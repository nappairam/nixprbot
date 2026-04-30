const std = @import("std");
const Db = @import("db.zig").Db;
const TelegramClient = @import("telegram.zig").Client;
const Update = @import("telegram.zig").Update;
const github = @import("github.zig");
const tracker_mod = @import("poller.zig");

pub const Error = error{
    InvalidPrReference,
};

pub fn parsePrReference(arg: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    if (trimmed.len == 0) return Error.InvalidPrReference;

    if (std.mem.indexOf(u8, trimmed, "github.com/")) |_| {
        const marker = "/pull/";
        const idx = std.mem.indexOf(u8, trimmed, marker) orelse return Error.InvalidPrReference;
        var rest = trimmed[idx + marker.len ..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        rest = rest[0..end];
        return std.fmt.parseInt(i64, rest, 10) catch return Error.InvalidPrReference;
    }

    const numeric = std.mem.trimStart(u8, trimmed, "#");
    return std.fmt.parseInt(i64, numeric, 10) catch return Error.InvalidPrReference;
}

const help_text =
    \\<b>nixprbot</b> — track nixpkgs PRs across channel branches.
    \\
    \\<b>Commands</b>
    \\/track &lt;PR#|url&gt; — start tracking
    \\/untrack &lt;PR#&gt; — stop tracking
    \\/list — list tracked PRs
    \\/status &lt;PR#&gt; — one-shot status check
    \\/help — show this help
;

pub fn dispatch(
    allocator: std.mem.Allocator,
    db: *Db,
    tg: *TelegramClient,
    tracker: *tracker_mod.Tracker,
    branches: []const []const u8,
    update: Update,
) !void {
    const msg = update.message orelse return;
    const text = msg.text orelse return;
    const chat_id = msg.chat.id;

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return;

    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const cmd_raw = it.next() orelse return;
    const cmd = stripBotSuffix(cmd_raw);
    const arg_rest = it.rest();

    std.log.info("cmd={s} chat={d} arg={s}", .{ cmd, chat_id, arg_rest });

    if (std.mem.eql(u8, cmd, "/track")) {
        try handleTrack(allocator, db, tg, tracker, branches, chat_id, arg_rest);
    } else if (std.mem.eql(u8, cmd, "/untrack")) {
        try handleUntrack(allocator, db, tg, chat_id, arg_rest);
    } else if (std.mem.eql(u8, cmd, "/list")) {
        try handleList(allocator, db, tg, branches, chat_id);
    } else if (std.mem.eql(u8, cmd, "/status")) {
        try handleStatus(allocator, db, tg, tracker, branches, chat_id, arg_rest);
    } else if (std.mem.eql(u8, cmd, "/start") or std.mem.eql(u8, cmd, "/help")) {
        try tg.sendMessage(chat_id, help_text);
    }
}

fn stripBotSuffix(cmd: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, cmd, '@') orelse return cmd;
    return cmd[0..at];
}

fn handleTrack(
    allocator: std.mem.Allocator,
    db: *Db,
    tg: *TelegramClient,
    tracker: *tracker_mod.Tracker,
    branches: []const []const u8,
    chat_id: i64,
    arg: []const u8,
) !void {
    const pr_number = parsePrReference(arg) catch {
        try tg.sendMessage(chat_id, "Usage: /track &lt;PR#|url&gt;");
        return;
    };

    const found = tracker.refreshPr(pr_number) catch |err| {
        std.log.warn("track refreshPr {d}: {s}", .{ pr_number, @errorName(err) });
        try tg.sendMessage(chat_id, "Couldn't fetch PR — try again later.");
        return;
    };
    if (!found) {
        const m = try std.fmt.allocPrint(allocator, "PR #{d} not found.", .{pr_number});
        defer allocator.free(m);
        try tg.sendMessage(chat_id, m);
        return;
    }

    const added = try db.subscribe(chat_id, pr_number);
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const lead = if (added) "Tracking" else "Already tracking";
    try buf.writer.print("{s} PR #{d}\n", .{ lead, pr_number });
    try writeStatusBody(allocator, db, &buf.writer, branches, pr_number);
    try tg.sendMessage(chat_id, buf.written());
}

fn handleUntrack(
    allocator: std.mem.Allocator,
    db: *Db,
    tg: *TelegramClient,
    chat_id: i64,
    arg: []const u8,
) !void {
    const pr_number = parsePrReference(arg) catch {
        try tg.sendMessage(chat_id, "Usage: /untrack &lt;PR#&gt;");
        return;
    };
    const removed = try db.unsubscribe(chat_id, pr_number);
    const msg = if (removed)
        try std.fmt.allocPrint(allocator, "Stopped tracking PR #{d}.", .{pr_number})
    else
        try std.fmt.allocPrint(allocator, "You weren't tracking PR #{d}.", .{pr_number});
    defer allocator.free(msg);
    try tg.sendMessage(chat_id, msg);
}

fn handleList(
    allocator: std.mem.Allocator,
    db: *Db,
    tg: *TelegramClient,
    branches: []const []const u8,
    chat_id: i64,
) !void {
    _ = branches;
    const prs = try db.listSubscriptions(allocator, chat_id);
    defer allocator.free(prs);

    if (prs.len == 0) {
        try tg.sendMessage(chat_id, "You aren't tracking any PRs. Use /track &lt;PR#&gt;.");
        return;
    }

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("<b>Tracked PRs</b>");
    for (prs) |pr_number| {
        const meta = try db.getMeta(allocator, pr_number);
        defer if (meta) |m| m.deinit(allocator);
        const reached = try db.reachedStages(allocator, pr_number);
        defer Db.freeStrings(allocator, reached);

        const title = if (meta) |m| (m.title orelse "(unknown)") else "(unknown)";
        const state_label = blk: {
            if (meta) |m| {
                if (m.merged) break :blk "merged";
                break :blk m.state orelse "unknown";
            }
            break :blk "unknown";
        };
        try buf.writer.print(
            "\n• #{d} [<code>{s}</code>] {s}",
            .{ pr_number, state_label, title },
        );
        if (reached.len > 0) {
            try buf.writer.writeAll("\n   stages: ");
            for (reached, 0..) |s, k| {
                if (k > 0) try buf.writer.writeAll(", ");
                try buf.writer.writeAll(s);
            }
        }
    }
    try tg.sendMessage(chat_id, buf.written());
}

fn handleStatus(
    allocator: std.mem.Allocator,
    db: *Db,
    tg: *TelegramClient,
    tracker: *tracker_mod.Tracker,
    branches: []const []const u8,
    chat_id: i64,
    arg: []const u8,
) !void {
    const pr_number = parsePrReference(arg) catch {
        try tg.sendMessage(chat_id, "Usage: /status &lt;PR#&gt;");
        return;
    };
    const found = tracker.refreshPr(pr_number) catch |err| {
        std.log.warn("status refreshPr {d}: {s}", .{ pr_number, @errorName(err) });
        try tg.sendMessage(chat_id, "Couldn't fetch status — try again later.");
        return;
    };
    if (!found) {
        const m = try std.fmt.allocPrint(allocator, "PR #{d} not found.", .{pr_number});
        defer allocator.free(m);
        try tg.sendMessage(chat_id, m);
        return;
    }

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try writeStatusBody(allocator, db, &buf.writer, branches, pr_number);
    try tg.sendMessage(chat_id, buf.written());
}

fn writeStatusBody(
    allocator: std.mem.Allocator,
    db: *Db,
    w: *std.Io.Writer,
    branches: []const []const u8,
    pr_number: i64,
) !void {
    const meta = try db.getMeta(allocator, pr_number);
    defer if (meta) |m| m.deinit(allocator);
    const reached = try db.reachedStages(allocator, pr_number);
    defer Db.freeStrings(allocator, reached);

    if (meta) |m| {
        const label = if (m.merged) "merged" else (m.state orelse "unknown");
        try w.print("<b>{s}</b>\nState: <code>{s}</code>\n", .{
            m.title orelse "(unknown)", label,
        });
    }
    for (branches) |b| {
        const mark: []const u8 = if (containsBranchSlice(reached, b)) "✅" else "⬜";
        try w.print("{s} {s}\n", .{ mark, b });
    }
}

fn containsBranchSlice(reached: []const []u8, branch: []const u8) bool {
    for (reached) |r| {
        if (std.mem.eql(u8, r, branch)) return true;
    }
    return false;
}

test "parsePrReference numeric" {
    try std.testing.expectEqual(@as(i64, 1234), try parsePrReference("1234"));
    try std.testing.expectEqual(@as(i64, 1234), try parsePrReference("#1234"));
    try std.testing.expectEqual(@as(i64, 1234), try parsePrReference("  1234  "));
}

test "parsePrReference url" {
    try std.testing.expectEqual(
        @as(i64, 567890),
        try parsePrReference("https://github.com/NixOS/nixpkgs/pull/567890"),
    );
    try std.testing.expectEqual(
        @as(i64, 567890),
        try parsePrReference("https://github.com/NixOS/nixpkgs/pull/567890/files"),
    );
}

test "parsePrReference invalid" {
    try std.testing.expectError(Error.InvalidPrReference, parsePrReference(""));
    try std.testing.expectError(Error.InvalidPrReference, parsePrReference("notanumber"));
    try std.testing.expectError(Error.InvalidPrReference, parsePrReference("https://github.com/foo/bar"));
}

test "stripBotSuffix" {
    try std.testing.expectEqualStrings("/track", stripBotSuffix("/track"));
    try std.testing.expectEqualStrings("/track", stripBotSuffix("/track@MyBot"));
}
