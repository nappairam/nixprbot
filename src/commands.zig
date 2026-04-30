const std = @import("std");
const Db = @import("db.zig").Db;
const TelegramClient = @import("telegram.zig").Client;
const Update = @import("telegram.zig").Update;

pub const Error = error{
    InvalidPrReference,
    NoMessage,
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
    \\nixpkgs PR tracker bot
    \\
    \\Commands:
    \\  /track <pr#|url>   Start tracking a PR
    \\  /untrack <pr#>     Stop tracking
    \\  /list              Show your tracked PRs
    \\  /help              Show this help
;

pub fn dispatch(
    allocator: std.mem.Allocator,
    db: *Db,
    tg: *TelegramClient,
    update: Update,
) !void {
    const msg = update.message orelse return;
    const text = msg.text orelse return;
    const chat_id = msg.chat.id;
    const user_id = if (msg.from) |u| u.id else chat_id;

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return;

    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const cmd_raw = it.next() orelse return;
    const cmd = stripBotSuffix(cmd_raw);
    const arg_rest = it.rest();

    if (std.mem.eql(u8, cmd, "/track")) {
        try handleTrack(allocator, db, tg, chat_id, user_id, arg_rest);
    } else if (std.mem.eql(u8, cmd, "/untrack")) {
        try handleUntrack(allocator, db, tg, chat_id, user_id, arg_rest);
    } else if (std.mem.eql(u8, cmd, "/list")) {
        try handleList(allocator, db, tg, chat_id, user_id);
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
    chat_id: i64,
    user_id: i64,
    arg: []const u8,
) !void {
    const pr = parsePrReference(arg) catch {
        try tg.sendMessage(chat_id, "Usage: /track <pr-number-or-url>");
        return;
    };
    try db.addTrack(user_id, pr);
    const msg = try std.fmt.allocPrint(allocator, "Tracking PR #{d}", .{pr});
    defer allocator.free(msg);
    try tg.sendMessage(chat_id, msg);
}

fn handleUntrack(
    allocator: std.mem.Allocator,
    db: *Db,
    tg: *TelegramClient,
    chat_id: i64,
    user_id: i64,
    arg: []const u8,
) !void {
    const pr = parsePrReference(arg) catch {
        try tg.sendMessage(chat_id, "Usage: /untrack <pr-number>");
        return;
    };
    const removed = try db.removeTrack(user_id, pr);
    const msg = if (removed)
        try std.fmt.allocPrint(allocator, "Stopped tracking PR #{d}", .{pr})
    else
        try std.fmt.allocPrint(allocator, "PR #{d} was not tracked", .{pr});
    defer allocator.free(msg);
    try tg.sendMessage(chat_id, msg);
}

fn handleList(
    allocator: std.mem.Allocator,
    db: *Db,
    tg: *TelegramClient,
    chat_id: i64,
    user_id: i64,
) !void {
    const tracks = try db.listTracksForUser(allocator, user_id);
    defer Db.freeTracks(allocator, tracks);

    if (tracks.len == 0) {
        try tg.sendMessage(chat_id, "No tracked PRs. Use /track <pr#> to add one.");
        return;
    }

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.print("Tracking {d} PR(s):\n", .{tracks.len});
    for (tracks) |t| {
        try buf.writer.print("- #{d}", .{t.pr_number});
        if (t.last_state_json) |s| try buf.writer.print(" {s}", .{s});
        try buf.writer.writeByte('\n');
    }
    try tg.sendMessage(chat_id, buf.written());
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
    try std.testing.expectEqual(
        @as(i64, 1),
        try parsePrReference("github.com/NixOS/nixpkgs/pull/1#discussion"),
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
