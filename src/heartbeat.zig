const std = @import("std");
const http = @import("http.zig");

/// Dead-man's-switch ping to an external uptime service (Better Stack,
/// healthchecks.io, ...). The URL carries its own token and is therefore a
/// secret; it arrives via NIXPRBOT_HEARTBEAT_URL, never nix config.
///
/// Two signals:
///   beat() — "fully functional", pinged while healthy; prolonged silence
///            makes the receiver alert. Covers the failures the bot can't
///            see coming (crash, hang, box death).
///   fail(reason) — "degraded and I know why": POSTs <url>/fail with the
///            reason as body (healthchecks.io shows it in the alert and
///            flips the check down immediately, no grace period). Covers
///            the failures the bot CAN see, with a label.
pub const Heartbeat = struct {
    http: *http.Client,
    url: ?[]const u8,
    min_interval_ns: i128 = 60 * std.time.ns_per_s,
    last_attempt_ns: i128 = 0,
    last_kind: Kind = .none,
    note_buf: [256]u8 = undefined,
    note_len: usize = 0,

    const Kind = enum { none, ok, fail };

    pub fn init(http_client: *http.Client, url: ?[]const u8) Heartbeat {
        return .{ .http = http_client, .url = url };
    }

    pub fn enabled(self: *const Heartbeat) bool {
        return self.url != null;
    }

    /// Attach text to the next beat that gets out; healthchecks.io keeps
    /// ping bodies in its event log, which makes them a remote readout.
    pub fn setNote(self: *Heartbeat, text: []const u8) void {
        self.note_len = @min(text.len, self.note_buf.len);
        @memcpy(self.note_buf[0..self.note_len], text[0..self.note_len]);
    }

    pub fn beat(self: *Heartbeat) void {
        if (self.send(.ok, if (self.note_len > 0) self.note_buf[0..self.note_len] else null)) self.note_len = 0;
    }

    pub fn fail(self: *Heartbeat, reason: []const u8) void {
        _ = self.send(.fail, reason);
    }

    /// Same-state pings are rate-limited to one attempt a minute (counting
    /// attempts, not successes, so a down receiver isn't hammered every poll
    /// iteration). A state TRANSITION sends immediately: a fail after beats
    /// must open the incident now, and the first beat after a fail must
    /// resolve it now.
    fn gate(self: *Heartbeat, kind: Kind, now: i128) bool {
        if (kind == self.last_kind and now - self.last_attempt_ns < self.min_interval_ns) {
            return false;
        }
        self.last_attempt_ns = now;
        self.last_kind = kind;
        return true;
    }

    /// True when the receiver accepted the ping.
    fn send(self: *Heartbeat, kind: Kind, body: ?[]const u8) bool {
        const base = self.url orelse return false;
        if (!self.gate(kind, monotonicNs())) return false;

        var url_buf: [512]u8 = undefined;
        const url = switch (kind) {
            .fail => std.fmt.bufPrint(&url_buf, "{s}/fail", .{base}) catch return false,
            else => base,
        };

        var resp = self.http.request(.{
            .url = url,
            .method = .POST,
            .body = body,
            .headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        }) catch |err| {
            std.log.warn("heartbeat: {s}", .{@errorName(err)});
            return false;
        };
        defer resp.deinit();
        if (@backingInt(resp.status) >= 300) {
            std.log.warn("heartbeat status={d}", .{@backingInt(resp.status)});
            return false;
        }
        return true;
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
    hb.fail("nope");
}

test "gate rate-limits same state but passes transitions" {
    var hb = Heartbeat.init(undefined, null);
    const s = std.time.ns_per_s;
    try std.testing.expect(hb.gate(.ok, 0 * s));
    try std.testing.expect(!hb.gate(.ok, 10 * s));
    try std.testing.expect(hb.gate(.fail, 11 * s)); // transition: immediate
    try std.testing.expect(!hb.gate(.fail, 30 * s));
    try std.testing.expect(hb.gate(.ok, 31 * s)); // recovery: immediate
    try std.testing.expect(hb.gate(.ok, 95 * s)); // 64s later: past interval
}
