const std = @import("std");
const http = @import("http.zig");

pub const repo_owner = "NixOS";
pub const repo_name = "nixpkgs";
pub const user_agent = "nixprbot/0.1";

pub const Pr = struct {
    number: i64,
    state: []const u8,
    merged: bool,
    merge_commit_sha: ?[]const u8,
    title: []const u8,
    html_url: []const u8,
};

pub const PrParsed = struct {
    parsed: std.json.Parsed(Pr),

    pub fn deinit(self: *PrParsed) void {
        self.parsed.deinit();
    }

    pub fn value(self: *const PrParsed) Pr {
        return self.parsed.value;
    }
};

pub const Channel = struct {
    name: []const u8,
    contains: bool,
};

pub const Client = struct {
    http: *http.Client,
    allocator: std.mem.Allocator,
    token: []const u8,

    pub fn init(allocator: std.mem.Allocator, http_client: *http.Client, token: []const u8) Client {
        return .{ .http = http_client, .allocator = allocator, .token = token };
    }

    fn authHeader(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "Bearer {s}", .{self.token});
    }

    fn defaultHeaders(self: *Client, allocator: std.mem.Allocator) ![]http.Header {
        const auth = try self.authHeader(allocator);
        const headers = try allocator.alloc(http.Header, 3);
        headers[0] = .{ .name = "authorization", .value = auth };
        headers[1] = .{ .name = "user-agent", .value = user_agent };
        headers[2] = .{ .name = "accept", .value = "application/vnd.github+json" };
        return headers;
    }

    pub fn getPr(self: *Client, pr_number: i64) !PrParsed {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const url = try std.fmt.allocPrint(
            a,
            "https://api.github.com/repos/{s}/{s}/pulls/{d}",
            .{ repo_owner, repo_name, pr_number },
        );
        const headers = try self.defaultHeaders(a);

        var resp = try self.http.request(.{ .url = url, .headers = headers });
        defer resp.deinit();

        if (resp.status != .ok) {
            std.log.warn("github getPr {d} status={d} body={s}", .{
                pr_number, @intFromEnum(resp.status), resp.body,
            });
            return error.GithubHttpError;
        }

        const parsed = try std.json.parseFromSlice(
            Pr,
            self.allocator,
            resp.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        return .{ .parsed = parsed };
    }

    pub fn compareStatus(self: *Client, base: []const u8, head: []const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const url = try std.fmt.allocPrint(
            a,
            "https://api.github.com/repos/{s}/{s}/compare/{s}...{s}",
            .{ repo_owner, repo_name, base, head },
        );
        const headers = try self.defaultHeaders(a);

        var resp = try self.http.request(.{ .url = url, .headers = headers });
        defer resp.deinit();

        if (resp.status == .not_found) return self.allocator.dupe(u8, "unknown");
        if (resp.status != .ok) {
            std.log.warn("github compare {s}...{s} status={d}", .{ base, head, @intFromEnum(resp.status) });
            return error.GithubHttpError;
        }

        const Envelope = struct { status: []const u8 };
        const parsed = try std.json.parseFromSlice(
            Envelope,
            self.allocator,
            resp.body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        return self.allocator.dupe(u8, parsed.value.status);
    }

    /// Returns slice of channels with `contains` indicating whether the
    /// merge commit is reachable from each branch. Caller frees with
    /// `freeChannels`. Channel order matches input.
    pub fn channelsForSha(
        self: *Client,
        sha: []const u8,
        branches: []const []const u8,
    ) ![]Channel {
        var out = try self.allocator.alloc(Channel, branches.len);
        errdefer self.allocator.free(out);
        for (branches, 0..) |branch, i| {
            const status = self.compareStatus(branch, sha) catch |err| {
                std.log.warn("compare {s}...{s} failed: {s}", .{ branch, sha, @errorName(err) });
                out[i] = .{ .name = try self.allocator.dupe(u8, branch), .contains = false };
                continue;
            };
            defer self.allocator.free(status);
            const contains = std.mem.eql(u8, status, "behind") or std.mem.eql(u8, status, "identical");
            out[i] = .{ .name = try self.allocator.dupe(u8, branch), .contains = contains };
        }
        return out;
    }

    pub fn freeChannels(allocator: std.mem.Allocator, channels: []Channel) void {
        for (channels) |c| allocator.free(c.name);
        allocator.free(channels);
    }
};

test "Pr deserializes minimal" {
    const a = std.testing.allocator;
    const json =
        \\{"number":42,"state":"open","merged":false,"merge_commit_sha":null,
        \\ "title":"foo","html_url":"https://github.com/x/y/pull/42","extra":"ignored"}
    ;
    const parsed = try std.json.parseFromSlice(
        Pr,
        a,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.number);
    try std.testing.expectEqualStrings("open", parsed.value.state);
    try std.testing.expect(!parsed.value.merged);
    try std.testing.expect(parsed.value.merge_commit_sha == null);
}
