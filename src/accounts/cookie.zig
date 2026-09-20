//! The session cookie: reading it from a request and writing it into a response.
//!
//! Over HTTPS the name carries the `__Host-` prefix, which makes a browser
//! refuse the cookie unless it is `Secure`, has `Path=/` and names no `Domain`,
//! so a sibling subdomain cannot plant one. The prefix needs `Secure`, and a
//! browser only accepts `Secure` cookies from a secure origin, which is why the
//! plain-HTTP development form drops both.

const std = @import("std");
const store = @import("store.zig");
const token = @import("token.zig");

pub const secure_name = "__Host-sid";
pub const plain_name = "sid";

/// How long the browser keeps the cookie: as long as the store keeps an idle
/// session, so neither outlives the other.
pub const max_age_seconds: u64 = @intCast(store.session_idle_seconds);

pub const Policy = enum {
    /// Served over plain HTTP, i.e. local development.
    plain,
    /// Served over HTTPS: `__Host-` name and `Secure`.
    secure,

    pub fn name(self: Policy) []const u8 {
        return switch (self) {
            .secure => secure_name,
            .plain => plain_name,
        };
    }
};

/// The token in the request's `Cookie` header, or null when there is none.
/// Malformed pairs and other cookies are skipped.
pub fn read(policy: Policy, header: ?[]const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, header orelse return null, ';');
    while (pairs.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " \t");
        const separator = std.mem.findScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..separator], policy.name())) return trimmed[separator + 1 ..];
    }
    return null;
}

/// The `Set-Cookie` value that stores `text` in the browser.
pub fn set(allocator: std.mem.Allocator, policy: Policy, text: token.Text) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}={s}; Max-Age={d}; Path=/; HttpOnly; SameSite=Lax{s}", .{
        policy.name(),
        text,
        max_age_seconds,
        secureAttribute(policy),
    });
}

/// The `Set-Cookie` value that removes the cookie.
pub fn clear(allocator: std.mem.Allocator, policy: Policy) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax{s}", .{
        policy.name(),
        secureAttribute(policy),
    });
}

fn secureAttribute(policy: Policy) []const u8 {
    return switch (policy) {
        .secure => "; Secure",
        .plain => "",
    };
}

test "read finds the session cookie among others" {
    try std.testing.expectEqualStrings("abc", read(.plain, "a=b; sid=abc; c=d").?);
    try std.testing.expectEqualStrings("abc", read(.secure, "__Host-sid=abc").?);
}

test "read ignores the other policy's name, malformed pairs and an absent header" {
    try std.testing.expect(read(.secure, "sid=abc") == null);
    try std.testing.expect(read(.plain, "__Host-sid=abc") == null);
    try std.testing.expect(read(.plain, "garbage; ;=; x") == null);
    try std.testing.expect(read(.plain, null) == null);
    try std.testing.expect(read(.plain, "xsid=abc") == null);
}

test "set writes an HttpOnly cookie, Secure only over HTTPS" {
    const text = token.encode(@splat(1));
    const secure = try set(std.testing.allocator, .secure, text);
    defer std.testing.allocator.free(secure);
    try std.testing.expect(std.mem.startsWith(u8, secure, "__Host-sid="));
    try std.testing.expect(std.mem.find(u8, secure, "; HttpOnly") != null);
    try std.testing.expect(std.mem.find(u8, secure, "; SameSite=Lax") != null);
    try std.testing.expect(std.mem.endsWith(u8, secure, "; Secure"));

    const plain = try set(std.testing.allocator, .plain, text);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.startsWith(u8, plain, "sid="));
    try std.testing.expect(std.mem.find(u8, plain, "Secure") == null);
}

test "clear expires the cookie immediately" {
    const cleared = try clear(std.testing.allocator, .secure);
    defer std.testing.allocator.free(cleared);
    try std.testing.expect(std.mem.startsWith(u8, cleared, "__Host-sid=;"));
    try std.testing.expect(std.mem.find(u8, cleared, "Max-Age=0") != null);
}
