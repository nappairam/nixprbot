const std = @import("std");
const http = @import("http.zig");
const runtime = @import("runtime.zig");
const Io = std.Io;

pub const Update = struct {
    update_id: i64,
    message: ?Message = null,
};

pub const Message = struct {
    message_id: i64,
    from: ?User = null,
    chat: Chat,
    text: ?[]const u8 = null,
};

pub const User = struct {
    id: i64,
};

pub const Chat = struct {
    id: i64,
};

pub const Error = error{
    /// Bot token rejected — configuration problem, not weather.
    TelegramUnauthorized,
    /// Another getUpdates poller is running against the same token.
    TelegramConflict,
    /// The chat blocked the bot (or kicked it) — permanent per-chat.
    TelegramForbidden,
    TelegramHttpError,
    TelegramApiError,
};

pub const Client = struct {
    http: *http.Client,
    allocator: std.mem.Allocator,
    token: []const u8,

    pub fn init(allocator: std.mem.Allocator, http_client: *http.Client, token: []const u8) Client {
        return .{ .http = http_client, .allocator = allocator, .token = token };
    }

    fn methodUrl(self: *Client, allocator: std.mem.Allocator, method: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/{s}", .{ self.token, method });
    }

    fn statusToError(status: std.http.Status) Error {
        return switch (status) {
            .unauthorized => Error.TelegramUnauthorized,
            .conflict => Error.TelegramConflict,
            .forbidden => Error.TelegramForbidden,
            else => Error.TelegramHttpError,
        };
    }

    pub const Updates = struct {
        parsed: std.json.Parsed(Envelope),

        const Envelope = struct {
            ok: bool,
            result: []Update,
            description: ?[]const u8 = null,
        };

        pub fn deinit(self: *Updates) void {
            self.parsed.deinit();
        }

        pub fn items(self: *const Updates) []const Update {
            return self.parsed.value.result;
        }
    };

    pub fn getUpdates(self: *Client, offset: i64, timeout_sec: u32) !Updates {
        const url = try std.fmt.allocPrint(
            self.allocator,
            // %5B%22message%22%5D = ["message"], percent-encoded.
            "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout={d}&allowed_updates=%5B%22message%22%5D",
            .{ self.token, offset, timeout_sec },
        );
        defer self.allocator.free(url);

        var resp = try self.http.request(.{ .url = url, .method = .GET });
        defer resp.deinit();

        if (resp.status != .ok) {
            // Response bodies never contain the token; the URL does — log the former only.
            std.log.warn("getUpdates status={d} body={s}", .{ @intFromEnum(resp.status), resp.body });
            return statusToError(resp.status);
        }

        const parsed = try std.json.parseFromSlice(
            Updates.Envelope,
            self.allocator,
            resp.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        if (!parsed.value.ok) {
            std.log.warn("getUpdates api not-ok: {s}", .{parsed.value.description orelse "(no description)"});
            parsed.deinit();
            return Error.TelegramApiError;
        }
        return .{ .parsed = parsed };
    }

    pub fn sendMessage(self: *Client, chat_id: i64, text: []const u8) !void {
        var attempt: u2 = 0;
        while (true) : (attempt += 1) {
            const res = try self.sendMessageOnce(chat_id, text);
            if (res.status == .ok) return;
            // Honor flood-control once; a second 429 (or anything else) is
            // left to the caller, whose notified-ledger retries next cycle.
            if (res.status == .too_many_requests and attempt == 0) {
                const wait_sec = res.retry_after orelse 3;
                std.log.warn("sendMessage 429; waiting {d}s", .{wait_sec});
                runtime.sleepInterruptible(self.http.io, @as(u64, wait_sec) * std.time.ns_per_s);
                continue;
            }
            return statusToError(res.status);
        }
    }

    const SendResult = struct {
        status: std.http.Status,
        retry_after: ?u32 = null,
    };

    fn sendMessageOnce(self: *Client, chat_id: i64, text: []const u8) !SendResult {
        const url = try self.methodUrl(self.allocator, "sendMessage");
        defer self.allocator.free(url);

        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buf.deinit();
        try std.json.Stringify.value(.{
            .chat_id = chat_id,
            .text = text,
            .parse_mode = "HTML",
            .disable_web_page_preview = true,
        }, .{ .emit_null_optional_fields = false }, &body_buf.writer);

        var resp = try self.http.request(.{
            .url = url,
            .method = .POST,
            .body = body_buf.written(),
            .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        defer resp.deinit();

        if (resp.status == .too_many_requests) {
            return .{
                .status = resp.status,
                .retry_after = parseRetryAfter(self.allocator, resp.body),
            };
        }
        if (resp.status != .ok) {
            std.log.warn("sendMessage status={d} body={s}", .{ @intFromEnum(resp.status), resp.body });
        }
        return .{ .status = resp.status };
    }

    pub const Command = struct {
        command: []const u8,
        description: []const u8,
    };

    pub fn setMyCommands(self: *Client, commands_list: []const Command) !void {
        const url = try self.methodUrl(self.allocator, "setMyCommands");
        defer self.allocator.free(url);

        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buf.deinit();
        try std.json.Stringify.value(.{
            .commands = commands_list,
        }, .{}, &body_buf.writer);

        var resp = try self.http.request(.{
            .url = url,
            .method = .POST,
            .body = body_buf.written(),
            .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        defer resp.deinit();

        if (resp.status != .ok) {
            std.log.warn("setMyCommands status={d} body={s}", .{
                @intFromEnum(resp.status), resp.body,
            });
            return statusToError(resp.status);
        }
    }
};

/// Extract parameters.retry_after from a Bot API error body, capped to 60s.
pub fn parseRetryAfter(allocator: std.mem.Allocator, body: []const u8) ?u32 {
    const Envelope = struct {
        parameters: ?struct {
            retry_after: ?u32 = null,
        } = null,
    };
    const parsed = std.json.parseFromSlice(
        Envelope,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();
    const params = parsed.value.parameters orelse return null;
    const ra = params.retry_after orelse return null;
    return @min(ra, 60);
}

test "parse getUpdates envelope" {
    const a = std.testing.allocator;
    const json =
        \\{"ok":true,"result":[
        \\  {"update_id":1,"message":{"message_id":10,"from":{"id":42},"chat":{"id":42},"text":"/list"}},
        \\  {"update_id":2,"message":{"message_id":11,"from":{"id":99},"chat":{"id":99},"text":"hi"}}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(
        Client.Updates.Envelope,
        a,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.result.len);
    try std.testing.expectEqualStrings("/list", parsed.value.result[0].message.?.text.?);
    try std.testing.expectEqual(@as(i64, 99), parsed.value.result[1].message.?.from.?.id);
}

test "parseRetryAfter" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(
        @as(?u32, 5),
        parseRetryAfter(a, "{\"ok\":false,\"error_code\":429,\"parameters\":{\"retry_after\":5}}"),
    );
    try std.testing.expectEqual(
        @as(?u32, 60),
        parseRetryAfter(a, "{\"parameters\":{\"retry_after\":3600}}"),
    );
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter(a, "{\"ok\":false}"));
    try std.testing.expectEqual(@as(?u32, null), parseRetryAfter(a, "not json"));
}
