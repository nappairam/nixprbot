const std = @import("std");
const http = @import("http.zig");

/// Dead-man's-switch ping to an external uptime service (Better Stack,
/// healthchecks.io, ...). The URL carries its own token and is therefore a
/// secret; it arrives via NIXPRBOT_HEARTBEAT_URL, never nix config.
///
/// The caller only beats while the bot is fully functional, so a missed
/// window at the receiver means "something is silently wrong" — the failure
/// class in-process alerting can never cover.
pub const Heartbeat = struct {
    http: *http.Client,
    url: ?[]const u8,
    min_interval_ns: i128 = 60 * std.time.ns_per_s,
    last_attempt_ns: i128 = 0,

    pub fn init(http_client: *http.Client, url: ?[]const u8) Heartbeat {
        return .{ .http = http_client, .url = url };
    }

    pub fn enabled(self: *const Heartbeat) bool {
        return self.url != null;
    }

    /// Fire-and-forget: rate-limited, never propagates errors. Rate limiting
    /// counts attempts rather than successes so a down receiver is retried
    /// once a minute, not once per poll iteration.
    pub fn beat(self: *Heartbeat) void {
        const url = self.url orelse return;
        const now = monotonicNs();
        if (now - self.last_attempt_ns < self.min_interval_ns) return;
        self.last_attempt_ns = now;

        var resp = self.http.request(.{ .url = url, .method = .GET }) catch |err| {
            std.log.warn("heartbeat: {s}", .{@errorName(err)});
            return;
        };
        defer resp.deinit();
        if (@intFromEnum(resp.status) >= 300) {
            std.log.warn("heartbeat status={d}", .{@intFromEnum(resp.status)});
        }
    }
};

fn monotonicNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

test "disabled heartbeat is a no-op" {
    var hb = Heartbeat.init(undefined, null);
    try std.testing.expect(!hb.enabled());
    hb.beat();
}
