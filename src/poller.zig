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
        var pr_parsed = self.gh.getPr(pr_number) catch |err| switch (err) {
            error.GithubNotFound => return false,
            else => return err,
        };
        defer pr_parsed.deinit();
        const pr = pr_parsed.value();

        const prev = try self.db.getMeta(self.allocator, pr_number);
        defer if (prev) |p| p.deinit(self.allocator);
        const prev_merged = if (prev) |p| p.merged else false;
        const prev_state: ?[]const u8 = if (prev) |p| p.state else null;

        try self.db.upsertMeta(pr_number, pr.title, pr.state, pr.merged, pr.merge_commit_sha);

        if (pr.merged and !prev_merged) {
            try self.fanout(pr, .merged);
        } else if (std.mem.eql(u8, pr.state, "closed") and !pr.merged) {
            const was_closed = if (prev_state) |s| std.mem.eql(u8, s, "closed") else false;
            if (!was_closed) try self.fanout(pr, .closed);
        }

        if (pr.merged) {
            const sha = pr.merge_commit_sha orelse return true;
            if (sha.len == 0) return true;

            const reached = try self.db.reachedStages(self.allocator, pr_number);
            defer Db.freeStrings(self.allocator, reached);

            for (self.branches) |branch| {
                if (containsBranch(reached, branch)) continue;
                const in_branch = self.gh.commitInBranch(branch, sha) catch |err| {
                    std.log.warn("compare {s} for PR #{d} failed: {s}", .{
                        branch, pr_number, @errorName(err),
                    });
                    continue;
                };
                if (!in_branch) continue;
                const newly = try self.db.recordStage(pr_number, branch);
                if (newly) try self.fanout(pr, .{ .stage = branch });
            }
        }

        return true;
    }

    fn fanout(self: *Tracker, pr: github.Pr, event: Event) !void {
        const subs = try self.db.subscribers(self.allocator, pr.number);
        defer self.allocator.free(subs);
        if (subs.len == 0) return;

        const stage = stageKey(event);
        const text = try formatEvent(self.allocator, pr, event);
        defer self.allocator.free(text);

        std.log.info("fanout pr={d} stage={s} subs={d}", .{ pr.number, stage, subs.len });

        for (subs) |chat_id| {
            const seen = self.db.alreadyNotified(chat_id, pr.number, stage) catch |err| {
                std.log.warn("alreadyNotified chat={d} pr={d}: {s}", .{ chat_id, pr.number, @errorName(err) });
                continue;
            };
            if (seen) continue;
            self.tg.sendMessage(chat_id, text) catch |err| {
                std.log.warn("notify chat={d} pr={d}: {s}", .{ chat_id, pr.number, @errorName(err) });
                continue;
            };
            self.db.markNotified(chat_id, pr.number, stage) catch |err| {
                std.log.warn("markNotified chat={d} pr={d}: {s}", .{ chat_id, pr.number, @errorName(err) });
            };
        }
    }

    pub fn runOnce(self: *Tracker) !void {
        const prs = try self.db.allTrackedPrs(self.allocator);
        defer self.allocator.free(prs);
        std.log.info("tracker.runOnce prs={d}", .{prs.len});
        for (prs) |pr_number| {
            _ = self.refreshPr(pr_number) catch |err| {
                std.log.warn("refreshPr {d}: {s}", .{ pr_number, @errorName(err) });
            };
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
    pr: github.Pr,
    event: Event,
) ![]u8 {
    switch (event) {
        .merged => return std.fmt.allocPrint(
            allocator,
            "🟣 <a href=\"{s}\">PR #{d}</a> was <b>merged</b>: {s}",
            .{ pr.html_url, pr.number, pr.title },
        ),
        .closed => return std.fmt.allocPrint(
            allocator,
            "⚫ <a href=\"{s}\">PR #{d}</a> was <b>closed without merging</b>: {s}",
            .{ pr.html_url, pr.number, pr.title },
        ),
        .stage => |branch| return std.fmt.allocPrint(
            allocator,
            "🟢 <a href=\"{s}\">PR #{d}</a> reached <code>{s}</code>",
            .{ pr.html_url, pr.number, branch },
        ),
    }
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
