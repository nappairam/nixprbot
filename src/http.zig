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

/// std.http.Client has no read or connect timeout, so a TCP path that dies
/// mid-request blocks recvmsg until the watchdog kills the process. Must
/// exceed the 30s Telegram long poll and, doubled by the stale-connection
/// retry, stay under the 120s watchdog.
pub const default_deadline: Io.Duration = .fromSeconds(45);

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    inner: std.http.Client,
    deadline: Io.Duration = default_deadline,

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
        return self.requestOnce(opts) catch |err| switch (err) {
            // A pooled keep-alive connection the server closed during idle
            // surfaces as a clean EOF the moment it's reused — the request
            // was never processed, so one retry (requestOnce already reset
            // the client, giving a fresh connection) is safe even for POSTs.
            // Every other error stays fatal to the attempt: retrying a
            // half-written request could double-send.
            error.HttpConnectionClosing => self.requestOnce(opts),
            else => err,
        };
    }

    fn requestOnce(self: *Client, opts: RequestOptions) !Response {
        // std.http.Client freezes `now` on first TLS handshake and reuses it
        // for every subsequent cert validity check. After the upstream rotates
        // its certificate, the new `notBefore` may be later than that frozen
        // time, producing TlsInitializationFailed. Refresh before each call.
        if (self.inner.now != null) {
            self.inner.now = Io.Clock.real.now(self.io);
        }

        var alloc_w: Io.Writer.Allocating = .init(self.allocator);

        const result = self.fetchWithDeadline(.{
            .location = .{ .url = opts.url },
            .method = opts.method,
            .payload = normalizePayload(opts.method, opts.body),
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

    const Race = union(enum) {
        fetch: std.http.Client.FetchError!std.http.Client.FetchResult,
        deadline: Io.Cancelable!void,
    };

    /// Run the fetch on a worker and race it against a timer; whichever loses
    /// is canceled (Io.Threaded interrupts the blocked syscall with SIGIO).
    fn fetchWithDeadline(self: *Client, opts: std.http.Client.FetchOptions) !std.http.Client.FetchResult {
        var buf: [2]Race = undefined;
        var race: Io.Select(Race) = .init(self.io, &buf);
        defer race.cancelDiscard();
        try race.concurrent(.fetch, std.http.Client.fetch, .{ &self.inner, opts });
        try race.concurrent(.deadline, Io.sleep, .{ self.io, self.deadline, .awake });
        return switch (try race.await()) {
            .fetch => |r| r,
            .deadline => error.RequestDeadlineExceeded,
        };
    }
};

/// std.http.Client's send path asserts — a panic in ReleaseSafe — when a
/// body-carrying method arrives with a null payload (fetch calls
/// sendBodiless, which requires !method.requestHasBody()). Normalize to an
/// empty body so callers can't trip it. Took the bot down in production:
/// a bodiless heartbeat POST crash-looped the process on every first beat.
fn normalizePayload(method: ?Method, body: ?[]const u8) ?[]const u8 {
    if (body != null) return body;
    return switch (method orelse .GET) {
        .POST, .PUT, .PATCH => "",
        else => null,
    };
}

test "normalizePayload gives body-carrying methods an empty body" {
    try std.testing.expectEqualStrings("", normalizePayload(.POST, null).?);
    try std.testing.expectEqualStrings("", normalizePayload(.PUT, null).?);
    try std.testing.expectEqualStrings("", normalizePayload(.PATCH, null).?);
    try std.testing.expect(normalizePayload(.GET, null) == null);
    try std.testing.expect(normalizePayload(null, null) == null);
    try std.testing.expectEqualStrings("x", normalizePayload(.POST, "x").?);
    try std.testing.expectEqualStrings("x", normalizePayload(.GET, "x").?);
}

test "request against a server that never answers fails at the deadline" {
    const io = std.testing.io;
    const addr: Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    // The kernel completes the handshake from the backlog; nothing ever accepts.
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});

    var client: Client = .init(std.testing.allocator, io);
    defer client.deinit();
    client.deadline = .fromMilliseconds(200);

    try std.testing.expectError(error.RequestDeadlineExceeded, client.request(.{ .url = url }));
}
