const std = @import("std");
const Db = @import("db.zig").Db;
const TelegramClient = @import("telegram.zig").Client;
const github = @import("github.zig");

pub const State = struct {
    state: []const u8,
    merged: bool,
    title: []const u8,
    html_url: []const u8,
    channels: []const ChannelState,

    pub const ChannelState = struct {
        name: []const u8,
        contains: bool,
    };
};

pub fn buildState(
    allocator: std.mem.Allocator,
    pr: github.Pr,
    channels: []const github.Channel,
) !State {
    const cs = try allocator.alloc(State.ChannelState, channels.len);
    for (channels, 0..) |c, i| {
        cs[i] = .{ .name = c.name, .contains = c.contains };
    }
    return .{
        .state = pr.state,
        .merged = pr.merged,
        .title = pr.title,
        .html_url = pr.html_url,
        .channels = cs,
    };
}

pub fn stateToJson(allocator: std.mem.Allocator, s: State) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    try std.json.Stringify.value(s, .{}, &buf.writer);
    return buf.toOwnedSlice();
}

pub fn formatNotification(
    allocator: std.mem.Allocator,
    pr_number: i64,
    prev_json: ?[]const u8,
    new_state: State,
) !?[]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    if (prev_json == null) {
        try buf.writer.print("Now tracking PR #{d}: {s}\n{s}\n", .{
            pr_number, new_state.title, new_state.html_url,
        });
        try writeStatus(&buf.writer, new_state);
        return try buf.toOwnedSlice();
    }

    const prev = try std.json.parseFromSlice(
        State,
        allocator,
        prev_json.?,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer prev.deinit();

    var changes: usize = 0;
    try buf.writer.print("PR #{d}: {s}\n{s}\n", .{
        pr_number, new_state.title, new_state.html_url,
    });

    if (!std.mem.eql(u8, prev.value.state, new_state.state) or prev.value.merged != new_state.merged) {
        const prev_label = stateLabel(prev.value);
        const new_label = stateLabel(new_state);
        try buf.writer.print("- state: {s} -> {s}\n", .{ prev_label, new_label });
        changes += 1;
    }

    for (new_state.channels) |nc| {
        const prev_contains = findChannel(prev.value.channels, nc.name) orelse false;
        if (prev_contains != nc.contains) {
            const arrow = if (nc.contains) "reached" else "left";
            try buf.writer.print("- {s} {s}\n", .{ arrow, nc.name });
            changes += 1;
        }
    }

    if (changes == 0) {
        buf.deinit();
        return null;
    }
    return try buf.toOwnedSlice();
}

fn stateLabel(s: State) []const u8 {
    if (s.merged) return "merged";
    return s.state;
}

fn findChannel(channels: []const State.ChannelState, name: []const u8) ?bool {
    for (channels) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.contains;
    }
    return null;
}

fn writeStatus(w: *std.Io.Writer, s: State) !void {
    try w.print("State: {s}\n", .{stateLabel(s)});
    if (s.channels.len > 0) {
        try w.writeAll("Channels:\n");
        for (s.channels) |c| {
            const mark: u8 = if (c.contains) '+' else '-';
            try w.print("  [{c}] {s}\n", .{ mark, c.name });
        }
    }
}

pub fn runOnce(
    allocator: std.mem.Allocator,
    db: *Db,
    gh: *github.Client,
    tg: *TelegramClient,
    branches: []const []const u8,
) !void {
    const tracks = try db.allTracks(allocator);
    defer Db.freeTracks(allocator, tracks);
    std.log.info("poller.runOnce tracks={d}", .{tracks.len});
    if (tracks.len == 0) return;

    var i: usize = 0;
    while (i < tracks.len) {
        const pr_number = tracks[i].pr_number;
        var j = i + 1;
        while (j < tracks.len and tracks[j].pr_number == pr_number) j += 1;
        defer i = j;

        std.log.info("fetching PR #{d} ({d} subscriber(s))", .{ pr_number, j - i });
        var pr_parsed = gh.getPr(pr_number) catch |err| {
            std.log.warn("getPr {d} failed: {s}", .{ pr_number, @errorName(err) });
            continue;
        };
        defer pr_parsed.deinit();
        const pr = pr_parsed.value();
        std.log.info("PR #{d} state={s} merged={} sha={?s}", .{
            pr_number, pr.state, pr.merged, pr.merge_commit_sha,
        });

        var channels: []github.Channel = &.{};
        defer if (channels.len > 0) github.Client.freeChannels(allocator, channels);

        if (pr.merged) {
            const sha = pr.merge_commit_sha orelse "";
            if (sha.len > 0) {
                channels = gh.channelsForSha(sha, branches) catch blk: {
                    break :blk &.{};
                };
                for (channels) |c| {
                    std.log.info("  channel {s}: {}", .{ c.name, c.contains });
                }
            }
        }

        const new_state = try buildState(allocator, pr, channels);
        const new_json = try stateToJson(allocator, new_state);
        defer allocator.free(new_json);
        allocator.free(new_state.channels);

        for (tracks[i..j]) |t| {
            const note = formatNotification(allocator, pr_number, t.last_state_json, .{
                .state = pr.state,
                .merged = pr.merged,
                .title = pr.title,
                .html_url = pr.html_url,
                .channels = blk: {
                    const cs = try allocator.alloc(State.ChannelState, channels.len);
                    for (channels, 0..) |c, k| cs[k] = .{ .name = c.name, .contains = c.contains };
                    break :blk cs;
                },
            }) catch |err| {
                std.log.warn("format notification failed for {d}/{d}: {s}", .{ t.user_id, pr_number, @errorName(err) });
                continue;
            };
            defer if (note) |n| allocator.free(n);

            if (note) |n| {
                std.log.info("notify user={d} pr={d} bytes={d}", .{ t.user_id, pr_number, n.len });
                tg.sendMessage(t.user_id, n) catch |err| {
                    std.log.warn("notify {d} pr={d} failed: {s}", .{ t.user_id, pr_number, @errorName(err) });
                };
                db.updateState(t.user_id, pr_number, new_json) catch |err| {
                    std.log.warn("updateState {d}/{d} failed: {s}", .{ t.user_id, pr_number, @errorName(err) });
                };
            } else {
                std.log.info("no change for user={d} pr={d}", .{ t.user_id, pr_number });
            }
        }
    }
}

test "formatNotification new track" {
    const a = std.testing.allocator;
    const channels = [_]State.ChannelState{
        .{ .name = "master", .contains = false },
    };
    const new_state: State = .{
        .state = "open",
        .merged = false,
        .title = "fix foo",
        .html_url = "https://github.com/NixOS/nixpkgs/pull/1",
        .channels = &channels,
    };
    const out = try formatNotification(a, 1, null, new_state);
    try std.testing.expect(out != null);
    defer a.free(out.?);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "Now tracking") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "fix foo") != null);
}

test "formatNotification no change" {
    const a = std.testing.allocator;
    const prev_json =
        \\{"state":"open","merged":false,"title":"fix foo",
        \\ "html_url":"https://github.com/x/y/pull/1",
        \\ "channels":[{"name":"master","contains":false}]}
    ;
    const channels = [_]State.ChannelState{
        .{ .name = "master", .contains = false },
    };
    const new_state: State = .{
        .state = "open",
        .merged = false,
        .title = "fix foo",
        .html_url = "https://github.com/x/y/pull/1",
        .channels = &channels,
    };
    const out = try formatNotification(a, 1, prev_json, new_state);
    try std.testing.expect(out == null);
}

test "formatNotification channel reached" {
    const a = std.testing.allocator;
    const prev_json =
        \\{"state":"open","merged":true,"title":"t","html_url":"u",
        \\ "channels":[{"name":"master","contains":false},{"name":"nixos-unstable","contains":false}]}
    ;
    const channels = [_]State.ChannelState{
        .{ .name = "master", .contains = true },
        .{ .name = "nixos-unstable", .contains = false },
    };
    const new_state: State = .{
        .state = "closed",
        .merged = true,
        .title = "t",
        .html_url = "u",
        .channels = &channels,
    };
    const out = try formatNotification(a, 5, prev_json, new_state);
    try std.testing.expect(out != null);
    defer a.free(out.?);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "reached master") != null);
}
