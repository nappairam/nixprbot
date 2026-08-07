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
    io: Io,
    inner: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: Io) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .inner = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
    }

    /// Drop the inner client — connection pool included — and start fresh.
    /// Zig 0.16's std.http.Client re-pools a keep-alive connection whose
    /// send failed (Request.deinit sees reader.state == .ready and keeps it),
    /// so a dead socket otherwise gets handed back out on every retry,
    /// forever. This wedged the previous deployment for 68 days.
    pub fn reset(self: *Client) void {
        self.inner.deinit();
        self.inner = .{ .allocator = self.allocator, .io = self.io };
    }

    pub const RequestOptions = struct {
        method: ?Method = null,
        url: []const u8,
        body: ?[]const u8 = null,
        headers: []const Header = &.{},
    };

    pub fn request(self: *Client, opts: RequestOptions) !Response {
        // std.http.Client freezes `now` on first TLS handshake and reuses it
        // for every subsequent cert validity check. After the upstream rotates
        // its certificate, the new `notBefore` may be later than that frozen
        // time, producing TlsInitializationFailed. Refresh before each call.
        if (self.inner.now != null) {
            self.inner.now = Io.Clock.real.now(self.io);
        }

        var alloc_w: Io.Writer.Allocating = .init(self.allocator);

        const result = self.inner.fetch(.{
            .location = .{ .url = opts.url },
            .method = opts.method,
            .payload = opts.body,
            .extra_headers = opts.headers,
            .response_writer = &alloc_w.writer,
        }) catch |err| {
            alloc_w.deinit();
            self.reset();
            return err;
        };

        const body = alloc_w.toOwnedSlice() catch |err| {
            alloc_w.deinit();
            return err;
        };
        return .{
            .status = result.status,
            .body = body,
            .allocator = self.allocator,
        };
    }
};
