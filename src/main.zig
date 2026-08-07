const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const db_mod = @import("db.zig");
const http = @import("http.zig");
const telegram = @import("telegram.zig");
const github = @import("github.zig");
const commands = @import("commands.zig");
const tracker_mod = @import("tracker.zig");
const backoff_mod = @import("backoff.zig");
const notify_mod = @import("notify.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = timestampedLog,
};

var runtime_log_level: std.log.Level = .info;

var shutdown_flag: std.atomic.Value(bool) = .init(false);

// Crash-only failure policy: the process never tries to out-clever a broken
// transport. Consecutive Telegram poll failures exhaust a budget and the
// process exits; systemd restarts it with a genuinely fresh state. The
// previous deployment wedged for 68 days precisely because it retried a
// poisoned HTTP client in-process forever.
const max_consecutive_tg_failures = 15;
const github_unauthorized_pause_sec = 3600;
const github_ratelimit_pause_sec = 900;

const offset_key = "tg_offset";
const auth_alert_key = "gh_auth_alerted";

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

var stderr_color_state: enum(u8) { unknown, on, off } = .unknown;

fn stderrIsTty() bool {
    return switch (stderr_color_state) {
        .unknown => blk: {
            const tty = std.c.isatty(std.posix.STDERR_FILENO) != 0;
            stderr_color_state = if (tty) .on else .off;
            break :blk tty;
        },
        .on => true,
        .off => false,
    };
}

fn timestampedLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;

    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    const day_secs: u64 = @as(u64, @intCast(@mod(ts.sec, 86400)));
    const h = day_secs / 3600;
    const m = (day_secs % 3600) / 60;
    const s = day_secs % 60;
    const ms: u32 = @intCast(@divTrunc(ts.nsec, 1_000_000));

    const color: []const u8 = comptime switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[32m",
        .debug => "\x1b[35m",
    };
    const reset = "\x1b[0m";
    if (stderrIsTty()) {
        std.debug.print("\x1b[2m{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{s} {s}{s}{s}: ", .{
            h, m, s, ms, reset, color, comptime level.asText(), reset,
        });
    } else {
        std.debug.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s}: ", .{
            h, m, s, ms, comptime level.asText(),
        });
    }
    std.debug.print(format ++ "\n", args);
}

fn nowSeedNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(u64, @bitCast(@as(i64, ts.sec) *% std.time.ns_per_s +% ts.nsec));
}

fn sleepNs(io: Io, ns: u64) void {
    Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = @intCast(ns) },
        .clock = .awake,
    }, io) catch {};
}

/// Tell every subscribed chat that GitHub auth is broken (once per episode)
/// or restored. The bot must never fail silently the way its python
/// predecessor did — 401 for five days straight, visible only in journald.
fn alertGithubAuth(gpa: std.mem.Allocator, db: *db_mod.Db, tg: *telegram.Client, broken: bool) void {
    const already = (db.kvGetInt(auth_alert_key) catch null) orelse 0;
    if (broken and already != 0) return;
    if (!broken and already == 0) return;

    const text = if (broken)
        "⚠️ GitHub rejected the bot's token (401). PR tracking is paused; commands still work. Fix NIXPRBOT_GITHUB_TOKEN and the bot will recover on its own."
    else
        "✅ GitHub auth restored; PR tracking resumed.";

    const chats = db.allChats(gpa) catch |err| {
        std.log.warn("auth alert: allChats failed: {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(chats);
    for (chats) |chat_id| {
        tg.sendMessage(chat_id, text) catch |err| {
            std.log.warn("auth alert chat={d}: {s}", .{ chat_id, @errorName(err) });
        };
    }

    if (broken) {
        db.kvSetInt(auth_alert_key, 1) catch {};
    } else {
        db.kvDelete(auth_alert_key) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var cfg = try config.load(gpa, env);
    defer cfg.deinit();
    runtime_log_level = cfg.log_level;

    var notify = try notify_mod.Notify.init(gpa, env.get("NOTIFY_SOCKET"), env.get("WATCHDOG_USEC"));
    defer notify.deinit();

    const db_path_z = try gpa.dupeZ(u8, cfg.db_path);
    defer gpa.free(db_path_z);
    var db = try db_mod.Db.open(db_path_z);
    defer db.close();

    var http_client = http.Client.init(gpa, io);
    defer http_client.deinit();

    var tg = telegram.Client.init(gpa, &http_client, cfg.bot_token);
    var gh = github.Client.init(gpa, &http_client, cfg.github_token, cfg.repo);
    var tracker = tracker_mod.Tracker.init(gpa, &db, &gh, &tg, cfg.branches, &notify);

    installSignalHandlers();

    tg.setMyCommands(&.{
        .{ .command = "track", .description = "Track a PR (e.g. /track 312345)" },
        .{ .command = "untrack", .description = "Stop tracking a PR" },
        .{ .command = "list", .description = "List tracked PRs" },
        .{ .command = "status", .description = "Show current status of a PR" },
        .{ .command = "help", .description = "Show help" },
    }) catch |err| std.log.warn("setMyCommands failed: {s}", .{@errorName(err)});

    // Not fatal on failure: the bot must come up (and be able to explain
    // itself over Telegram) even while the GitHub token is broken.
    if (gh.checkAuth()) |remaining| {
        std.log.info("github auth ok; core quota remaining={d}", .{remaining});
    } else |err| {
        std.log.err("github auth check failed: {s}", .{@errorName(err)});
    }

    std.log.info("nixprbot up. db={s} interval={d}s repo={s} branches={d}", .{
        cfg.db_path, cfg.poll_interval_sec, cfg.repo, cfg.branches.len,
    });
    notify.ready();

    const interval_ns: i96 = @as(i96, @intCast(cfg.poll_interval_sec)) * std.time.ns_per_s;

    var offset: i64 = (db.kvGetInt(offset_key) catch null) orelse 0;
    var last_status_poll = Io.Clock.Timestamp.now(io, .awake);
    // Force first iteration to poll immediately.
    last_status_poll = last_status_poll.addDuration(.{
        .raw = .{ .nanoseconds = -interval_ns },
        .clock = .awake,
    });

    var tg_failures: u32 = 0;
    var tg_backoff = backoff_mod.Backoff.init(nowSeedNs(), std.time.ns_per_s, 60 * std.time.ns_per_s);
    var github_paused_ns: i96 = 0;

    while (!shutdown_flag.load(.seq_cst)) {
        notify.ping();

        const now = Io.Clock.Timestamp.now(io, .awake);
        const elapsed_ns = last_status_poll.durationTo(now).raw.nanoseconds;
        const effective_interval = interval_ns + github_paused_ns;
        if (elapsed_ns >= effective_interval) {
            std.log.info("status poll triggered (elapsed={d}s)", .{@divTrunc(elapsed_ns, std.time.ns_per_s)});
            if (tracker.runOnce()) {
                github_paused_ns = 0;
                alertGithubAuth(gpa, &db, &tg, false);
            } else |err| switch (err) {
                error.GithubUnauthorized => {
                    std.log.err("github auth failed; pausing tracking for {d}s", .{github_unauthorized_pause_sec});
                    github_paused_ns = @max(0, @as(i96, github_unauthorized_pause_sec) * std.time.ns_per_s - interval_ns);
                    alertGithubAuth(gpa, &db, &tg, true);
                },
                error.GithubRateLimited => {
                    std.log.warn("github rate limited; pausing tracking for {d}s", .{github_ratelimit_pause_sec});
                    github_paused_ns = @max(0, @as(i96, github_ratelimit_pause_sec) * std.time.ns_per_s - interval_ns);
                },
                else => std.log.warn("status poll failed: {s}", .{@errorName(err)}),
            }
            last_status_poll = Io.Clock.Timestamp.now(io, .awake);
        }

        const since_poll = last_status_poll.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
        const remaining_ns = effective_interval - since_poll;
        const max_tg_ns: i96 = 30 * std.time.ns_per_s;
        const min_tg_ns: i96 = std.time.ns_per_s;
        const tg_ns: i96 = @max(min_tg_ns, @min(max_tg_ns, remaining_ns));
        const tg_timeout: u32 = @intCast(@divTrunc(tg_ns, std.time.ns_per_s));

        std.log.debug("telegram poll offset={d} timeout={d}s", .{ offset, tg_timeout });
        var updates = tg.getUpdates(offset, tg_timeout) catch |err| {
            switch (err) {
                error.TelegramUnauthorized => {
                    std.log.err("bot token rejected; exiting", .{});
                    std.process.exit(1);
                },
                error.TelegramConflict => {
                    // Another poller owns this token (stale deploy overlap?).
                    // Exit and let systemd's restart backoff arbitrate.
                    std.log.err("getUpdates conflict: another poller is active; exiting", .{});
                    std.process.exit(1);
                },
                else => {},
            }
            tg_failures += 1;
            if (tg_failures >= max_consecutive_tg_failures) {
                std.log.err("getUpdates failed {d} times in a row ({s}); exiting for a fresh start", .{
                    tg_failures, @errorName(err),
                });
                std.process.exit(1);
            }
            const delay = tg_backoff.next();
            std.log.warn("getUpdates failed ({s}); retry {d}/{d} in {d}ms", .{
                @errorName(err), tg_failures, max_consecutive_tg_failures, delay / std.time.ns_per_ms,
            });
            sleepNs(io, delay);
            continue;
        };
        defer updates.deinit();
        tg_failures = 0;
        tg_backoff.reset();

        if (updates.items().len > 0) {
            std.log.info("got {d} update(s)", .{updates.items().len});
        }
        for (updates.items()) |u| {
            notify.ping();
            commands.dispatch(gpa, &db, &tg, &tracker, cfg.branches, cfg.repo, u) catch |err| {
                std.log.warn("dispatch update {d} failed: {s}", .{ u.update_id, @errorName(err) });
            };
            // Advance past failed updates too — a poison message must not
            // wedge the queue.
            offset = u.update_id + 1;
        }
        if (updates.items().len > 0) {
            db.kvSetInt(offset_key, offset) catch |err| {
                std.log.warn("persist offset: {s}", .{@errorName(err)});
            };
        }
    }
    std.log.info("shutdown signal received; exiting cleanly", .{});
    notify.stopping();
}
