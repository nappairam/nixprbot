const std = @import("std");
const http = @import("http.zig");

pub const default_repo = "NixOS/nixpkgs";
pub const user_agent = "nixprbot/0.2";

pub const Error = error{
    GithubNotFound,
    /// Token rejected (expired, revoked, wrong scope). Permanent until the
    /// operator fixes it — callers must not treat this as a transient blip.
    GithubUnauthorized,
    /// Primary or secondary rate limit hit — back off, don't hammer.
    GithubRateLimited,
    GithubHttpError,
};

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

pub const Client = struct {
    http: *http.Client,
    allocator: std.mem.Allocator,
    token: []const u8,
    repo: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        http_client: *http.Client,
        token: []const u8,
        repo: []const u8,
    ) Client {
        return .{ .http = http_client, .allocator = allocator, .token = token, .repo = repo };
    }

    fn defaultHeaders(self: *Client, allocator: std.mem.Allocator) ![]http.Header {
        const headers = try allocator.alloc(http.Header, 4);
        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.token});
        headers[0] = .{ .name = "authorization", .value = auth };
        headers[1] = .{ .name = "user-agent", .value = user_agent };
        headers[2] = .{ .name = "accept", .value = "application/vnd.github+json" };
        headers[3] = .{ .name = "x-github-api-version", .value = "2022-11-28" };
        return headers;
    }

    fn statusToError(status: std.http.Status) Error {
        return switch (status) {
            .not_found => Error.GithubNotFound,
            .unauthorized => Error.GithubUnauthorized,
            // GitHub signals both primary and secondary rate limits as 403
            // (some newer endpoints use 429).
            .forbidden, .too_many_requests => Error.GithubRateLimited,
            else => Error.GithubHttpError,
        };
    }

    /// Validate the token and report remaining core quota. /rate_limit is
    /// itself free — it never consumes quota.
    pub fn checkAuth(self: *Client) !u64 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const headers = try self.defaultHeaders(a);
        var resp = try self.http.request(.{
            .url = "https://api.github.com/rate_limit",
            .headers = headers,
        });
        defer resp.deinit();

        if (resp.status != .ok) {
            std.log.warn("github rate_limit status={d} body={s}", .{
                @intFromEnum(resp.status), resp.body,
            });
            return statusToError(resp.status);
        }

        const Envelope = struct {
            resources: struct {
                core: struct { limit: u64, remaining: u64 },
            },
        };
        const parsed = try std.json.parseFromSlice(Envelope, a, resp.body, .{
            .ignore_unknown_fields = true,
        });
        return parsed.value.resources.core.remaining;
    }

    pub fn getPr(self: *Client, pr_number: i64) !PrParsed {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const url = try std.fmt.allocPrint(
            a,
            "https://api.github.com/repos/{s}/pulls/{d}",
            .{ self.repo, pr_number },
        );
        const headers = try self.defaultHeaders(a);

        var resp = try self.http.request(.{ .url = url, .headers = headers });
        defer resp.deinit();

        if (resp.status != .ok) {
            if (resp.status != .not_found) {
                std.log.warn("github getPr {d} status={d} body={s}", .{
                    pr_number, @intFromEnum(resp.status), resp.body,
                });
            }
            return statusToError(resp.status);
        }

        const parsed = try std.json.parseFromSlice(
            Pr,
            self.allocator,
            resp.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        return .{ .parsed = parsed };
    }

    /// Returns true when commit_sha is reachable from branch HEAD using the
    /// compare endpoint: status "identical" or "behind" means the commit is
    /// an ancestor of branch.
    ///
    /// page=2&per_page=1 keeps the response small: the top-level status field
    /// is present on every page, while the commit list and the file diffs
    /// (up to 300 entries with full patch text — megabytes for a diverged
    /// nixpkgs compare) are only served on page 1.
    pub fn commitInBranch(self: *Client, branch: []const u8, commit_sha: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const url = try std.fmt.allocPrint(
            a,
            "https://api.github.com/repos/{s}/compare/{s}...{s}?per_page=1&page=2",
            .{ self.repo, branch, commit_sha },
        );
        const headers = try self.defaultHeaders(a);

        var resp = try self.http.request(.{ .url = url, .headers = headers });
        defer resp.deinit();

        if (resp.status == .not_found) return false;
        if (resp.status != .ok) {
            std.log.warn("github compare {s}...{s} status={d}", .{
                branch, commit_sha, @intFromEnum(resp.status),
            });
            return statusToError(resp.status);
        }

        const Envelope = struct { status: []const u8 };
        const parsed = try std.json.parseFromSlice(
            Envelope,
            self.allocator,
            resp.body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        return std.mem.eql(u8, parsed.value.status, "identical") or
            std.mem.eql(u8, parsed.value.status, "behind");
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
