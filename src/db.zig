const std = @import("std");
const zqlite = @import("zqlite");

pub const Db = struct {
    conn: zqlite.Conn,

    pub fn open(path: [:0]const u8) !Db {
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        var conn = try zqlite.open(path, flags);
        errdefer conn.close();
        try conn.busyTimeout(5000);
        try migrate(&conn);
        return .{ .conn = conn };
    }

    pub fn close(self: *Db) void {
        self.conn.close();
    }

    pub fn addTrack(self: *Db, user_id: i64, pr_number: i64) !void {
        try self.conn.exec(
            \\INSERT INTO tracks(user_id, pr_number, last_state_json, updated_at)
            \\VALUES(?1, ?2, NULL, unixepoch())
            \\ON CONFLICT(user_id, pr_number) DO NOTHING
        , .{ user_id, pr_number });
    }

    pub fn removeTrack(self: *Db, user_id: i64, pr_number: i64) !bool {
        try self.conn.exec(
            "DELETE FROM tracks WHERE user_id = ?1 AND pr_number = ?2",
            .{ user_id, pr_number },
        );
        return self.conn.changes() > 0;
    }

    pub const TrackRow = struct {
        user_id: i64,
        pr_number: i64,
        last_state_json: ?[]const u8,
    };

    pub fn listTracksForUser(
        self: *Db,
        allocator: std.mem.Allocator,
        user_id: i64,
    ) ![]TrackRow {
        var rows = try self.conn.rows(
            "SELECT user_id, pr_number, last_state_json FROM tracks WHERE user_id = ?1 ORDER BY pr_number",
            .{user_id},
        );
        defer rows.deinit();
        return collect(allocator, &rows);
    }

    pub fn allTracks(self: *Db, allocator: std.mem.Allocator) ![]TrackRow {
        var rows = try self.conn.rows(
            "SELECT user_id, pr_number, last_state_json FROM tracks ORDER BY pr_number, user_id",
            .{},
        );
        defer rows.deinit();
        return collect(allocator, &rows);
    }

    fn collect(allocator: std.mem.Allocator, rows: *zqlite.Rows) ![]TrackRow {
        var list: std.ArrayList(TrackRow) = .empty;
        errdefer {
            for (list.items) |item| {
                if (item.last_state_json) |s| allocator.free(s);
            }
            list.deinit(allocator);
        }
        while (rows.next()) |row| {
            const last_json: ?[]const u8 = if (row.nullableText(2)) |t|
                try allocator.dupe(u8, t)
            else
                null;
            try list.append(allocator, .{
                .user_id = row.int(0),
                .pr_number = row.int(1),
                .last_state_json = last_json,
            });
        }
        if (rows.err) |err| return err;
        return list.toOwnedSlice(allocator);
    }

    pub fn freeTracks(allocator: std.mem.Allocator, tracks: []TrackRow) void {
        for (tracks) |t| {
            if (t.last_state_json) |s| allocator.free(s);
        }
        allocator.free(tracks);
    }

    pub fn updateState(
        self: *Db,
        user_id: i64,
        pr_number: i64,
        state_json: []const u8,
    ) !void {
        try self.conn.exec(
            \\UPDATE tracks SET last_state_json = ?3, updated_at = unixepoch()
            \\WHERE user_id = ?1 AND pr_number = ?2
        , .{ user_id, pr_number, state_json });
    }
};

fn migrate(conn: *zqlite.Conn) !void {
    try conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS tracks (
        \\    user_id INTEGER NOT NULL,
        \\    pr_number INTEGER NOT NULL,
        \\    last_state_json TEXT,
        \\    updated_at INTEGER NOT NULL,
        \\    PRIMARY KEY (user_id, pr_number)
        \\) STRICT;
    );
    try conn.execNoArgs(
        "CREATE INDEX IF NOT EXISTS tracks_pr_idx ON tracks(pr_number);",
    );
}

test "db round trip" {
    const a = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();

    try db.addTrack(42, 100);
    try db.addTrack(42, 200);
    try db.addTrack(99, 100);
    try db.addTrack(42, 100);

    const list = try db.listTracksForUser(a, 42);
    defer Db.freeTracks(a, list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(i64, 100), list[0].pr_number);
    try std.testing.expectEqual(@as(i64, 200), list[1].pr_number);

    try db.updateState(42, 100, "{\"state\":\"open\"}");
    const after = try db.listTracksForUser(a, 42);
    defer Db.freeTracks(a, after);
    try std.testing.expectEqualStrings("{\"state\":\"open\"}", after[0].last_state_json.?);

    const removed = try db.removeTrack(42, 100);
    try std.testing.expect(removed);
    const missing = try db.removeTrack(42, 100);
    try std.testing.expect(!missing);
}
