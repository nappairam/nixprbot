const std = @import("std");
const Db = @import("db.zig").Db;
const TelegramClient = @import("telegram.zig").Client;
const github = @import("github.zig");
const Notify = @import("notify.zig").Notify;
const runtime = @import("runtime.zig");

/// Set by the main loop while GitHub polling is paused; refreshPr fails fast
/// so user commands can't hammer a rate-limited (or auth-broken) API.
pub const GhPause = enum { none, rate_limited, unauthorized };

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
    notify: *Notify,
    gh_pause: GhPause = .none,
    /// True while the last runOnce saw no contained failures — GitHub calls,
    /// notification sends, prunes all succeeded. Consumed by the heartbeat:
    /// a dirty sweep must stop the dead-man pings.
    sweep_clean: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        db: *Db,
        gh: *github.Client,
        tg: *TelegramClient,
        branches: []const []const u8,
        notify: *Notify,
    ) Tracker {
        return .{
            .allocator = allocator,
            .db = db,
            .gh = gh,
            .tg = tg,
            .branches = branches,
            .notify = notify,
        };
    }

    /// Refresh PR metadata from GitHub, emit transition events, and check
    /// branch containment for any branches not yet reached. Returns false
    /// if the PR is not found.
    ///
    /// GithubUnauthorized and GithubRateLimited propagate — they poison the
    /// whole sweep, not just this PR, and the caller must stop.
    pub fn refreshPr(self: *Tracker, pr_number: i64) !bool {
        switch (self.gh_pause) {
            .none => {},
            .rate_limited => return error.GithubRateLimited,
            .unauthorized => return error.GithubUnauthorized,
        }

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

        std.log.debug("PR #{d} state={s} merged={} prev_merged={} prev_state={?s}", .{
            pr_number, pr.state, pr.merged, prev_merged, prev_state,
        });

        // Events fire BEFORE the state they are edged on is persisted, and
        // the state is only persisted once every subscriber got the message.
        // A failed send therefore re-fires next sweep (the notified ledger
        // dedups chats that already got it) instead of being lost forever.
        var events_ok = true;
        if (pr.merged and !prev_merged) {
            events_ok = try self.fanout(pr, .merged);
        } else if (std.mem.eql(u8, pr.state, "closed") and !pr.merged) {
            const was_closed = if (prev_state) |s| std.mem.eql(u8, s, "closed") else false;
            if (!was_closed) events_ok = try self.fanout(pr, .closed);
        }
        if (events_ok) {
            try self.db.upsertMeta(pr_number, pr.title, pr.state, pr.merged, pr.merge_commit_sha);
        }

        if (pr.merged) {
            const sha = pr.merge_commit_sha orelse {
                std.log.debug("PR #{d} merged but no merge_commit_sha; skipping branch check", .{pr_number});
                return true;
            };
            if (sha.len == 0) return true;

            const reached = try self.db.reachedStages(self.allocator, pr_number);
            defer Db.freeStrings(self.allocator, reached);

            for (self.branches) |branch| {
                if (containsBranch(reached, branch)) continue;
                const in_branch = self.gh.commitInBranch(branch, sha) catch |err| switch (err) {
                    error.GithubUnauthorized, error.GithubRateLimited => return err,
                    else => {
                        std.log.warn("  compare {s}: {s}", .{ branch, @errorName(err) });
                        continue;
                    },
                };
                std.log.debug("  {s}: contains={}", .{ branch, in_branch });
                if (!in_branch) continue;
                if (try self.fanout(pr, .{ .stage = branch })) {
                    _ = try self.db.recordStage(pr_number, branch);
                }
            }
        }

        return true;
    }

    /// Returns true when every subscriber is marked notified (sent now or
    /// previously); false when at least one send failed and the event must
    /// re-fire next sweep.
    fn fanout(self: *Tracker, pr: github.Pr, event: Event) !bool {
        const subs = try self.db.subscribers(self.allocator, pr.number);
        defer self.allocator.free(subs);

        const stage = stageKey(event);
        std.log.info("fanout pr={d} stage={s} subs={d}", .{ pr.number, stage, subs.len });
        if (subs.len == 0) return true;

        const text = try formatEvent(self.allocator, pr.number, pr.title, pr.html_url, event);
        defer self.allocator.free(text);

        var all_ok = true;
        for (subs) |chat_id| {
            if (!try self.sendIfNew(chat_id, pr.number, stage, text)) all_ok = false;
        }
        return all_ok;
    }

    /// Send-then-mark: a failed send stays unmarked and retries next cycle.
    /// At-least-once beats silently-never. Returns true when the chat is
    /// marked notified (now or previously).
    fn sendIfNew(
        self: *Tracker,
        chat_id: i64,
        pr_number: i64,
        stage: []const u8,
        text: []const u8,
    ) !bool {
        self.notify.ping();
        const seen = self.db.alreadyNotified(chat_id, pr_number, stage) catch |err| {
            std.log.warn("alreadyNotified chat={d} pr={d}: {s}", .{ chat_id, pr_number, @errorName(err) });
            return false;
        };
        if (seen) return true;
        self.tg.sendMessage(chat_id, text) catch |err| {
            // A blocked bot can never deliver to this chat again; dropping
            // the subscription is the honest outcome, and it must not hold
            // the event's persistence (or the heartbeat) hostage.
            if (err == error.TelegramForbidden) {
                std.log.info("chat {d} blocked the bot; unsubscribing from pr {d}", .{ chat_id, pr_number });
                _ = self.db.unsubscribe(chat_id, pr_number) catch {};
                return true;
            }
            std.log.warn("notify chat={d} pr={d} stage={s}: {s}", .{
                chat_id, pr_number, stage, @errorName(err),
            });
            self.sweep_clean = false;
            return false;
        };
        self.db.markNotified(chat_id, pr_number, stage) catch |err| {
            std.log.warn("markNotified chat={d} pr={d}: {s}", .{ chat_id, pr_number, @errorName(err) });
        };
        return true;
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
            _ = try self.sendIfNew(chat_id, pr_number, "_merged", text);
        } else if (m.state) |s| {
            if (std.mem.eql(u8, s, "closed")) {
                const text = try formatEvent(self.allocator, pr_number, title, html_url, .closed);
                defer self.allocator.free(text);
                _ = try self.sendIfNew(chat_id, pr_number, "_closed", text);
            }
        }

        if (!m.merged) return;

        const reached = try self.db.reachedStages(self.allocator, pr_number);
        defer Db.freeStrings(self.allocator, reached);

        for (branches) |b| {
            if (!containsBranch(reached, b)) continue;
            const text = try formatEvent(self.allocator, pr_number, title, html_url, .{ .stage = b });
            defer self.allocator.free(text);
            _ = try self.sendIfNew(chat_id, pr_number, b, text);
        }
    }

    /// One full sweep over every tracked PR. Per-PR errors are contained;
    /// GithubUnauthorized/GithubRateLimited abort the sweep and propagate so
    /// the main loop can pause GitHub polling instead of hammering.
    pub fn runOnce(self: *Tracker) !void {
        // Pessimistic until the sweep is underway: an abort at any point must
        // leave the flag false, never a stale true from the previous sweep.
        self.sweep_clean = false;
        const prs = try self.db.allTrackedPrs(self.allocator);
        defer self.allocator.free(prs);
        std.log.info("tracker.runOnce prs={d}", .{prs.len});
        self.sweep_clean = true;
        for (prs) |pr_number| {
            if (runtime.shutdown.load(.seq_cst)) return;
            self.notify.ping();
            const ok = self.refreshPr(pr_number) catch |err| switch (err) {
                error.GithubUnauthorized, error.GithubRateLimited => {
                    self.sweep_clean = false;
                    return err;
                },
                else => blk: {
                    std.log.warn("refreshPr {d}: {s}", .{ pr_number, @errorName(err) });
                    self.sweep_clean = false;
                    break :blk false;
                },
            };
            if (!ok) continue;
            _ = self.pruneIfComplete(pr_number) catch |err| {
                std.log.warn("pruneIfComplete {d}: {s}", .{ pr_number, @errorName(err) });
                self.sweep_clean = false;
            };
            _ = self.pruneIfClosed(pr_number) catch |err| {
                std.log.warn("pruneIfClosed {d}: {s}", .{ pr_number, @errorName(err) });
                self.sweep_clean = false;
            };
        }
    }

    /// Returns true if cached pr_meta + pr_stage indicate the PR has reached
    /// every configured branch. Pure cache lookup, no GitHub call.
    pub fn isComplete(self: *Tracker, pr_number: i64) !bool {
        const meta = try self.db.getMeta(self.allocator, pr_number);
        defer if (meta) |m| m.deinit(self.allocator);
        const m = meta orelse return false;
        if (!m.merged) return false;

        const reached = try self.db.reachedStages(self.allocator, pr_number);
        defer Db.freeStrings(self.allocator, reached);
        for (self.branches) |b| if (!containsBranch(reached, b)) return false;
        return true;
    }

    /// If the PR has reached all configured branches, drop every subscription
    /// for it. pr_meta and pr_stage are kept so future /track requests for the
    /// same PR can serve from cache without a GitHub round-trip.
    /// Returns the number of subscriptions removed.
    pub fn pruneIfComplete(self: *Tracker, pr_number: i64) !usize {
        if (!try self.isComplete(pr_number)) return 0;
        const text = try std.fmt.allocPrint(
            self.allocator,
            "✅ PR #{d} reached all configured branches; auto-untracked.",
            .{pr_number},
        );
        defer self.allocator.free(text);
        return self.untrackAll(pr_number, text);
    }

    /// Closed-without-merge PRs are dead ends: polling them forever only
    /// burns quota. Untrack everyone; a reopened PR can be re-/track'ed.
    pub fn pruneIfClosed(self: *Tracker, pr_number: i64) !usize {
        const meta = try self.db.getMeta(self.allocator, pr_number);
        defer if (meta) |m| m.deinit(self.allocator);
        const m = meta orelse return 0;
        if (m.merged) return 0;
        const state = m.state orelse return 0;
        if (!std.mem.eql(u8, state, "closed")) return 0;

        const text = try std.fmt.allocPrint(
            self.allocator,
            "PR #{d} was closed; auto-untracked (re-/track it if it reopens).",
            .{pr_number},
        );
        defer self.allocator.free(text);
        return self.untrackAll(pr_number, text);
    }

    fn untrackAll(self: *Tracker, pr_number: i64, text: []const u8) !usize {
        const subs = try self.db.subscribers(self.allocator, pr_number);
        defer self.allocator.free(subs);
        if (subs.len == 0) return 0;

        var removed: usize = 0;
        for (subs) |chat_id| {
            self.notify.ping();
            // Message strictly before unsubscribe: a failed send keeps the
            // subscription (and the notified ledger) so next sweep retries —
            // a tracked PR must never vanish without the chat hearing why.
            // Exception: a chat that blocked the bot can never hear anything;
            // fall through and unsubscribe it.
            self.tg.sendMessage(chat_id, text) catch |err| {
                if (err != error.TelegramForbidden) {
                    std.log.warn("untrack notify chat={d} pr={d}: {s}", .{
                        chat_id, pr_number, @errorName(err),
                    });
                    self.sweep_clean = false;
                    continue;
                }
                std.log.info("chat {d} blocked the bot; unsubscribing from pr {d}", .{ chat_id, pr_number });
            };
            _ = self.db.unsubscribe(chat_id, pr_number) catch |err| {
                std.log.warn("auto-untrack chat={d} pr={d}: {s}", .{
                    chat_id, pr_number, @errorName(err),
                });
                continue;
            };
            removed += 1;
        }
        std.log.info("auto-untracked PR #{d} ({d}/{d} sub(s))", .{ pr_number, removed, subs.len });
        return removed;
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

test "formatEvent escapes html in title" {
    const a = std.testing.allocator;
    const text = try formatEvent(a, 7, "fix <script> & stuff", "https://x/pull/7", .merged);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "&amp;") != null);
}
