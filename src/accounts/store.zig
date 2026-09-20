//! The accounts database: who a browser is, without knowing anything about it.
//!
//! An account starts anonymous. A `user` is a bare row, and a `session` ties one
//! browser's cookie to it. Everything a user owns later (favourites, push
//! subscriptions) hangs off `users.id`, so signing in on a second device only
//! has to move those rows to the user that device already holds.
//!
//! This is a file of its own, apart from the weather database. The weather rows
//! can be downloaded again from IMGW and these cannot, so the two want different
//! backups. It also keeps the connection separate: `weather/store.zig` writes in
//! batches over its own serialized connection and cannot spare one for a
//! transaction that belongs to somebody else.

const std = @import("std");
const sqlite = @import("sqlite");
const token = @import("token.zig");

/// How long a session may sit unused before it stops working. The session is the
/// only thing that identifies the user, and holding it grants nothing beyond the
/// user's own data, so it is allowed to be long.
pub const session_idle_seconds: i64 = 365 * 24 * 60 * 60;

/// A session's `last_seen_at` and expiry are moved forward at most this often,
/// so a page that polls does not turn every request into a write.
const touch_interval_seconds: i64 = 60 * 60;

/// A user with nothing attached is deleted only once it is this old, so the
/// sweep cannot remove a user between the statement that creates it and the one
/// that creates its session.
const orphan_grace_seconds: i64 = 60 * 60;

/// The sweep runs once per this many users created, in place of a task of its
/// own: a background task would take one of the connection slots, and users only
/// pile up when they are being created.
const sweep_every_creations = 64;

/// The tables whose rows belong to a user, by name. A table that carries a
/// `user_id` must be listed: the sweep keeps a user alive while any of these
/// holds a row of it, and moving an account has to move every one of them. A
/// test compares this list with the schema, so a table added without it fails
/// the build instead of losing data.
pub const owned_tables = .{ "favorites", "sessions" };

const orphan_users_sql = blk: {
    var sql: []const u8 = "DELETE FROM users WHERE recovery_hash IS NULL AND created_at < ?";
    for (owned_tables) |table| {
        sql = sql ++ " AND NOT EXISTS (SELECT 1 FROM " ++ table ++ " WHERE " ++ table ++ ".user_id = users.id)";
    }
    break :blk sql;
};

/// The most cities one user may keep. It bounds a row count that a client
/// controls, and it is far more than a person picks.
pub const max_favorites = 50;

/// What the store knows about a token.
pub const Lookup = union(enum) {
    /// A session that existed and has run out.
    expired,
    /// No such session.
    unknown,
    /// A live session of this user.
    valid: i64,
};

const SessionRow = struct {
    user_id: i64,
    last_seen_at: i64,
    expires_at: i64,
};

pub const Store = struct {
    db: sqlite.Db,
    creations: std.atomic.Value(u32) = .init(0),

    pub fn initFile(path: [:0]const u8) !Store {
        var store: Store = .{
            .db = try sqlite.Db.init(.{
                .mode = .{ .File = path },
                .open_flags = .{ .write = true, .create = true },
                .threading_mode = .Serialized,
            }),
        };
        errdefer store.deinit();
        try store.migrate();
        return store;
    }

    pub fn initMemory() !Store {
        var store: Store = .{
            .db = try sqlite.Db.init(.{
                .mode = .Memory,
                .open_flags = .{ .write = true, .create = true },
                .threading_mode = .Serialized,
            }),
        };
        errdefer store.deinit();
        try store.migrate();
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.db.deinit();
        self.* = undefined;
    }

    fn migrate(self: *Store) !void {
        // Foreign keys are off until asked for, per connection. Without them a
        // deleted user would leave its sessions behind.
        try self.db.exec("PRAGMA foreign_keys = ON", .{}, .{});
        try self.db.execMulti(
            \\CREATE TABLE IF NOT EXISTS users (
            \\    id INTEGER PRIMARY KEY,
            \\    created_at INTEGER NOT NULL,
            \\    recovery_hash BLOB UNIQUE
            \\);
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\    token_hash BLOB NOT NULL PRIMARY KEY,
            \\    user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
            \\    created_at INTEGER NOT NULL,
            \\    last_seen_at INTEGER NOT NULL,
            \\    expires_at INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS sessions_user ON sessions (user_id);
            \\CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions (expires_at);
            \\CREATE TABLE IF NOT EXISTS favorites (
            \\    user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
            \\    city TEXT NOT NULL,
            \\    created_at INTEGER NOT NULL,
            \\    PRIMARY KEY (user_id, city)
            \\);
        ,
            .{},
        );
    }

    /// Adds an anonymous user and returns its id. The id comes back through
    /// `RETURNING` and not through `last_insert_rowid`, which belongs to the
    /// connection: this one is shared by every request in flight, and two of
    /// them creating a user at once would read each other's row.
    pub fn createUser(self: *Store, now: i64) !i64 {
        const id = (try self.db.one(i64, "INSERT INTO users (created_at) VALUES (?) RETURNING id", .{}, .{now})) orelse return error.NoRowReturned;
        if (self.creations.fetchAdd(1, .monotonic) % sweep_every_creations == sweep_every_creations - 1) {
            self.sweep(now) catch |err| std.log.warn("account sweep failed: {t}", .{err});
        }
        return id;
    }

    /// Ties the token with this hash to `user_id`.
    pub fn createSession(self: *Store, user_id: i64, hash: token.Hash, now: i64) !void {
        try self.db.exec(
            "INSERT INTO sessions (token_hash, user_id, created_at, last_seen_at, expires_at) VALUES (?, ?, ?, ?, ?)",
            .{},
            .{ sqlite.Blob{ .data = &hash }, user_id, now, now, now + session_idle_seconds },
        );
    }

    /// Resolves a token and, when it is live, moves its expiry forward. A session
    /// found expired stays in the table for the sweep; deleting it here would make
    /// a read write.
    pub fn lookup(self: *Store, hash: token.Hash, now: i64) !Lookup {
        const row = (try self.db.one(
            SessionRow,
            "SELECT user_id, last_seen_at, expires_at FROM sessions WHERE token_hash = ?",
            .{},
            .{sqlite.Blob{ .data = &hash }},
        )) orelse return .unknown;
        if (row.expires_at <= now) return .expired;
        if (now - row.last_seen_at >= touch_interval_seconds) {
            try self.db.exec(
                "UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE token_hash = ?",
                .{},
                .{ now, now + session_idle_seconds, sqlite.Blob{ .data = &hash } },
            );
        }
        return .{ .valid = row.user_id };
    }

    /// Ends the session with this token. A token that is already gone is not an
    /// error: signing out twice is the same as signing out once.
    pub fn deleteSession(self: *Store, hash: token.Hash) !void {
        try self.db.exec("DELETE FROM sessions WHERE token_hash = ?", .{}, .{sqlite.Blob{ .data = &hash }});
    }

    /// Deletes the sessions that have run out and the users nothing points at.
    /// A user with a recovery code stays, since the code is a way back in.
    pub fn sweep(self: *Store, now: i64) !void {
        try self.db.exec("DELETE FROM sessions WHERE expires_at <= ?", .{}, .{now});
        try self.db.exec(orphan_users_sql, .{}, .{now - orphan_grace_seconds});
    }

    /// Adds `city` to the user's favourites; a city already there stays as it
    /// was. `city` is the spelling of the city table, which the caller resolved:
    /// the store keeps the name and not the table's position, because a
    /// regenerated table shifts every position.
    ///
    /// The cap is checked before the insert, and two requests of one user racing
    /// each other may pass it together. That overshoots by a row or two and
    /// nothing depends on it being exact.
    pub fn addFavorite(self: *Store, user_id: i64, city: []const u8, now: i64) !void {
        const held = (try self.db.one(i64, "SELECT COUNT(*) FROM favorites WHERE user_id = ?", .{}, .{user_id})) orelse 0;
        const already = (try self.db.one(i64, "SELECT COUNT(*) FROM favorites WHERE user_id = ? AND city = ?", .{}, .{ user_id, city })) orelse 0;
        if (already == 0 and held >= max_favorites) return error.FavoritesFull;
        try self.db.exec(
            "INSERT OR IGNORE INTO favorites (user_id, city, created_at) VALUES (?, ?, ?)",
            .{},
            .{ user_id, city, now },
        );
    }

    /// Removes `city`; one that was not there is not an error.
    pub fn removeFavorite(self: *Store, user_id: i64, city: []const u8) !void {
        try self.db.exec("DELETE FROM favorites WHERE user_id = ? AND city = ?", .{}, .{ user_id, city });
    }

    /// The user's favourite cities in the order they were added. The names and
    /// the slice are the caller's to free.
    pub fn favorites(self: *Store, allocator: std.mem.Allocator, user_id: i64) ![]const []const u8 {
        var statement = try self.db.prepare("SELECT city FROM favorites WHERE user_id = ? ORDER BY created_at, city");
        defer statement.deinit();
        return statement.all([]const u8, allocator, .{}, .{user_id});
    }

    fn countRows(self: *Store, comptime table: []const u8) !i64 {
        return (try self.db.one(i64, "SELECT COUNT(*) FROM " ++ table, .{}, .{})) orelse 0;
    }
};

fn hashOf(seed: u8) token.Hash {
    return token.hash(&token.encode(@splat(seed))).?;
}

test "a session resolves to its user" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(1000);
    try store.createSession(user, hashOf(1), 1000);

    try std.testing.expectEqual(Lookup{ .valid = user }, try store.lookup(hashOf(1), 1001));
    try std.testing.expectEqual(Lookup.unknown, try store.lookup(hashOf(2), 1001));
}

test "users are numbered separately" {
    var store = try Store.initMemory();
    defer store.deinit();
    const first = try store.createUser(1000);
    const second = try store.createUser(1000);
    try std.testing.expect(first != second);
}

test "a session runs out after the idle period and not before" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.createSession(user, hashOf(1), 0);
    try store.createSession(user, hashOf(2), 0);

    try std.testing.expectEqual(Lookup{ .valid = user }, try store.lookup(hashOf(1), session_idle_seconds - 1));
    // Session 2 was not used above, so nothing extended it.
    try std.testing.expectEqual(Lookup.expired, try store.lookup(hashOf(2), session_idle_seconds));
}

test "use extends a session, but only once per touch interval" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.createSession(user, hashOf(1), 0);

    // Inside the interval nothing is written, so the expiry stays where it was.
    _ = try store.lookup(hashOf(1), touch_interval_seconds - 1);
    try std.testing.expectEqual(session_idle_seconds, try expiryOf(&store));

    _ = try store.lookup(hashOf(1), touch_interval_seconds);
    try std.testing.expectEqual(touch_interval_seconds + session_idle_seconds, try expiryOf(&store));
}

fn expiryOf(store: *Store) !i64 {
    return (try store.db.one(i64, "SELECT expires_at FROM sessions", .{}, .{})).?;
}

test "deleting a session signs that browser out and tolerates a repeat" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.createSession(user, hashOf(1), 0);
    try store.createSession(user, hashOf(2), 0);

    try store.deleteSession(hashOf(1));
    try store.deleteSession(hashOf(1));
    try std.testing.expectEqual(Lookup.unknown, try store.lookup(hashOf(1), 1));
    try std.testing.expectEqual(Lookup{ .valid = user }, try store.lookup(hashOf(2), 1));
}

test "the sweep drops expired sessions and the users left with nothing" {
    var store = try Store.initMemory();
    defer store.deinit();
    const stale = try store.createUser(0);
    try store.createSession(stale, hashOf(1), 0);
    const live = try store.createUser(0);
    try store.createSession(live, hashOf(2), session_idle_seconds);

    try store.sweep(session_idle_seconds + orphan_grace_seconds + 1);

    try std.testing.expectEqual(@as(i64, 1), try store.countRows("sessions"));
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));
    try std.testing.expectEqual(Lookup{ .valid = live }, try store.lookup(hashOf(2), session_idle_seconds + 1));
}

test "the sweep leaves a fresh user whose session is not written yet" {
    var store = try Store.initMemory();
    defer store.deinit();
    _ = try store.createUser(5000);
    try store.sweep(5000);
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));
}

test "the sweep keeps a user that holds a recovery code" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.db.exec("UPDATE users SET recovery_hash = ? WHERE id = ?", .{}, .{ sqlite.Blob{ .data = "recovery" }, user });
    try store.sweep(session_idle_seconds * 2);
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));
}

test "deleting a user removes its sessions" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.createSession(user, hashOf(1), 0);
    try store.db.exec("DELETE FROM users WHERE id = ?", .{}, .{user});
    try std.testing.expectEqual(@as(i64, 0), try store.countRows("sessions"));
}

test "every table that carries a user_id is listed as owned" {
    var store = try Store.initMemory();
    defer store.deinit();
    var statement = try store.db.prepare(
        \\SELECT m.name FROM sqlite_master m
        \\WHERE m.type = 'table' AND m.name <> 'users'
        \\  AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = 'user_id')
    );
    defer statement.deinit();
    const names = try statement.all([]const u8, std.testing.allocator, .{}, .{});
    defer {
        for (names) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(names);
    }

    try std.testing.expectEqual(owned_tables.len, names.len);
    for (names) |name| {
        var listed = false;
        inline for (owned_tables) |owned| listed = listed or std.mem.eql(u8, owned, name);
        try std.testing.expect(listed);
    }
}

fn freeNames(names: []const []const u8) void {
    for (names) |name| std.testing.allocator.free(name);
    std.testing.allocator.free(names);
}

test "favourites come back in the order they were added and add is idempotent" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.addFavorite(user, "Zakopane", 10);
    try store.addFavorite(user, "Gdańsk", 20);
    try store.addFavorite(user, "Zakopane", 30);

    const names = try store.favorites(std.testing.allocator, user);
    defer freeNames(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("Zakopane", names[0]);
    try std.testing.expectEqualStrings("Gdańsk", names[1]);
}

test "favourites belong to one user and removing one that is not there is fine" {
    var store = try Store.initMemory();
    defer store.deinit();
    const first = try store.createUser(0);
    const second = try store.createUser(0);
    try store.addFavorite(first, "Zakopane", 1);
    try store.addFavorite(second, "Gdańsk", 1);

    try store.removeFavorite(first, "Gdańsk");
    try store.removeFavorite(first, "Zakopane");
    try store.removeFavorite(first, "Zakopane");

    const none = try store.favorites(std.testing.allocator, first);
    defer freeNames(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const kept = try store.favorites(std.testing.allocator, second);
    defer freeNames(kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
}

test "a user cannot keep more than the cap, but may re-add a city it has" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    var name_buffer: [16]u8 = undefined;
    for (0..max_favorites) |index| {
        try store.addFavorite(user, try std.fmt.bufPrint(&name_buffer, "City {d}", .{index}), 1);
    }
    try std.testing.expectError(error.FavoritesFull, store.addFavorite(user, "One more", 1));
    try store.addFavorite(user, "City 0", 2);
}

test "the sweep keeps a user that holds a favourite" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.addFavorite(user, "Zakopane", 0);
    try store.sweep(session_idle_seconds * 2);
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));
}

test "deleting a user removes its favourites" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.addFavorite(user, "Zakopane", 0);
    try store.db.exec("DELETE FROM users WHERE id = ?", .{}, .{user});
    try std.testing.expectEqual(@as(i64, 0), try store.countRows("favorites"));
}

test "the sweep runs by itself once enough users have been created" {
    var store = try Store.initMemory();
    defer store.deinit();
    // These users are older than the grace period by the time the 64th arrives.
    for (0..sweep_every_creations - 1) |_| _ = try store.createUser(0);
    _ = try store.createUser(orphan_grace_seconds + 1);
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));
}
