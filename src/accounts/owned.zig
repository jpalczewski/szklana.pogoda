//! The tables whose rows belong to a user, and how each one hands them over.
//!
//! Two things need the same list: the sweep keeps a user while any of these
//! holds a row of it, and merging two accounts has to move every one of them.
//! Each table therefore carries its own `move`, and one cannot be listed
//! without saying how its rows travel, which is what keeps a merge from leaving
//! some of a person's data behind. A test compares the list with the schema, so
//! a table that carries a `user_id` and is missing here fails the build.
//!
//! A `move` takes the connection, not the store, so `store.zig` can import this
//! file without a cycle.

const std = @import("std");
const sqlite = @import("sqlite");

/// The most cities one user may keep. It bounds a row count that a client
/// controls, and it is far more than a person picks.
pub const max_favorites = 50;

pub const Table = struct {
    name: []const u8,
    /// Gives user `into` the rows of user `from` and leaves `from` with none of
    /// them: what does not fit, or is `into`'s already, is dropped, not left
    /// behind. That is what lets a merge tell a row that arrived after the move
    /// from one that was never going to move.
    move: *const fn (*sqlite.Db, i64, i64) anyerror!void,
};

/// Sessions come first: once they are moved the old user is no longer what any
/// browser holds, so a request racing the merge sees the account it is joining.
pub const tables = [_]Table{
    .{ .name = "sessions", .move = moveSessions },
    .{ .name = "favorites", .move = moveFavorites },
    .{ .name = "transfer_codes", .move = moveTransferCodes },
};

fn moveSessions(db: *sqlite.Db, into: i64, from: i64) anyerror!void {
    try db.exec("UPDATE sessions SET user_id = ? WHERE user_id = ?", .{}, .{ into, from });
}

/// Adds the cities `into` does not have yet, oldest first, until it holds
/// `max_favorites`, and drops what is left. A city both users have is one
/// favourite. Cities `into` already has are left out of the selection and not
/// merely ignored on insert, so they do not use up the room the new ones are
/// counted against.
fn moveFavorites(db: *sqlite.Db, into: i64, from: i64) anyerror!void {
    try db.exec(
        comptime std.fmt.comptimePrint(
            \\INSERT OR IGNORE INTO favorites (user_id, city, created_at)
            \\SELECT ?, city, created_at FROM favorites
            \\WHERE user_id = ? AND city NOT IN (SELECT city FROM favorites WHERE user_id = ?)
            \\ORDER BY created_at, city
            \\LIMIT MAX(0, {d} - (SELECT COUNT(*) FROM favorites WHERE user_id = ?))
        , .{max_favorites}),
        .{},
        .{ into, from, into, into },
    );
    try db.exec("DELETE FROM favorites WHERE user_id = ?", .{}, .{from});
}

/// A transfer code belongs to the browser that asked for it and is not part of
/// what the account keeps; the receiver has its own, and there is one per user.
fn moveTransferCodes(db: *sqlite.Db, _: i64, from: i64) anyerror!void {
    try db.exec("DELETE FROM transfer_codes WHERE user_id = ?", .{}, .{from});
}
