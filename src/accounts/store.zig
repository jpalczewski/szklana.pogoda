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
const Io = std.Io;
const sqlite = @import("sqlite");
const codes = @import("code.zig");
const owned = @import("owned.zig");
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

/// How long a transfer code can be typed after it was shown.
pub const transfer_code_seconds: i64 = 10 * 60;

/// A merge moves an account's rows, deletes the account and, when the delete
/// finds a row that arrived after the move, moves again. This many rounds.
const merge_rounds = 3;

/// The sweep runs once per this many users created, in place of a task of its
/// own: a background task would take one of the connection slots, and users only
/// pile up when they are being created.
const sweep_every_creations = 64;

/// The tables whose rows belong to a user and how each moves them to another
/// (see `owned.zig`). The sweep keeps a user alive while any of them holds a row
/// of it.
pub const owned_tables = owned.tables;

const orphan_users_sql = blk: {
    var sql: []const u8 = "DELETE FROM users WHERE recovery_hash IS NULL AND created_at < ?";
    for (owned_tables) |table| {
        sql = sql ++ " AND NOT EXISTS (SELECT 1 FROM " ++ table.name ++ " WHERE " ++ table.name ++ ".user_id = users.id)";
    }
    break :blk sql;
};

/// The most cities one user may keep.
pub const max_favorites = owned.max_favorites;

/// Removes a user only when none of the tables that hold rows of it has one left.
const delete_if_empty_sql = blk: {
    var sql: []const u8 = "DELETE FROM users WHERE id = ?";
    for (owned_tables) |table| {
        sql = sql ++ " AND NOT EXISTS (SELECT 1 FROM " ++ table.name ++ " WHERE " ++ table.name ++ ".user_id = users.id)";
    }
    break :blk sql;
};

/// What redeeming a code came to.
pub const Redeemed = struct {
    /// The account the browser now belongs to.
    user_id: i64,
    /// The browser already held another account, and it was joined into this one.
    merged: bool,
    /// The browser was given a new session, so the caller sets its cookie. False
    /// when it was already signed in to this account, and nothing changed.
    signed_in: bool,
};

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
    /// Held across everything that has to see the accounts in one piece: issuing
    /// a code, and redeeming one, which consumes it, joins two accounts and swaps
    /// the browser's session. The connection is shared by every request in
    /// flight, so a `BEGIN` here could swallow another request's statements;
    /// this lock is what keeps two of these from interleaving instead.
    merge_mutex: Io.Mutex = .init,

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
            \\CREATE TABLE IF NOT EXISTS transfer_codes (
            \\    user_id INTEGER PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
            \\    code_hash BLOB NOT NULL UNIQUE,
            \\    expires_at INTEGER NOT NULL
            \\);
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
        // Before the users: a code that has run out is not a reason to keep one.
        try self.db.exec("DELETE FROM transfer_codes WHERE expires_at <= ?", .{}, .{now});
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

    /// Makes `hash` the user's transfer code, replacing the one it had. The hash
    /// is of a code the caller drew; `error.CodeCollision` means another user's
    /// code has the same hash, and the caller draws again. The collision is looked
    /// for and not left to the unique index: SQLite reports every constraint as
    /// the same error, and a missing user would read as a collision. Nothing can
    /// slip in between, since every way of issuing a code holds the same lock.
    pub fn issueTransferCode(self: *Store, io: Io, user_id: i64, hash: token.Hash, now: i64) !void {
        self.merge_mutex.lockUncancelable(io);
        defer self.merge_mutex.unlock(io);
        const taken = (try self.db.one(i64, "SELECT COUNT(*) FROM transfer_codes WHERE code_hash = ? AND user_id <> ?", .{}, .{ sqlite.Blob{ .data = &hash }, user_id })) orelse 0;
        if (taken != 0) return error.CodeCollision;
        try self.db.exec(
            "INSERT INTO transfer_codes (user_id, code_hash, expires_at) VALUES (?, ?, ?) ON CONFLICT (user_id) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at",
            .{},
            .{ user_id, sqlite.Blob{ .data = &hash }, now + transfer_code_seconds },
        );
    }

    /// Makes `hash` the user's recovery code; the previous one stops working.
    /// `error.CodeCollision` as for a transfer code.
    pub fn issueRecoveryCode(self: *Store, io: Io, user_id: i64, hash: token.Hash) !void {
        self.merge_mutex.lockUncancelable(io);
        defer self.merge_mutex.unlock(io);
        const taken = (try self.db.one(i64, "SELECT COUNT(*) FROM users WHERE recovery_hash = ? AND id <> ?", .{}, .{ sqlite.Blob{ .data = &hash }, user_id })) orelse 0;
        if (taken != 0) return error.CodeCollision;
        try self.db.exec("UPDATE users SET recovery_hash = ? WHERE id = ?", .{}, .{ sqlite.Blob{ .data = &hash }, user_id });
    }

    pub fn hasRecovery(self: *Store, user_id: i64) !bool {
        const present = (try self.db.one(i64, "SELECT recovery_hash IS NOT NULL FROM users WHERE id = ?", .{}, .{user_id})) orelse 0;
        return present != 0;
    }

    /// Signs a browser in with a code someone typed.
    ///
    /// The code is consumed first: a transfer code is deleted by the statement
    /// that finds it, so two requests with one code cannot both win, and a
    /// recovery code is looked up. A code that is unknown, spent or out of time is
    /// `error.InvalidCode`, without saying which. One that turns out to be for
    /// the account the browser is already in changes nothing.
    ///
    /// Otherwise the browser gets a fresh session for the account, so a token
    /// that leaked while it was anonymous does not become one that is signed in.
    /// It is created before the old one is removed, so a failure cannot leave
    /// the browser with none. When the browser already held another account, that
    /// account is joined into this one: what the two keep is added together, and
    /// its other sessions come along.
    ///
    /// `current` is the token the request came with, if any. The caller gives
    /// `new_session` the hash of a token it drew.
    pub fn redeem(self: *Store, io: Io, code: codes.Code, current: ?token.Hash, new_session: token.Hash, now: i64) !Redeemed {
        self.merge_mutex.lockUncancelable(io);
        defer self.merge_mutex.unlock(io);

        const target = (try self.consume(code, now)) orelse return error.InvalidCode;
        const held = if (current) |hash| try self.liveSessionUser(hash, now) else null;
        if (held != null and held.? == target) return .{ .user_id = target, .merged = false, .signed_in = false };

        try self.createSession(target, new_session, now);
        if (held) |from| try self.mergeInto(target, from);
        if (current) |hash| try self.deleteSession(hash);
        return .{ .user_id = target, .merged = held != null, .signed_in = true };
    }

    fn consume(self: *Store, code: codes.Code, now: i64) !?i64 {
        const hash = code.hash();
        return switch (code.kind) {
            .transfer => try self.db.one(
                i64,
                "DELETE FROM transfer_codes WHERE code_hash = ? AND expires_at > ? RETURNING user_id",
                .{},
                .{ sqlite.Blob{ .data = &hash }, now },
            ),
            .recovery => try self.db.one(i64, "SELECT id FROM users WHERE recovery_hash = ?", .{}, .{sqlite.Blob{ .data = &hash }}),
        };
    }

    fn liveSessionUser(self: *Store, hash: token.Hash, now: i64) !?i64 {
        return self.db.one(i64, "SELECT user_id FROM sessions WHERE token_hash = ? AND expires_at > ?", .{}, .{ sqlite.Blob{ .data = &hash }, now });
    }

    /// Joins `from` into `into` and removes `from`. The moves come first and the
    /// delete only succeeds when nothing of `from` is left, so a request that was
    /// already writing for `from` cannot have its row deleted with the account:
    /// the delete refuses, and the next round moves that row too. Should rounds
    /// run out, the account stays with what it has instead of losing it.
    fn mergeInto(self: *Store, into: i64, from: i64) !void {
        try self.adoptRecovery(into, from);
        for (0..merge_rounds) |_| {
            for (owned_tables) |table| try table.move(&self.db, into, from);
            try self.db.exec(delete_if_empty_sql, .{}, .{from});
            const left = (try self.db.one(i64, "SELECT COUNT(*) FROM users WHERE id = ?", .{}, .{from})) orelse 0;
            if (left == 0) return;
        }
        std.log.warn("account {d} still holds rows after {d} moves into account {d}; it is left as it is", .{ from, merge_rounds, into });
    }

    /// A recovery code the person saved must not vanish with the account it was
    /// made on. When the account being joined has none, it takes this one; when
    /// it has its own, that one stays. The column is unique, so the code is
    /// cleared from `from` before `into` takes it.
    fn adoptRecovery(self: *Store, into: i64, from: i64) !void {
        const Row = struct { recovery_hash: ?token.Hash };
        const theirs = (try self.db.one(Row, "SELECT recovery_hash FROM users WHERE id = ?", .{}, .{from})) orelse return;
        const hash = theirs.recovery_hash orelse return;
        if (try self.hasRecovery(into)) return;
        try self.db.exec("UPDATE users SET recovery_hash = NULL WHERE id = ?", .{}, .{from});
        try self.db.exec("UPDATE users SET recovery_hash = ? WHERE id = ?", .{}, .{ sqlite.Blob{ .data = &hash }, into });
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
        inline for (owned_tables) |table| listed = listed or std.mem.eql(u8, table.name, name);
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

test "moving sessions gives them to the other user" {
    var store = try Store.initMemory();
    defer store.deinit();
    const from = try store.createUser(0);
    const into = try store.createUser(0);
    try store.createSession(from, hashOf(1), 0);
    try store.createSession(from, hashOf(2), 0);

    try owned.tables[0].move(&store.db, into, from);

    try std.testing.expectEqual(Lookup{ .valid = into }, try store.lookup(hashOf(1), 1));
    try std.testing.expectEqual(Lookup{ .valid = into }, try store.lookup(hashOf(2), 1));
}

test "moving favourites adds the missing cities, oldest first, up to the cap" {
    var store = try Store.initMemory();
    defer store.deinit();
    const from = try store.createUser(0);
    const into = try store.createUser(0);
    try store.addFavorite(into, "Zakopane", 5);
    try store.addFavorite(from, "Zakopane", 1);
    try store.addFavorite(from, "Gdańsk", 2);
    try store.addFavorite(from, "Kraków", 3);

    try owned.tables[1].move(&store.db, into, from);

    const names = try store.favorites(std.testing.allocator, into);
    defer freeNames(names);
    // Zakopane was on both sides and is one favourite. The moved cities keep the
    // time they were added, so they list before the one `into` added later.
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("Gdańsk", names[0]);
    try std.testing.expectEqualStrings("Kraków", names[1]);
    try std.testing.expectEqualStrings("Zakopane", names[2]);

    var name_buffer: [16]u8 = undefined;
    for (0..max_favorites - 3) |index| {
        try store.addFavorite(from, try std.fmt.bufPrint(&name_buffer, "Extra {d}", .{index}), 10 + @as(i64, @intCast(index)));
    }
    try owned.tables[1].move(&store.db, into, from);
    try std.testing.expectEqual(@as(i64, max_favorites), (try store.db.one(i64, "SELECT COUNT(*) FROM favorites WHERE user_id = ?", .{}, .{into})).?);
}

test "the sweep runs by itself once enough users have been created" {
    var store = try Store.initMemory();
    defer store.deinit();
    // These users are older than the grace period by the time the 64th arrives.
    for (0..sweep_every_creations - 1) |_| _ = try store.createUser(0);
    _ = try store.createUser(orphan_grace_seconds + 1);
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));
}

const transfer_text = "ABCDE12345";
const other_transfer_text = "FGHJK67890";
const recovery_text = "0123456789ABCDEFGHJK";
const other_recovery_text = "KJHGFEDCBA9876543210";

fn codeOf(text: []const u8) codes.Code {
    return codes.normalise(text).?;
}

fn sessionIn(store: *Store, user: i64, seed: u8) !void {
    try store.createSession(user, hashOf(seed), 0);
}

test "a transfer code signs a browser in once" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 100);

    const signed_in = try store.redeem(std.testing.io, codeOf(transfer_text), null, hashOf(9), 101);
    try std.testing.expectEqual(Redeemed{ .user_id = account, .merged = false, .signed_in = true }, signed_in);
    try std.testing.expectEqual(Lookup{ .valid = account }, try store.lookup(hashOf(9), 102));

    try std.testing.expectError(error.InvalidCode, store.redeem(std.testing.io, codeOf(transfer_text), null, hashOf(8), 102));
    try std.testing.expectEqual(Lookup.unknown, try store.lookup(hashOf(8), 102));
}

test "a transfer code works until it runs out and not at that moment" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 0);

    try std.testing.expectError(error.InvalidCode, store.redeem(std.testing.io, codeOf(transfer_text), null, hashOf(9), transfer_code_seconds));
    // Being refused as too late does not use the code up before it could be tried.
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 1);
    _ = try store.redeem(std.testing.io, codeOf(transfer_text), null, hashOf(9), transfer_code_seconds);
}

test "a code nobody issued is refused, whatever its kind" {
    var store = try Store.initMemory();
    defer store.deinit();
    _ = try store.createUser(0);
    try std.testing.expectError(error.InvalidCode, store.redeem(std.testing.io, codeOf(transfer_text), null, hashOf(9), 1));
    try std.testing.expectError(error.InvalidCode, store.redeem(std.testing.io, codeOf(recovery_text), null, hashOf(9), 1));
}

test "a new transfer code replaces the one before it" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 0);
    try store.issueTransferCode(std.testing.io, account, codeOf(other_transfer_text).hash(), 0);

    try std.testing.expectError(error.InvalidCode, store.redeem(std.testing.io, codeOf(transfer_text), null, hashOf(9), 1));
    _ = try store.redeem(std.testing.io, codeOf(other_transfer_text), null, hashOf(9), 1);
}

test "two users cannot hold the same code" {
    var store = try Store.initMemory();
    defer store.deinit();
    const first = try store.createUser(0);
    const second = try store.createUser(0);
    try store.issueTransferCode(std.testing.io, first, codeOf(transfer_text).hash(), 0);
    try std.testing.expectError(error.CodeCollision, store.issueTransferCode(std.testing.io, second, codeOf(transfer_text).hash(), 0));

    try store.issueRecoveryCode(std.testing.io, first, codeOf(recovery_text).hash());
    try std.testing.expectError(error.CodeCollision, store.issueRecoveryCode(std.testing.io, second, codeOf(recovery_text).hash()));
}

test "a recovery code can be used again and a new one retires it" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    try std.testing.expect(!try store.hasRecovery(account));
    try store.issueRecoveryCode(std.testing.io, account, codeOf(recovery_text).hash());
    try std.testing.expect(try store.hasRecovery(account));

    _ = try store.redeem(std.testing.io, codeOf(recovery_text), null, hashOf(1), 1);
    _ = try store.redeem(std.testing.io, codeOf(recovery_text), null, hashOf(2), 2);

    try store.issueRecoveryCode(std.testing.io, account, codeOf(other_recovery_text).hash());
    try std.testing.expectError(error.InvalidCode, store.redeem(std.testing.io, codeOf(recovery_text), null, hashOf(3), 3));
    _ = try store.redeem(std.testing.io, codeOf(other_recovery_text), null, hashOf(3), 3);
}

test "a browser already in the account is left as it is, and the code is still spent" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    try sessionIn(&store, account, 1);
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 0);

    const result = try store.redeem(std.testing.io, codeOf(transfer_text), hashOf(1), hashOf(9), 1);
    try std.testing.expectEqual(Redeemed{ .user_id = account, .merged = false, .signed_in = false }, result);
    try std.testing.expectEqual(Lookup{ .valid = account }, try store.lookup(hashOf(1), 2));
    try std.testing.expectEqual(Lookup.unknown, try store.lookup(hashOf(9), 2));
    try std.testing.expectError(error.InvalidCode, store.redeem(std.testing.io, codeOf(transfer_text), null, hashOf(9), 2));
}

test "signing in swaps the browser's session for a new one" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    const anonymous = try store.createUser(0);
    try sessionIn(&store, anonymous, 1);
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 0);

    const result = try store.redeem(std.testing.io, codeOf(transfer_text), hashOf(1), hashOf(9), 1);
    try std.testing.expect(result.signed_in);
    try std.testing.expectEqual(Lookup.unknown, try store.lookup(hashOf(1), 2));
    try std.testing.expectEqual(Lookup{ .valid = account }, try store.lookup(hashOf(9), 2));
}

test "an anonymous account is joined into the one signed in to" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    const anonymous = try store.createUser(0);
    try store.addFavorite(account, "Zakopane", 1);
    try store.addFavorite(anonymous, "Gdańsk", 2);
    try store.addFavorite(anonymous, "Zakopane", 3);
    try sessionIn(&store, anonymous, 1);
    try sessionIn(&store, anonymous, 2);
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 0);

    const result = try store.redeem(std.testing.io, codeOf(transfer_text), hashOf(1), hashOf(9), 1);
    try std.testing.expectEqual(Redeemed{ .user_id = account, .merged = true, .signed_in = true }, result);

    const names = try store.favorites(std.testing.allocator, account);
    defer freeNames(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("Zakopane", names[0]);
    try std.testing.expectEqualStrings("Gdańsk", names[1]);

    // The other browser of the joined account keeps working, now as the account.
    try std.testing.expectEqual(Lookup{ .valid = account }, try store.lookup(hashOf(2), 2));
    try std.testing.expectEqual(Lookup.unknown, try store.lookup(hashOf(1), 2));
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));
}

test "joining accounts drops what does not fit under the cap and still removes the account" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    const anonymous = try store.createUser(0);
    var name_buffer: [16]u8 = undefined;
    for (0..max_favorites) |index| {
        try store.addFavorite(account, try std.fmt.bufPrint(&name_buffer, "Mine {d}", .{index}), 1);
    }
    try store.addFavorite(anonymous, "Zakopane", 1);
    try sessionIn(&store, anonymous, 1);
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 0);

    _ = try store.redeem(std.testing.io, codeOf(transfer_text), hashOf(1), hashOf(9), 1);
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));
    try std.testing.expectEqual(@as(i64, max_favorites), try store.countRows("favorites"));
}

test "the account being joined gives its recovery code to one that has none" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    const anonymous = try store.createUser(0);
    try store.issueRecoveryCode(std.testing.io, anonymous, codeOf(recovery_text).hash());
    try sessionIn(&store, anonymous, 1);
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 0);

    _ = try store.redeem(std.testing.io, codeOf(transfer_text), hashOf(1), hashOf(9), 1);
    try std.testing.expect(try store.hasRecovery(account));
    const back = try store.redeem(std.testing.io, codeOf(recovery_text), null, hashOf(8), 2);
    try std.testing.expectEqual(account, back.user_id);
}

test "an account that has its own recovery code keeps it and the other one is gone" {
    var store = try Store.initMemory();
    defer store.deinit();
    const account = try store.createUser(0);
    const anonymous = try store.createUser(0);
    try store.issueRecoveryCode(std.testing.io, account, codeOf(other_recovery_text).hash());
    try store.issueRecoveryCode(std.testing.io, anonymous, codeOf(recovery_text).hash());
    try sessionIn(&store, anonymous, 1);
    try store.issueTransferCode(std.testing.io, account, codeOf(transfer_text).hash(), 0);

    _ = try store.redeem(std.testing.io, codeOf(transfer_text), hashOf(1), hashOf(9), 1);
    try std.testing.expectError(error.InvalidCode, store.redeem(std.testing.io, codeOf(recovery_text), null, hashOf(8), 2));
    _ = try store.redeem(std.testing.io, codeOf(other_recovery_text), null, hashOf(8), 2);
}

test "an account is not deleted while a row of it is left" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.addFavorite(user, "Zakopane", 0);

    try store.db.exec(delete_if_empty_sql, .{}, .{user});
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));

    try store.removeFavorite(user, "Zakopane");
    try store.db.exec(delete_if_empty_sql, .{}, .{user});
    try std.testing.expectEqual(@as(i64, 0), try store.countRows("users"));
}

test "the sweep removes a transfer code that ran out and then the user it kept alive" {
    var store = try Store.initMemory();
    defer store.deinit();
    const user = try store.createUser(0);
    try store.issueTransferCode(std.testing.io, user, codeOf(transfer_text).hash(), 0);

    try store.sweep(orphan_grace_seconds);
    try std.testing.expectEqual(@as(i64, 1), try store.countRows("users"));

    try store.sweep(transfer_code_seconds + orphan_grace_seconds);
    try std.testing.expectEqual(@as(i64, 0), try store.countRows("transfer_codes"));
    try std.testing.expectEqual(@as(i64, 0), try store.countRows("users"));
}
