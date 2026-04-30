const std = @import("std");

pub const Config = struct {
    bot_token: []const u8,
    github_token: []const u8,
    db_path: []const u8,
    poll_interval_sec: u64,
    channels: []const []const u8,

    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub const ConfigError = error{
    MissingBotToken,
    MissingGithubToken,
    InvalidPollInterval,
};

const default_db_path = "nixprbot.sqlite";
const default_poll_interval_sec: u64 = 900;
const default_channels = "staging,staging-next,master,nixpkgs-unstable,nixos-unstable";

pub fn load(parent_allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !Config {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const bot_token = env.get("BOT_TOKEN") orelse return ConfigError.MissingBotToken;
    const github_token = env.get("GITHUB_TOKEN") orelse return ConfigError.MissingGithubToken;
    const db_path = env.get("DB_PATH") orelse default_db_path;

    const poll_interval_sec = if (env.get("POLL_INTERVAL_SEC")) |s|
        std.fmt.parseInt(u64, s, 10) catch return ConfigError.InvalidPollInterval
    else
        default_poll_interval_sec;

    const channels_csv = env.get("CHANNELS") orelse default_channels;
    const channels = try splitCsv(a, channels_csv);

    return .{
        .bot_token = try a.dupe(u8, bot_token),
        .github_token = try a.dupe(u8, github_token),
        .db_path = try a.dupe(u8, db_path),
        .poll_interval_sec = poll_interval_sec,
        .channels = channels,
        .arena = arena,
    };
}

fn splitCsv(a: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(a);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        try list.append(a, try a.dupe(u8, trimmed));
    }
    return list.toOwnedSlice(a);
}

test "splitCsv basic" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const out = try splitCsv(arena.allocator(), "a,b, c , ,d");
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualStrings("a", out[0]);
    try std.testing.expectEqualStrings("b", out[1]);
    try std.testing.expectEqualStrings("c", out[2]);
    try std.testing.expectEqualStrings("d", out[3]);
}
