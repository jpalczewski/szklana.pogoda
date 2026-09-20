//! A cap on how often one address may do something that costs a row.
//!
//! An anonymous account is made by whoever asks for one, so without a cap a
//! single client can fill the accounts file. The count is per address and per
//! fixed window, and it lives in memory: the process is a single one, and losing
//! the counts on a restart only lets a client start a new window early.
//!
//! The table is bounded. When it is full of live windows, what happens to an
//! address it cannot track is the caller's choice. Making an account lets it
//! through, because refusing is what an attacker with many addresses would use
//! against everyone else. Guessing a code refuses it, because a table that fills
//! up must not be a way past the limit.
//!
//! An IPv6 client is counted by its /64, the smallest block a network hands out,
//! so one machine cannot turn its block into as many addresses as it likes.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

/// The most addresses tracked at once.
const max_entries = 8192;

/// What to do with an address the table has no room to track.
pub const OnFull = enum {
    allow,
    refuse,
};

const Window = struct {
    started_at: i64,
    count: u32,
};

pub const Limiter = struct {
    allocator: std.mem.Allocator,
    /// How many times one address may pass per window.
    limit: u32,
    window_seconds: i64,
    on_full: OnFull,
    mutex: Io.Mutex = .init,
    /// Keyed by a hash of the address, so no address text is kept.
    windows: std.AutoHashMapUnmanaged(u64, Window) = .empty,

    pub fn init(allocator: std.mem.Allocator, limit: u32, window_seconds: i64, on_full: OnFull) Limiter {
        return .{ .allocator = allocator, .limit = limit, .window_seconds = window_seconds, .on_full = on_full };
    }

    pub fn deinit(self: *Limiter) void {
        self.windows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Counts one attempt by `address` and says whether it may go ahead.
    pub fn allow(self: *Limiter, io: Io, address: []const u8, now: i64) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const key = keyFor(address);
        if (self.windows.getPtr(key)) |window| {
            if (now - window.started_at >= self.window_seconds) {
                window.* = .{ .started_at = now, .count = 1 };
                return true;
            }
            if (window.count >= self.limit) return false;
            window.count += 1;
            return true;
        }

        if (self.windows.count() >= max_entries) self.dropExpired(now);
        if (self.windows.count() >= max_entries) return self.on_full == .allow;
        self.windows.put(self.allocator, key, .{ .started_at = now, .count = 1 }) catch return self.on_full == .allow;
        return true;
    }

    fn dropExpired(self: *Limiter, now: i64) void {
        var expired: std.ArrayList(u64) = .empty;
        defer expired.deinit(self.allocator);
        var entries = self.windows.iterator();
        while (entries.next()) |entry| {
            if (now - entry.value_ptr.started_at < self.window_seconds) continue;
            expired.append(self.allocator, entry.key_ptr.*) catch return;
        }
        for (expired.items) |key| _ = self.windows.remove(key);
    }
};

/// What an address is counted as: an IPv4 address by itself, an IPv6 one by its
/// /64. An IPv4 address a dual-stack listener reports in IPv6 form
/// (`::ffff:a.b.c.d`) is counted as the IPv4 address it is. Text that is not an
/// address is counted as text.
fn keyFor(address: []const u8) u64 {
    const parsed = net.IpAddress.parse(address, 0) catch return std.hash.Wyhash.hash(0, address);
    switch (parsed) {
        .ip4 => |ip4| return std.hash.Wyhash.hash(4, &ip4.bytes),
        .ip6 => |ip6| {
            const mapped_prefix = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff };
            if (std.mem.eql(u8, ip6.bytes[0..12], &mapped_prefix)) return std.hash.Wyhash.hash(4, ip6.bytes[12..16]);
            return std.hash.Wyhash.hash(6, ip6.bytes[0..8]);
        },
    }
}

test "an address passes up to the limit and is refused after" {
    var limiter: Limiter = .init(std.testing.allocator, 3, 3600, .allow);
    defer limiter.deinit();
    for (0..3) |_| try std.testing.expect(limiter.allow(std.testing.io, "203.0.113.4", 100));
    try std.testing.expect(!limiter.allow(std.testing.io, "203.0.113.4", 101));
    try std.testing.expect(!limiter.allow(std.testing.io, "203.0.113.4", 3699));
}

test "the count starts over when the window has passed" {
    var limiter: Limiter = .init(std.testing.allocator, 1, 3600, .allow);
    defer limiter.deinit();
    try std.testing.expect(limiter.allow(std.testing.io, "203.0.113.4", 0));
    try std.testing.expect(!limiter.allow(std.testing.io, "203.0.113.4", 3599));
    try std.testing.expect(limiter.allow(std.testing.io, "203.0.113.4", 3600));
}

test "addresses are counted apart" {
    var limiter: Limiter = .init(std.testing.allocator, 1, 3600, .allow);
    defer limiter.deinit();
    try std.testing.expect(limiter.allow(std.testing.io, "203.0.113.4", 0));
    try std.testing.expect(limiter.allow(std.testing.io, "203.0.113.5", 0));
    try std.testing.expect(!limiter.allow(std.testing.io, "203.0.113.4", 1));
}

test "a full table drops expired windows and otherwise lets a new address through" {
    var limiter: Limiter = .init(std.testing.allocator, 1, 3600, .allow);
    defer limiter.deinit();
    for (0..max_entries) |index| try limiter.windows.put(std.testing.allocator, index, .{ .started_at = 0, .count = 1 });

    // Every window is still live: the newcomer is not tracked, but it passes.
    try std.testing.expect(limiter.allow(std.testing.io, "203.0.113.4", 10));
    try std.testing.expectEqual(@as(u32, max_entries), limiter.windows.count());

    // Once they have expired the table makes room and tracks the address.
    try std.testing.expect(limiter.allow(std.testing.io, "203.0.113.4", 4000));
    try std.testing.expectEqual(@as(u32, 1), limiter.windows.count());
    try std.testing.expect(!limiter.allow(std.testing.io, "203.0.113.4", 4001));
}

test "a full table refuses a new address when the limiter is told to" {
    var limiter: Limiter = .init(std.testing.allocator, 1, 3600, .refuse);
    defer limiter.deinit();
    for (0..max_entries) |index| try limiter.windows.put(std.testing.allocator, index, .{ .started_at = 0, .count = 1 });

    try std.testing.expect(!limiter.allow(std.testing.io, "203.0.113.4", 10));
    // Room made by expired windows lets it in again.
    try std.testing.expect(limiter.allow(std.testing.io, "203.0.113.4", 4000));
}

test "an IPv6 client is counted by its /64" {
    var limiter: Limiter = .init(std.testing.allocator, 1, 3600, .allow);
    defer limiter.deinit();
    try std.testing.expect(limiter.allow(std.testing.io, "2001:db8:1:2::1", 0));
    try std.testing.expect(!limiter.allow(std.testing.io, "2001:db8:1:2:ffff:ffff:ffff:ffff", 1));
    try std.testing.expect(limiter.allow(std.testing.io, "2001:db8:1:3::1", 1));
}

test "an IPv4 address in IPv6 form is the same client as in IPv4 form" {
    var limiter: Limiter = .init(std.testing.allocator, 1, 3600, .allow);
    defer limiter.deinit();
    try std.testing.expect(limiter.allow(std.testing.io, "203.0.113.4", 0));
    try std.testing.expect(!limiter.allow(std.testing.io, "::ffff:203.0.113.4", 1));
    // Two mapped clients are two clients, not one /64.
    try std.testing.expect(limiter.allow(std.testing.io, "::ffff:203.0.113.5", 1));
}

test "text that is not an address is counted as itself" {
    var limiter: Limiter = .init(std.testing.allocator, 1, 3600, .allow);
    defer limiter.deinit();
    try std.testing.expect(limiter.allow(std.testing.io, "", 0));
    try std.testing.expect(!limiter.allow(std.testing.io, "", 1));
    try std.testing.expect(limiter.allow(std.testing.io, "unknown", 1));
}
