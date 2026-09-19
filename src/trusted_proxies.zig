//! The peers that may vouch for a request's client address.
//!
//! A forwarded-address header is only as honest as whoever wrote it. A request
//! sent straight to the origin carries whatever its sender put there, so the
//! server reads such a header only when the TCP peer is a proxy the operator
//! listed in `TRUSTED_PROXIES`.

const std = @import("std");
const net = std.Io.net;

/// Upper bound on the list, so it is a plain value that needs no allocator and
/// can sit in the config and in `router.App`.
pub const capacity = 16;

/// An address block. IPv4 is stored as its IPv4-mapped IPv6 form (`::ffff:a.b.c.d`,
/// prefix shifted by 96), so one comparison handles both families and a peer
/// that a dual-stack listener reports in mapped form still matches an IPv4 block.
const Network = struct {
    bytes: [16]u8 = @splat(0),
    prefix_bits: u8 = 0,
};

pub const ParseError = error{
    InvalidTrustedProxy,
    TooManyTrustedProxies,
};

pub const TrustedProxies = struct {
    networks: [capacity]Network = @splat(.{}),
    len: usize = 0,

    /// Reads a comma-separated list of addresses or CIDR blocks, such as
    /// `172.18.0.0/16,10.0.0.1`. A bare address is a block of one. An empty
    /// list trusts nobody.
    pub fn parse(text: []const u8) ParseError!TrustedProxies {
        var proxies: TrustedProxies = .{};
        var entries = std.mem.splitScalar(u8, text, ',');
        while (entries.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t");
            if (entry.len == 0) continue;
            if (proxies.len == capacity) return error.TooManyTrustedProxies;
            proxies.networks[proxies.len] = try parseNetwork(entry);
            proxies.len += 1;
        }
        return proxies;
    }

    pub fn contains(self: TrustedProxies, address: net.IpAddress) bool {
        const bytes = mapped(address);
        for (self.networks[0..self.len]) |network| {
            if (sharesPrefix(&bytes, &network.bytes, network.prefix_bits)) return true;
        }
        return false;
    }
};

fn parseNetwork(entry: []const u8) ParseError!Network {
    const slash = std.mem.findScalar(u8, entry, '/');
    const address = net.IpAddress.parse(entry[0 .. slash orelse entry.len], 0) catch return error.InvalidTrustedProxy;
    const family_bits: u8 = switch (address) {
        .ip4 => 32,
        .ip6 => 128,
    };
    const prefix: u8 = if (slash) |index|
        std.fmt.parseInt(u8, entry[index + 1 ..], 10) catch return error.InvalidTrustedProxy
    else
        family_bits;
    if (prefix > family_bits) return error.InvalidTrustedProxy;
    return .{
        .bytes = mapped(address),
        .prefix_bits = if (family_bits == 32) prefix + 96 else prefix,
    };
}

fn mapped(address: net.IpAddress) [16]u8 {
    return switch (address) {
        .ip4 => |ip4| .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3] },
        .ip6 => |ip6| ip6.bytes,
    };
}

fn sharesPrefix(a: *const [16]u8, b: *const [16]u8, prefix_bits: u8) bool {
    const whole = prefix_bits / 8;
    if (!std.mem.eql(u8, a[0..whole], b[0..whole])) return false;
    const rest = prefix_bits % 8;
    if (rest == 0) return true;
    const mask: u8 = ~(@as(u8, 0xff) >> @intCast(rest));
    return (a[whole] & mask) == (b[whole] & mask);
}

fn ip(text: []const u8) !net.IpAddress {
    return net.IpAddress.parse(text, 0);
}

test "an empty list trusts nobody" {
    const proxies = try TrustedProxies.parse("");
    try std.testing.expect(!proxies.contains(try ip("172.18.0.6")));
    try std.testing.expect(!(try TrustedProxies.parse(" , ,")).contains(try ip("127.0.0.1")));
}

test "a CIDR block trusts every address inside it and none outside" {
    const proxies = try TrustedProxies.parse("172.18.0.0/16");
    try std.testing.expect(proxies.contains(try ip("172.18.0.6")));
    try std.testing.expect(proxies.contains(try ip("172.18.255.255")));
    try std.testing.expect(!proxies.contains(try ip("172.19.0.1")));
    try std.testing.expect(!proxies.contains(try ip("104.23.1.1")));
}

test "a prefix that is not a whole number of bytes masks the partial byte" {
    const proxies = try TrustedProxies.parse("10.0.0.0/20");
    try std.testing.expect(proxies.contains(try ip("10.0.15.255")));
    try std.testing.expect(!proxies.contains(try ip("10.0.16.0")));
}

test "a bare address is a block of one and the list may hold several entries" {
    const proxies = try TrustedProxies.parse(" 192.0.2.10 , 2001:db8::/32 ");
    try std.testing.expect(proxies.contains(try ip("192.0.2.10")));
    try std.testing.expect(!proxies.contains(try ip("192.0.2.11")));
    try std.testing.expect(proxies.contains(try ip("2001:db8:1::5")));
    try std.testing.expect(!proxies.contains(try ip("2001:db9::1")));
}

test "a zero-length prefix trusts every address of its family" {
    const proxies = try TrustedProxies.parse("0.0.0.0/0");
    try std.testing.expect(proxies.contains(try ip("203.0.113.4")));
    try std.testing.expect(!proxies.contains(try ip("2001:db8::1")));
}

test "an IPv4 block matches the IPv4-mapped form of its addresses" {
    const proxies = try TrustedProxies.parse("172.18.0.0/16");
    try std.testing.expect(proxies.contains(try ip("::ffff:172.18.0.6")));
}

test "malformed entries are rejected" {
    try std.testing.expectError(error.InvalidTrustedProxy, TrustedProxies.parse("traefik"));
    try std.testing.expectError(error.InvalidTrustedProxy, TrustedProxies.parse("172.18.0.0/33"));
    try std.testing.expectError(error.InvalidTrustedProxy, TrustedProxies.parse("172.18.0.0/"));
    try std.testing.expectError(error.InvalidTrustedProxy, TrustedProxies.parse("172.18.0.0/x"));
    try std.testing.expectError(error.InvalidTrustedProxy, TrustedProxies.parse("172.18.0.0/16,nope"));
}

test "more entries than the capacity are rejected" {
    const list = "10.0.0.1," ** capacity ++ "10.0.0.2";
    try std.testing.expectError(error.TooManyTrustedProxies, TrustedProxies.parse(list));
}
