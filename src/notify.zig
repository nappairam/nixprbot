const std = @import("std");

/// Minimal sd_notify(3) client. Everything degrades to a no-op when
/// NOTIFY_SOCKET is absent, so the binary runs unchanged outside systemd.
pub const Notify = struct {
    allocator: std.mem.Allocator,
    socket_path: ?[]const u8,
    watchdog_interval_ns: ?u64,
    last_ping_ns: i128 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        notify_socket: ?[]const u8,
        watchdog_usec: ?[]const u8,
    ) !Notify {
        const path: ?[]const u8 = if (notify_socket) |p|
            try allocator.dupe(u8, p)
        else
            null;

        var watchdog_ns: ?u64 = null;
        if (watchdog_usec) |s| {
            if (std.fmt.parseInt(u64, s, 10)) |usec| {
                if (usec > 0 and usec <= std.math.maxInt(u64) / std.time.ns_per_us) {
                    watchdog_ns = usec * std.time.ns_per_us;
                }
            } else |_| {}
        }

        return .{
            .allocator = allocator,
            .socket_path = path,
            .watchdog_interval_ns = watchdog_ns,
        };
    }

    pub fn deinit(self: *Notify) void {
        if (self.socket_path) |p| self.allocator.free(p);
    }

    pub fn ready(self: *Notify) void {
        self.send("READY=1");
    }

    pub fn stopping(self: *Notify) void {
        self.send("STOPPING=1");
    }

    /// Pet the watchdog, rate-limited to half of WATCHDOG_USEC so callers can
    /// invoke it as often as they like (every loop iteration, every PR).
    pub fn ping(self: *Notify) void {
        const interval = self.watchdog_interval_ns orelse return;
        const now = monotonicNs();
        if (now - self.last_ping_ns < interval / 2) return;
        self.last_ping_ns = now;
        self.send("WATCHDOG=1");
    }

    // Raw libc calls: Zig 0.16 removed the std.posix socket wrappers and the
    // std.Io net layer has no unix-datagram support. libc is linked anyway
    // (sqlite), and a failed notification must never disturb the caller.
    fn send(self: *Notify, msg: []const u8) void {
        const path = self.socket_path orelse return;
        if (path.len == 0) return;

        const fd = std.c.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
            0,
        );
        if (fd < 0) return;
        defer _ = std.c.close(fd);

        var addr = std.mem.zeroes(std.posix.sockaddr.un);
        addr.family = std.posix.AF.UNIX;
        if (path.len > addr.path.len) return;
        @memcpy(addr.path[0..path.len], path);
        // Leading '@' means a Linux abstract socket address.
        if (path[0] == '@') addr.path[0] = 0;

        const addr_len: std.posix.socklen_t =
            @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len);
        _ = std.c.sendto(fd, msg.ptr, msg.len, 0, @ptrCast(&addr), addr_len);
    }
};

fn monotonicNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

test "notify without socket is a no-op" {
    var n = try Notify.init(std.testing.allocator, null, null);
    defer n.deinit();
    n.ready();
    n.ping();
    n.stopping();
}

test "watchdog interval parses" {
    var n = try Notify.init(std.testing.allocator, null, "3000000");
    defer n.deinit();
    try std.testing.expectEqual(@as(?u64, 3 * std.time.ns_per_ms * 1000), n.watchdog_interval_ns);
}
