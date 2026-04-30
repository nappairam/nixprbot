const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const db_mod = @import("db.zig");
const http = @import("http.zig");
const telegram = @import("telegram.zig");
const github = @import("github.zig");
const commands = @import("commands.zig");
const poller = @import("poller.zig");

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

    std.log.info("nixprbot up. db={s} interval={d}s repo={s} branches={d}", .{
        cfg.db_path, cfg.poll_interval_sec, cfg.repo, cfg.branches.len,
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

    while (true) {
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
            commands.dispatch(gpa, &db, &tg, &tracker, cfg.branches, u) catch |err| {
                std.log.warn("dispatch update {d} failed: {s}", .{ u.update_id, @errorName(err) });
            };
            offset = u.update_id + 1;
        }
    }
}
