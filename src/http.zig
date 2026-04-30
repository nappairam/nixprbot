const std = @import("std");
const Io = std.Io;

pub const Method = std.http.Method;
pub const Header = std.http.Header;

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    inner: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: Io) Client {
        return .{
            .allocator = allocator,
            .inner = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
    }

    pub const RequestOptions = struct {
        method: ?Method = null,
        url: []const u8,
        body: ?[]const u8 = null,
        headers: []const Header = &.{},
    };

    pub fn request(self: *Client, opts: RequestOptions) !Response {
        var alloc_w: Io.Writer.Allocating = .init(self.allocator);
        errdefer alloc_w.deinit();

        const result = try self.inner.fetch(.{
            .location = .{ .url = opts.url },
            .method = opts.method,
            .payload = opts.body,
            .extra_headers = opts.headers,
            .response_writer = &alloc_w.writer,
        });

        const body = try alloc_w.toOwnedSlice();
        return .{
            .status = result.status,
            .body = body,
            .allocator = self.allocator,
        };
    }
};
