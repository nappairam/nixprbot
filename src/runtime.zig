const std = @import("std");
const Io = std.Io;
const Notify = @import("notify.zig").Notify;

/// Process-wide signals shared by the main loop and the API clients. The bot
/// is single-threaded except for signal handlers, which only store `shutdown`.
pub var shutdown: std.atomic.Value(bool) = .init(false);
pub var notify: ?*Notify = null;

pub fn ping() void {
    if (notify) |n| n.ping();
}

/// Sleep in short chunks, petting the watchdog between them and bailing out
/// on shutdown. Every sleep longer than a few seconds must go through this —
/// an unpinged 60s flood-control nap plus ping rate-limiting is enough to
/// blow the 120s watchdog budget.
pub fn sleepInterruptible(io: Io, total_ns: u64) void {
    const chunk_ns: u64 = 5 * std.time.ns_per_s;
    var remaining = total_ns;
    while (remaining > 0) {
        if (shutdown.load(.seq_cst)) return;
        ping();
        const step = @min(chunk_ns, remaining);
        Io.Clock.Duration.sleep(.{
            .raw = .{ .nanoseconds = @intCast(step) },
            .clock = .awake,
        }, io) catch return;
        remaining -= step;
    }
    ping();
}

test "ping without a notify instance is a no-op" {
    notify = null;
    ping();
}
