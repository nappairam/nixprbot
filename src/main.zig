const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const db_mod = @import("db.zig");
const http = @import("http.zig");
const telegram = @import("telegram.zig");
const github = @import("github.zig");
const commands = @import("commands.zig");
const poller = @import("poller.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = timestampedLog,
};

var shutdown_flag: std.atomic.Value(bool) = .init(false);

fn shutdownHandler(_: std.posix.SIG) callconv(.c) void {
    shutdown_flag.store(true, .seq_cst);
}

fn installSignalHandlers() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = shutdownHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

fn timestampedLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    const day_secs: u64 = @as(u64, @intCast(@mod(ts.sec, 86400)));
    const h = day_secs / 3600;
    const m = (day_secs % 3600) / 60;
    const s = day_secs % 60;
    const ms: u32 = @intCast(@divTrunc(ts.nsec, 1_000_000));
    std.debug.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s}: ", .{
        h, m, s, ms, comptime level.asText(),
    });
    std.debug.print(format ++ "\n", args);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var cfg = try config.load(gpa, init.environ_map);
    defer cfg.deinit();

    const db_path_z = try gpa.dupeZ(u8, cfg.db_path);
    defer gpa.free(db_path_z);
    var db = try db_mod.Db.open(db_path_z);
    defer db.close();

    var http_client = http.Client.init(gpa, io);
    defer http_client.deinit();

    var tg = telegram.Client.init(gpa, &http_client, cfg.bot_token);
    var gh = github.Client.init(gpa, &http_client, cfg.github_token, cfg.repo);
    var tracker = poller.Tracker.init(gpa, &db, &gh, &tg, cfg.branches);

    installSignalHandlers();

    tg.setMyCommands(&.{
        .{ .command = "track", .description = "Track a PR (e.g. /track 312345)" },
        .{ .command = "untrack", .description = "Stop tracking a PR" },
        .{ .command = "list", .description = "List tracked PRs" },
        .{ .command = "status", .description = "Show current status of a PR" },
        .{ .command = "help", .description = "Show help" },
    }) catch |err| std.log.warn("setMyCommands failed: {s}", .{@errorName(err)});

    const has_token = cfg.github_token != null and cfg.github_token.?.len > 0;
    std.log.info("nixprbot up. db={s} interval={d}s repo={s} branches={d} gh_auth={}", .{
        cfg.db_path, cfg.poll_interval_sec, cfg.repo, cfg.branches.len, has_token,
    });

    const interval_ns: i96 = @as(i96, @intCast(cfg.poll_interval_sec)) * std.time.ns_per_s;
    const interval = Io.Clock.Duration{ .raw = .{ .nanoseconds = interval_ns }, .clock = .awake };

    var offset: i64 = 0;
    var last_status_poll = Io.Clock.Timestamp.now(io, .awake);
    // Force first iteration to poll immediately.
    last_status_poll = last_status_poll.addDuration(.{
        .raw = .{ .nanoseconds = -interval_ns },
        .clock = .awake,
    });

    while (!shutdown_flag.load(.seq_cst)) {
        const now = Io.Clock.Timestamp.now(io, .awake);
        const elapsed = last_status_poll.durationTo(now);
        const elapsed_s = @divTrunc(elapsed.raw.nanoseconds, std.time.ns_per_s);
        if (elapsed.raw.nanoseconds >= interval.raw.nanoseconds) {
            std.log.info("status poll triggered (elapsed={d}s)", .{elapsed_s});
            tracker.runOnce() catch |err| {
                std.log.warn("status poll failed: {s}", .{@errorName(err)});
            };
            last_status_poll = Io.Clock.Timestamp.now(io, .awake);
        }

        const remaining_ns = interval.raw.nanoseconds - last_status_poll.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
        const max_tg_ns: i96 = 30 * std.time.ns_per_s;
        const min_tg_ns: i96 = std.time.ns_per_s;
        const tg_ns: i96 = @max(min_tg_ns, @min(max_tg_ns, remaining_ns));
        const tg_timeout: u32 = @intCast(@divTrunc(tg_ns, std.time.ns_per_s));

        std.log.debug("telegram poll offset={d} timeout={d}s", .{ offset, tg_timeout });
        var updates = tg.getUpdates(offset, tg_timeout) catch |err| {
            std.log.warn("getUpdates failed: {s}", .{@errorName(err)});
            Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = 2 * std.time.ns_per_s }, .clock = .awake }, io) catch {};
            continue;
        };
        defer updates.deinit();

        if (updates.items().len > 0) {
            std.log.info("got {d} update(s)", .{updates.items().len});
        }
        for (updates.items()) |u| {
            commands.dispatch(gpa, &db, &tg, &tracker, cfg.branches, cfg.repo, u) catch |err| {
                std.log.warn("dispatch update {d} failed: {s}", .{ u.update_id, @errorName(err) });
            };
            offset = u.update_id + 1;
        }
    }
    std.log.info("shutdown signal received; exiting cleanly", .{});
}
