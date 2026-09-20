//! Sign-in codes: what a person types to bring an account to another browser.
//!
//! Two kinds share one alphabet and one field. A transfer code is short and
//! lives ten minutes: the signed-in browser shows it and the other one types it.
//! A recovery code is long and stays valid: it is the way back in for someone who
//! has lost every browser. The length of what was typed tells them apart, so the
//! person never has to say which they have.
//!
//! The alphabet is Crockford's base32, which leaves out the letters that read as
//! digits. A code is drawn from the system's secure source one character per
//! random byte; 256 is a multiple of 32, so masking a byte gives every character
//! the same chance.
//!
//! Like a session token, only the hash of a code is stored. A code is a secret
//! and never appears in a URL, a log line, an error text or a metric label.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const token = @import("token.zig");

pub const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub const Kind = enum {
    recovery,
    transfer,

    /// How many characters the code has.
    pub fn length(self: Kind) usize {
        return switch (self) {
            .recovery => 20,
            .transfer => 10,
        };
    }

    /// How many characters stand between two dashes when the code is shown.
    fn groupSize(self: Kind) usize {
        return switch (self) {
            .recovery => 4,
            .transfer => 5,
        };
    }
};

pub const max_length = Kind.recovery.length();

/// The largest text `format` produces: the code and a dash between groups.
pub const max_formatted_length = max_length + max_length / Kind.recovery.groupSize() - 1;

/// What a person may type is bounded before it is looked at, so an oversized
/// request costs nothing.
const max_input_bytes = 64;

/// A code in its canonical form: capital letters and digits of the alphabet, with
/// no dashes or spaces. Its length is its kind.
pub const Code = struct {
    kind: Kind,
    chars: [max_length]u8,

    pub fn text(self: *const Code) []const u8 {
        return self.chars[0..self.kind.length()];
    }

    /// The hash the store keeps.
    pub fn hash(self: *const Code) token.Hash {
        // zlinter-disable-next-line no_undefined - filled by Sha256.hash before being read
        var digest: token.Hash = undefined;
        Sha256.hash(self.text(), &digest, .{});
        return digest;
    }

    /// The code as it is shown to a person, in groups.
    pub fn format(self: *const Code, out: *[max_formatted_length]u8) []const u8 {
        const group = self.kind.groupSize();
        var written: usize = 0;
        for (self.text(), 0..) |char, index| {
            if (index != 0 and index % group == 0) {
                out[written] = '-';
                written += 1;
            }
            out[written] = char;
            written += 1;
        }
        return out[0..written];
    }
};

/// Draws a new code of `kind`.
pub fn generate(io: Io, kind: Kind) Io.RandomSecureError!Code {
    // zlinter-disable-next-line no_undefined - filled by randomSecure before being read
    var random: [max_length]u8 = undefined;
    try io.randomSecure(random[0..kind.length()]);
    var code: Code = .{ .kind = kind, .chars = @splat(0) };
    for (random[0..kind.length()], code.chars[0..kind.length()]) |byte, *char| char.* = charFor(byte);
    return code;
}

fn charFor(byte: u8) u8 {
    return alphabet[byte & 31];
}

/// Reads what a person typed. Case, spaces and dashes do not matter, and the
/// letters the alphabet leaves out are read as the digits they look like:
/// `I` and `L` as 1, `O` as 0. Null when what is left is not a code of a known
/// length or holds a character no code has.
pub fn normalise(input: []const u8) ?Code {
    if (input.len > max_input_bytes) return null;
    var code: Code = .{ .kind = .transfer, .chars = @splat(0) };
    var count: usize = 0;
    for (input) |raw| {
        if (raw == ' ' or raw == '-' or raw == '\t') continue;
        const upper = std.ascii.toUpper(raw);
        const char: u8 = switch (upper) {
            'I', 'L' => '1',
            'O' => '0',
            else => upper,
        };
        if (std.mem.findScalar(u8, alphabet, char) == null) return null;
        if (count == max_length) return null;
        code.chars[count] = char;
        count += 1;
    }
    inline for (std.enums.values(Kind)) |kind| {
        if (count == kind.length()) {
            code.kind = kind;
            return code;
        }
    }
    return null;
}

test "a generated code has its kind's length and only alphabet characters" {
    inline for (std.enums.values(Kind)) |kind| {
        const code = try generate(std.testing.io, kind);
        try std.testing.expectEqual(kind.length(), code.text().len);
        for (code.text()) |char| try std.testing.expect(std.mem.findScalar(u8, alphabet, char) != null);
    }
}

test "two generated codes differ" {
    const first = try generate(std.testing.io, .recovery);
    const second = try generate(std.testing.io, .recovery);
    try std.testing.expect(!std.mem.eql(u8, first.text(), second.text()));
}

test "every character of the alphabet is equally likely" {
    var seen: [alphabet.len]usize = @splat(0);
    for (0..256) |byte| seen[std.mem.findScalar(u8, alphabet, charFor(@intCast(byte))).?] += 1;
    for (seen) |count| try std.testing.expectEqual(@as(usize, 8), count);
}

test "a code is shown in groups and reads back the same" {
    var buffer: [max_formatted_length]u8 = undefined;
    const transfer = normalise("abcde12345").?;
    try std.testing.expectEqualStrings("ABCDE-12345", transfer.format(&buffer));
    const recovery = normalise("0123456789ABCDEFGHJK").?;
    try std.testing.expectEqualStrings("0123-4567-89AB-CDEF-GHJK", recovery.format(&buffer));

    const typed = normalise(recovery.format(&buffer)).?;
    try std.testing.expectEqualStrings(recovery.text(), typed.text());
    try std.testing.expectEqual(Kind.recovery, typed.kind);
}

test "case, spaces and dashes do not matter and look-alike letters are read as digits" {
    const plain = normalise("ABCDE12345").?;
    for ([_][]const u8{ "abcde12345", "ABCDE-12345", " abcde 12345 ", "AB-CD-E1-23-45" }) |typed| {
        try std.testing.expectEqualStrings(plain.text(), normalise(typed).?.text());
    }
    try std.testing.expectEqualStrings("0110ABCDEF", normalise("OiLoabcdef").?.text());
}

test "text that is not a code is refused" {
    try std.testing.expect(normalise("") == null);
    try std.testing.expect(normalise("ABCDE1234") == null);
    try std.testing.expect(normalise("ABCDE123456") == null);
    try std.testing.expect(normalise("ABCDE1234U") == null);
    try std.testing.expect(normalise("ABCDE1234!") == null);
    try std.testing.expect(normalise("0123456789ABCDEFGHJKM") == null);
    try std.testing.expect(normalise("A" ** 65) == null);
}

test "the kind follows from the length" {
    try std.testing.expectEqual(Kind.transfer, normalise("ABCDE12345").?.kind);
    try std.testing.expectEqual(Kind.recovery, normalise("ABCDE12345ABCDE12345").?.kind);
}

test "the hash depends on the canonical text, not on how it was typed" {
    const first = normalise("abcde-12345").?;
    const second = normalise("ABCDE12345").?;
    const other = normalise("ABCDE12346").?;
    try std.testing.expectEqualSlices(u8, &first.hash(), &second.hash());
    try std.testing.expect(!std.mem.eql(u8, &first.hash(), &other.hash()));
}
