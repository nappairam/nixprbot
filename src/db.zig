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

    // ---- subscriptions ----

    /// Returns true if a new subscription row was inserted.
    pub fn subscribe(self: *Db, chat_id: i64, pr_number: i64) !bool {
        try self.conn.exec(
            \\INSERT OR IGNORE INTO subscriptions(chat_id, pr_number, created_at)
            \\VALUES(?1, ?2, unixepoch())
        , .{ chat_id, pr_number });
        return self.conn.changes() > 0;
    }

    pub fn unsubscribe(self: *Db, chat_id: i64, pr_number: i64) !bool {
        try self.conn.exec(
            "DELETE FROM subscriptions WHERE chat_id = ?1 AND pr_number = ?2",
            .{ chat_id, pr_number },
        );
        const removed = self.conn.changes() > 0;
        if (removed) {
            try self.conn.exec(
                "DELETE FROM notified WHERE chat_id = ?1 AND pr_number = ?2",
                .{ chat_id, pr_number },
            );
        }
        return removed;
    }

    pub fn listSubscriptions(
        self: *Db,
        allocator: std.mem.Allocator,
        chat_id: i64,
    ) ![]i64 {
        var rows = try self.conn.rows(
            "SELECT pr_number FROM subscriptions WHERE chat_id = ?1 ORDER BY pr_number",
            .{chat_id},
        );
        defer rows.deinit();
        var list: std.ArrayList(i64) = .empty;
        errdefer list.deinit(allocator);
        while (rows.next()) |row| try list.append(allocator, row.int(0));
        if (rows.err) |err| return err;
        return list.toOwnedSlice(allocator);
    }

    pub fn allTrackedPrs(self: *Db, allocator: std.mem.Allocator) ![]i64 {
        var rows = try self.conn.rows(
            "SELECT DISTINCT pr_number FROM subscriptions ORDER BY pr_number",
            .{},
        );
        defer rows.deinit();
        var list: std.ArrayList(i64) = .empty;
        errdefer list.deinit(allocator);
        while (rows.next()) |row| try list.append(allocator, row.int(0));
        if (rows.err) |err| return err;
        return list.toOwnedSlice(allocator);
    }

    pub fn subscribers(
        self: *Db,
        allocator: std.mem.Allocator,
        pr_number: i64,
    ) ![]i64 {
        var rows = try self.conn.rows(
            "SELECT chat_id FROM subscriptions WHERE pr_number = ?1",
            .{pr_number},
        );
        defer rows.deinit();
        var list: std.ArrayList(i64) = .empty;
        errdefer list.deinit(allocator);
        while (rows.next()) |row| try list.append(allocator, row.int(0));
        if (rows.err) |err| return err;
        return list.toOwnedSlice(allocator);
    }

    // ---- pr_meta ----

    pub const PrMeta = struct {
        pr_number: i64,
        title: ?[]const u8,
        state: ?[]const u8,
        merged: bool,
        merge_commit_sha: ?[]const u8,

        pub fn deinit(self: PrMeta, allocator: std.mem.Allocator) void {
            if (self.title) |s| allocator.free(s);
            if (self.state) |s| allocator.free(s);
            if (self.merge_commit_sha) |s| allocator.free(s);
        }
    };

    pub fn getMeta(
        self: *Db,
        allocator: std.mem.Allocator,
        pr_number: i64,
    ) !?PrMeta {
        const row_opt = try self.conn.row(
            "SELECT pr_number, title, state, merged, merge_commit_sha FROM pr_meta WHERE pr_number = ?1",
            .{pr_number},
        );
        if (row_opt) |row| {
            defer row.deinit();
            const title: ?[]const u8 = if (row.nullableText(1)) |t| try allocator.dupe(u8, t) else null;
            errdefer if (title) |s| allocator.free(s);
            const state: ?[]const u8 = if (row.nullableText(2)) |t| try allocator.dupe(u8, t) else null;
            errdefer if (state) |s| allocator.free(s);
            const sha: ?[]const u8 = if (row.nullableText(4)) |t| try allocator.dupe(u8, t) else null;
            return PrMeta{
                .pr_number = row.int(0),
                .title = title,
                .state = state,
                .merged = row.int(3) != 0,
                .merge_commit_sha = sha,
            };
        }
        return null;
    }

    pub fn upsertMeta(
        self: *Db,
        pr_number: i64,
        title: ?[]const u8,
        state: ?[]const u8,
        merged: bool,
        merge_commit_sha: ?[]const u8,
    ) !void {
        try self.conn.exec(
            \\INSERT INTO pr_meta(pr_number, title, state, merged, merge_commit_sha, last_checked_at)
            \\VALUES(?1, ?2, ?3, ?4, ?5, unixepoch())
            \\ON CONFLICT(pr_number) DO UPDATE SET
            \\    title = excluded.title,
            \\    state = excluded.state,
            \\    merged = excluded.merged,
            \\    merge_commit_sha = excluded.merge_commit_sha,
            \\    last_checked_at = excluded.last_checked_at
        , .{ pr_number, title, state, @as(i64, if (merged) 1 else 0), merge_commit_sha });
    }

    // ---- pr_stage ----

    /// Returns true on first insert (PR's commit reached `stage` for the
    /// first time globally).
    pub fn recordStage(self: *Db, pr_number: i64, stage: []const u8) !bool {
        try self.conn.exec(
            \\INSERT OR IGNORE INTO pr_stage(pr_number, stage, reached_at)
            \\VALUES(?1, ?2, unixepoch())
        , .{ pr_number, stage });
        return self.conn.changes() > 0;
    }

    pub fn reachedStages(
        self: *Db,
        allocator: std.mem.Allocator,
        pr_number: i64,
    ) ![][]u8 {
        var rows = try self.conn.rows(
            "SELECT stage FROM pr_stage WHERE pr_number = ?1",
            .{pr_number},
        );
        defer rows.deinit();
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
        while (rows.next()) |row| {
            try list.append(allocator, try allocator.dupe(u8, row.text(0)));
        }
        if (rows.err) |err| return err;
        return list.toOwnedSlice(allocator);
    }

    pub fn freeStrings(allocator: std.mem.Allocator, items: [][]u8) void {
        for (items) |s| allocator.free(s);
        allocator.free(items);
    }

    // ---- notified (per-chat dedup) ----

    pub fn alreadyNotified(
        self: *Db,
        chat_id: i64,
        pr_number: i64,
        stage: []const u8,
    ) !bool {
        const row = try self.conn.row(
            "SELECT 1 FROM notified WHERE chat_id = ?1 AND pr_number = ?2 AND stage = ?3",
            .{ chat_id, pr_number, stage },
        );
        if (row) |r| {
            r.deinit();
            return true;
        }
        return false;
    }

    pub fn markNotified(
        self: *Db,
        chat_id: i64,
        pr_number: i64,
        stage: []const u8,
    ) !void {
        try self.conn.exec(
            \\INSERT OR IGNORE INTO notified(chat_id, pr_number, stage, sent_at)
            \\VALUES(?1, ?2, ?3, unixepoch())
        , .{ chat_id, pr_number, stage });
    }
};

fn migrate(conn: *zqlite.Conn) !void {
    try conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS subscriptions (
        \\    chat_id    INTEGER NOT NULL,
        \\    pr_number  INTEGER NOT NULL,
        \\    created_at INTEGER NOT NULL,
        \\    PRIMARY KEY (chat_id, pr_number)
        \\) STRICT;
    );
    try conn.execNoArgs(
        "CREATE INDEX IF NOT EXISTS idx_subscriptions_pr ON subscriptions(pr_number);",
    );
    try conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS pr_meta (
        \\    pr_number        INTEGER PRIMARY KEY,
        \\    title            TEXT,
        \\    state            TEXT,
        \\    merged           INTEGER NOT NULL DEFAULT 0,
        \\    merge_commit_sha TEXT,
        \\    last_checked_at  INTEGER
        \\) STRICT;
    );
    try conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS pr_stage (
        \\    pr_number  INTEGER NOT NULL,
        \\    stage      TEXT    NOT NULL,
        \\    reached_at INTEGER NOT NULL,
        \\    PRIMARY KEY (pr_number, stage)
        \\) STRICT;
    );
    try conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS notified (
        \\    chat_id   INTEGER NOT NULL,
        \\    pr_number INTEGER NOT NULL,
        \\    stage     TEXT    NOT NULL,
        \\    sent_at   INTEGER NOT NULL,
        \\    PRIMARY KEY (chat_id, pr_number, stage)
        \\) STRICT;
    );
}

test "subscriptions and stages" {
    const a = std.testing.allocator;
    var db = try Db.open(":memory:");
    defer db.close();

    try std.testing.expect(try db.subscribe(42, 100));
    try std.testing.expect(try db.subscribe(42, 200));
    try std.testing.expect(try db.subscribe(99, 100));
    try std.testing.expect(!(try db.subscribe(42, 100)));

    const list = try db.listSubscriptions(a, 42);
    defer a.free(list);
    try std.testing.expectEqualSlices(i64, &.{ 100, 200 }, list);

    const subs = try db.subscribers(a, 100);
    defer a.free(subs);
    try std.testing.expectEqual(@as(usize, 2), subs.len);

    try db.upsertMeta(100, "fix x", "open", false, null);
    var meta = (try db.getMeta(a, 100)).?;
    defer meta.deinit(a);
    try std.testing.expectEqualStrings("fix x", meta.title.?);
    try std.testing.expect(!meta.merged);

    try std.testing.expect(try db.recordStage(100, "master"));
    try std.testing.expect(!(try db.recordStage(100, "master")));
    const stages = try db.reachedStages(a, 100);
    defer Db.freeStrings(a, stages);
    try std.testing.expectEqual(@as(usize, 1), stages.len);
    try std.testing.expectEqualStrings("master", stages[0]);

    try std.testing.expect(!(try db.alreadyNotified(42, 100, "master")));
    try db.markNotified(42, 100, "master");
    try std.testing.expect(try db.alreadyNotified(42, 100, "master"));

    try std.testing.expect(try db.unsubscribe(42, 100));
    try std.testing.expect(!(try db.unsubscribe(42, 100)));
    // unsubscribe wipes notified rows for that (chat, pr) so re-track replays.
    try std.testing.expect(!(try db.alreadyNotified(42, 100, "master")));
}
