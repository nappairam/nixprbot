const std = @import("std");
const http = @import("http.zig");

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
            "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout={d}&allowed_updates=[\"message\"]",
            .{ self.token, offset, timeout_sec },
        );
        defer self.allocator.free(url);

        var resp = try self.http.request(.{ .url = url, .method = .GET });
        defer resp.deinit();

        if (resp.status != .ok) return error.TelegramHttpError;

        const parsed = try std.json.parseFromSlice(
            Updates.Envelope,
            self.allocator,
            resp.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        if (!parsed.value.ok) {
            parsed.deinit();
            return error.TelegramApiError;
        }
        return .{ .parsed = parsed };
    }

    pub fn sendMessage(self: *Client, chat_id: i64, text: []const u8) !void {
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

        if (resp.status != .ok) {
            std.log.warn("sendMessage status={d} body={s}", .{ @intFromEnum(resp.status), resp.body });
            return error.TelegramHttpError;
        }
    }
};

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
