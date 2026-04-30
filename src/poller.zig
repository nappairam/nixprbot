const std = @import("std");
const Db = @import("db.zig").Db;
const TelegramClient = @import("telegram.zig").Client;
const github = @import("github.zig");

pub const Event = union(enum) {
    merged,
    closed,
    stage: []const u8,
};

pub fn stageKey(event: Event) []const u8 {
    return switch (event) {
        .merged => "_merged",
        .closed => "_closed",
        .stage => |b| b,
    };
}

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    db: *Db,
    gh: *github.Client,
    tg: *TelegramClient,
    branches: []const []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        db: *Db,
        gh: *github.Client,
        tg: *TelegramClient,
        branches: []const []const u8,
    ) Tracker {
        return .{ .allocator = allocator, .db = db, .gh = gh, .tg = tg, .branches = branches };
    }

    /// Refresh PR metadata from GitHub, emit transition events, and check
    /// branch containment for any branches not yet reached. Returns false
    /// if the PR is not found.
    pub fn refreshPr(self: *Tracker, pr_number: i64) !bool {
        std.log.debug("refreshPr {d}", .{pr_number});
        var pr_parsed = self.gh.getPr(pr_number) catch |err| switch (err) {
            error.GithubNotFound => {
                std.log.warn("refreshPr {d}: not found", .{pr_number});
                return false;
            },
            else => return err,
        };
        defer pr_parsed.deinit();
        const pr = pr_parsed.value();

        const prev = try self.db.getMeta(self.allocator, pr_number);
        defer if (prev) |p| p.deinit(self.allocator);
        const prev_merged = if (prev) |p| p.merged else false;
        const prev_state: ?[]const u8 = if (prev) |p| p.state else null;

        try self.db.upsertMeta(pr_number, pr.title, pr.state, pr.merged, pr.merge_commit_sha);
        std.log.debug("PR #{d} state={s} merged={} prev_merged={} prev_state={?s}", .{
            pr_number, pr.state, pr.merged, prev_merged, prev_state,
        });

        if (pr.merged and !prev_merged) {
            try self.fanout(pr, .merged);
        } else if (std.mem.eql(u8, pr.state, "closed") and !pr.merged) {
            const was_closed = if (prev_state) |s| std.mem.eql(u8, s, "closed") else false;
            if (!was_closed) try self.fanout(pr, .closed);
        }

        if (pr.merged) {
            const sha = pr.merge_commit_sha orelse {
                std.log.debug("PR #{d} merged but no merge_commit_sha; skipping branch check", .{pr_number});
                return true;
            };
            if (sha.len == 0) {
                std.log.debug("PR #{d} merge_commit_sha empty", .{pr_number});
                return true;
            }
            std.log.debug("PR #{d} merge_commit_sha={s}", .{ pr_number, sha });

            const reached = try self.db.reachedStages(self.allocator, pr_number);
            defer Db.freeStrings(self.allocator, reached);
            std.log.debug("PR #{d} reached_stages={d} branches_to_check={d}", .{
                pr_number, reached.len, self.branches.len,
            });

            for (self.branches) |branch| {
                if (containsBranch(reached, branch)) {
                    std.log.debug("  {s}: already reached, skip", .{branch});
                    continue;
                }
                const in_branch = self.gh.commitInBranch(branch, sha) catch |err| {
                    std.log.warn("  compare {s}: {s}", .{ branch, @errorName(err) });
                    continue;
                };
                std.log.debug("  {s}: contains={}", .{ branch, in_branch });
                if (!in_branch) continue;
                const newly = try self.db.recordStage(pr_number, branch);
                std.log.debug("  recordStage {s}: newly={}", .{ branch, newly });
                if (newly) try self.fanout(pr, .{ .stage = branch });
            }
        } else {
            std.log.debug("PR #{d} not merged (state={s}); skipping branch check", .{ pr_number, pr.state });
        }

        return true;
    }

    fn fanout(self: *Tracker, pr: github.Pr, event: Event) !void {
        const subs = try self.db.subscribers(self.allocator, pr.number);
        defer self.allocator.free(subs);

        const stage = stageKey(event);
        std.log.info("fanout pr={d} stage={s} subs={d}", .{ pr.number, stage, subs.len });
        if (subs.len == 0) return;

        const text = try formatEvent(self.allocator, pr.number, pr.title, pr.html_url, event);
        defer self.allocator.free(text);

        for (subs) |chat_id| {
            try self.sendIfNew(chat_id, pr.number, stage, text);
        }
    }

    fn sendIfNew(
        self: *Tracker,
        chat_id: i64,
        pr_number: i64,
        stage: []const u8,
        text: []const u8,
    ) !void {
        const seen = self.db.alreadyNotified(chat_id, pr_number, stage) catch |err| {
            std.log.warn("alreadyNotified chat={d} pr={d}: {s}", .{ chat_id, pr_number, @errorName(err) });
            return;
        };
        if (seen) {
            std.log.debug("  chat={d}: already notified for {s}, skip", .{ chat_id, stage });
            return;
        }
        self.tg.sendMessage(chat_id, text) catch |err| {
            std.log.warn("notify chat={d} pr={d} stage={s}: {s}", .{
                chat_id, pr_number, stage, @errorName(err),
            });
            return;
        };
        std.log.debug("  chat={d}: sent {s}", .{ chat_id, stage });
        self.db.markNotified(chat_id, pr_number, stage) catch |err| {
            std.log.warn("markNotified chat={d} pr={d}: {s}", .{ chat_id, pr_number, @errorName(err) });
        };
    }

    /// Send one message per stage already reached for the PR (and merged/closed
    /// transitions) to a single chat, deduplicated by the `notified` table.
    /// Used after /track so a new subscriber gets the per-stage backstory.
    pub fn backfillSubscriber(
        self: *Tracker,
        chat_id: i64,
        pr_number: i64,
        branches: []const []const u8,
    ) !void {
        const meta = try self.db.getMeta(self.allocator, pr_number);
        defer if (meta) |m| m.deinit(self.allocator);
        const m = meta orelse return;

        const title = m.title orelse "(unknown)";
        const html_url = try std.fmt.allocPrint(
            self.allocator,
            "https://github.com/{s}/pull/{d}",
            .{ self.gh.repo, pr_number },
        );
        defer self.allocator.free(html_url);

        if (m.merged) {
            const text = try formatEvent(self.allocator, pr_number, title, html_url, .merged);
            defer self.allocator.free(text);
            try self.sendIfNew(chat_id, pr_number, "_merged", text);
        } else if (m.state) |s| {
            if (std.mem.eql(u8, s, "closed")) {
                const text = try formatEvent(self.allocator, pr_number, title, html_url, .closed);
                defer self.allocator.free(text);
                try self.sendIfNew(chat_id, pr_number, "_closed", text);
            }
        }

        if (!m.merged) return;

        const reached = try self.db.reachedStages(self.allocator, pr_number);
        defer Db.freeStrings(self.allocator, reached);

        for (branches) |b| {
            if (!containsBranch(reached, b)) continue;
            const text = try formatEvent(self.allocator, pr_number, title, html_url, .{ .stage = b });
            defer self.allocator.free(text);
            try self.sendIfNew(chat_id, pr_number, b, text);
        }
    }

    pub fn runOnce(self: *Tracker) !void {
        const prs = try self.db.allTrackedPrs(self.allocator);
        defer self.allocator.free(prs);
        std.log.info("tracker.runOnce prs={d}", .{prs.len});
        for (prs) |pr_number| {
            const ok = self.refreshPr(pr_number) catch |err| blk: {
                std.log.warn("refreshPr {d}: {s}", .{ pr_number, @errorName(err) });
                break :blk false;
            };
            if (!ok) std.log.debug("refreshPr {d} returned not-found", .{pr_number});
        }
    }
};

fn containsBranch(reached: []const []u8, branch: []const u8) bool {
    for (reached) |r| {
        if (std.mem.eql(u8, r, branch)) return true;
    }
    return false;
}

pub fn formatEvent(
    allocator: std.mem.Allocator,
    pr_number: i64,
    title: []const u8,
    html_url: []const u8,
    event: Event,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    switch (event) {
        .merged => {
            try buf.writer.print(
                "🟣 <a href=\"{s}\">PR #{d}</a>: ",
                .{ html_url, pr_number },
            );
            try writeEscaped(&buf.writer, title);
            try buf.writer.writeAll(" was <b>merged</b>.");
        },
        .closed => {
            try buf.writer.print(
                "⚫ <a href=\"{s}\">PR #{d}</a>: ",
                .{ html_url, pr_number },
            );
            try writeEscaped(&buf.writer, title);
            try buf.writer.writeAll(" was <b>closed without merging</b>.");
        },
        .stage => |branch| {
            try buf.writer.print(
                "🟢 <a href=\"{s}\">PR #{d}</a>: ",
                .{ html_url, pr_number },
            );
            try writeEscaped(&buf.writer, title);
            try buf.writer.print(" reached <code>{s}</code>.", .{branch});
        },
    }
    return buf.toOwnedSlice();
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

test "stageKey" {
    try std.testing.expectEqualStrings("_merged", stageKey(.merged));
    try std.testing.expectEqualStrings("_closed", stageKey(.closed));
    try std.testing.expectEqualStrings("master", stageKey(.{ .stage = "master" }));
}

test "containsBranch" {
    var a = "master".*;
    var b = "staging".*;
    var arr = [_][]u8{ &a, &b };
    try std.testing.expect(containsBranch(&arr, "master"));
    try std.testing.expect(!containsBranch(&arr, "nixos-unstable"));
}
