const std = @import("std");
const Io = std.Io;
const net = Io.net;

/// Periodically opens short-lived TCP connections to a host over each address
/// family and tallies how many complete. Each connect gets a fresh ephemeral
/// source port, so a path that drops a fixed share of flows (an ECMP member
/// blackholing its hash bucket) shows up as that share of timeouts.
pub const Tally = struct {
    ok: u32 = 0,
    timeout: u32 = 0,
    err: u32 = 0,

    pub fn add(self: *Tally, other: Tally) void {
        self.ok += other.ok;
        self.timeout += other.timeout;
        self.err += other.err;
    }

    pub fn total(self: Tally) u32 {
        return self.ok + self.timeout + self.err;
    }
};

pub const Round = struct {
    v6: Tally = .{},
    v4: Tally = .{},

    pub fn add(self: *Round, other: Round) void {
        self.v6.add(other.v6);
        self.v4.add(other.v4);
    }
};

pub const Prober = struct {
    io: Io,
    host: []const u8,
    port: u16 = 443,
    per_family: u8 = 16,
    connect_timeout: Io.Duration = .fromSeconds(3),
    interval: Io.Duration = .fromSeconds(5 * 60),
    summary_every: Io.Duration = .fromSeconds(60 * 60),

    last_round: ?Io.Clock.Timestamp = null,
    window_start: ?Io.Clock.Timestamp = null,
    window: Round = .{},

    pub fn init(io: Io, host: []const u8) Prober {
        return .{ .io = io, .host = host };
    }

    /// Runs a round if one is due and returns the closed summary window's
    /// totals once `summary_every` has elapsed.
    pub fn tick(self: *Prober) ?Round {
        const now = Io.Clock.Timestamp.now(self.io, .awake);
        if (!self.due(now)) return null;
        return self.record(now, self.run());
    }

    fn due(self: *const Prober, now: Io.Clock.Timestamp) bool {
        const last = self.last_round orelse return true;
        return last.durationTo(now).raw.nanoseconds >= self.interval.nanoseconds;
    }

    fn record(self: *Prober, now: Io.Clock.Timestamp, round: Round) ?Round {
        self.last_round = now;
        const start = self.window_start orelse now;
        self.window_start = start;
        self.window.add(round);
        if (start.durationTo(now).raw.nanoseconds < self.summary_every.nanoseconds) return null;
        const closed = self.window;
        self.window = .{};
        self.window_start = now;
        return closed;
    }

    pub fn run(self: *Prober) Round {
        const addrs = resolve(self.io, self.host, self.port) catch |err| {
            std.log.warn("netprobe: resolve {s}: {s}", .{ self.host, @errorName(err) });
            return .{};
        };
        const round: Round = .{
            .v6 = if (addrs.v6) |a| self.probe(a) else .{},
            .v4 = if (addrs.v4) |a| self.probe(a) else .{},
        };
        std.log.info("netprobe {s} v6 ok={d} timeout={d} err={d} | v4 ok={d} timeout={d} err={d}", .{
            self.host,
            round.v6.ok,
            round.v6.timeout,
            round.v6.err,
            round.v4.ok,
            round.v4.timeout,
            round.v4.err,
        });
        return round;
    }

    const Outcome = enum { ok, err };
    const Race = union(enum) {
        attempt: Outcome,
        deadline: Io.Cancelable!void,
    };

    fn attempt(io: Io, addr: net.IpAddress) Outcome {
        const stream = addr.connect(io, .{ .mode = .stream }) catch return .err;
        stream.close(io);
        return .ok;
    }

    /// All attempts run at once against one shared deadline; whatever has not
    /// connected when it fires is a timeout. std's connect panics on a
    /// timeout option, hence the race.
    fn probe(self: *Prober, addr: net.IpAddress) Tally {
        var buf: [256 + 1]Race = undefined;
        var race: Io.Select(Race) = .init(self.io, buf[0 .. @as(usize, self.per_family) + 1]);
        defer race.cancelDiscard();

        var tally: Tally = .{};
        var launched: u32 = 0;
        for (0..self.per_family) |_| {
            race.concurrent(.attempt, attempt, .{ self.io, addr }) catch {
                tally.err += 1;
                continue;
            };
            launched += 1;
        }
        race.concurrent(.deadline, Io.sleep, .{ self.io, self.connect_timeout, .awake }) catch {
            // No timer means no bound; count what is outstanding as errors.
            tally.err += launched;
            return tally;
        };

        var settled: u32 = 0;
        while (settled < launched) {
            const r = race.await() catch break;
            switch (r) {
                .attempt => |o| switch (o) {
                    .ok => tally.ok += 1,
                    .err => tally.err += 1,
                },
                .deadline => break,
            }
            settled += 1;
        }
        tally.timeout += launched - settled;
        return tally;
    }
};

const Resolved = struct { v6: ?net.IpAddress = null, v4: ?net.IpAddress = null };

fn resolve(io: Io, host: []const u8, port: u16) !Resolved {
    const name = try net.HostName.init(host);
    var buf: [32]net.HostName.LookupResult = undefined;
    var queue: Io.Queue(net.HostName.LookupResult) = .init(&buf);
    try name.lookup(io, &queue, .{ .port = port });

    var out: Resolved = .{};
    while (queue.getOne(io)) |r| switch (r) {
        .address => |a| switch (a) {
            .ip6 => if (out.v6 == null) {
                out.v6 = a;
            },
            .ip4 => if (out.v4 == null) {
                out.v4 = a;
            },
        },
        .canonical_name => {},
    } else |err| switch (err) {
        error.Closed => {},
        error.Canceled => |e| return e,
    }
    return out;
}

/// "v6 14/16 timeout=2 err=0 | v4 16/16 timeout=0 err=0"
pub fn formatRound(buf: []u8, r: Round) []const u8 {
    return std.fmt.bufPrint(buf, "v6 {d}/{d} timeout={d} err={d} | v4 {d}/{d} timeout={d} err={d}", .{
        r.v6.ok, r.v6.total(), r.v6.timeout, r.v6.err,
        r.v4.ok, r.v4.total(), r.v4.timeout, r.v4.err,
    }) catch buf[0..0];
}

test "probe counts connects to a listener as ok and to a closed port as err" {
    const io = std.testing.io;
    const listen_addr: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try listen_addr.listen(io, .{ .kernel_backlog = 64 });
    defer server.deinit(io);

    var p = Prober.init(io, "localhost");
    p.per_family = 4;

    const open = p.probe(server.socket.address);
    try std.testing.expectEqual(Tally{ .ok = 4 }, open);

    // Bind then close to get a port nothing listens on.
    var gone = try listen_addr.listen(io, .{});
    const closed_addr = gone.socket.address;
    gone.deinit(io);
    const closed = p.probe(closed_addr);
    try std.testing.expectEqual(@as(u32, 4), closed.err);
}

test "rounds are spaced by interval and summed into hourly windows" {
    var p = Prober.init(std.testing.io, "unused");
    const at = struct {
        fn f(min: i96) Io.Clock.Timestamp {
            return .{ .raw = .{ .nanoseconds = min * 60 * std.time.ns_per_s }, .clock = .awake };
        }
    }.f;
    const r: Round = .{ .v6 = .{ .ok = 15, .timeout = 1 }, .v4 = .{ .ok = 16 } };

    try std.testing.expect(p.due(at(0)));
    try std.testing.expect(p.record(at(0), r) == null);
    try std.testing.expect(!p.due(at(4)));
    try std.testing.expect(p.due(at(5)));
    var m: i96 = 5;
    while (m < 60) : (m += 5) try std.testing.expect(p.record(at(m), r) == null);
    const hour = p.record(at(60), r).?;
    try std.testing.expectEqual(@as(u32, 13), hour.v6.timeout);
    try std.testing.expectEqual(@as(u32, 13 * 16), hour.v4.ok);
    try std.testing.expectEqual(Round{}, p.window);
}

test "formatRound" {
    var buf: [128]u8 = undefined;
    const s = formatRound(&buf, .{ .v6 = .{ .ok = 14, .timeout = 2 }, .v4 = .{ .ok = 16 } });
    try std.testing.expectEqualStrings("v6 14/16 timeout=2 err=0 | v4 16/16 timeout=0 err=0", s);
}
