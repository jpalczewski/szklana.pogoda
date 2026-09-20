//! Session tokens: what the cookie carries and what the database keeps of it.
//!
//! A token is 256 random bits, so it cannot be guessed and its hash needs no
//! salt or stretching. The database stores only the SHA-256 of the token, so a
//! copy of the database is not a copy of anybody's session.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const secret_bytes = 32;
pub const hash_bytes = Sha256.digest_length;
/// Length of a token as text: base64url of `secret_bytes`, without padding.
pub const text_len = std.base64.url_safe_no_pad.Encoder.calcSize(secret_bytes);

pub const Hash = [hash_bytes]u8;
pub const Text = [text_len]u8;

/// Draws a new token from the system's secure source, as the text the cookie
/// carries.
pub fn generate(io: Io) Io.RandomSecureError!Text {
    // zlinter-disable-next-line no_undefined - filled by randomSecure before being read
    var secret: [secret_bytes]u8 = undefined;
    try io.randomSecure(&secret);
    return encode(secret);
}

pub fn encode(secret: [secret_bytes]u8) Text {
    // zlinter-disable-next-line no_undefined - filled by encode before being read
    var text: Text = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&text, &secret);
    return text;
}

/// The hash the store keeps for `text`, or null when `text` cannot be a token
/// this module produced. Rejecting on shape keeps garbage out of the lookup.
pub fn hash(text: []const u8) ?Hash {
    if (text.len != text_len) return null;
    // zlinter-disable-next-line no_undefined - filled by decode before being read
    var secret: [secret_bytes]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&secret, text) catch return null;
    // zlinter-disable-next-line no_undefined - filled by Sha256.hash before being read
    var digest: Hash = undefined;
    Sha256.hash(&secret, &digest, .{});
    return digest;
}

test "a generated token round-trips into a stable hash" {
    const first = try generate(std.testing.io);
    const second = try generate(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    try std.testing.expectEqualSlices(u8, &hash(&first).?, &hash(&first).?);
    try std.testing.expect(!std.mem.eql(u8, &hash(&first).?, &hash(&second).?));
}

test "the token text is url safe and has the documented length" {
    const text = try generate(std.testing.io);
    try std.testing.expectEqual(@as(usize, 43), text.len);
    for (text) |byte| {
        try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_');
    }
}

test "text that is not a token has no hash" {
    try std.testing.expect(hash("") == null);
    try std.testing.expect(hash("short") == null);
    try std.testing.expect(hash("!" ** text_len) == null);
    try std.testing.expect(hash("A" ** (text_len + 1)) == null);
}

test "the hash is the SHA-256 of the decoded secret" {
    const secret: [secret_bytes]u8 = @splat(7);
    const text = encode(secret);
    var expected: Hash = undefined;
    Sha256.hash(&secret, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &hash(&text).?);
}
