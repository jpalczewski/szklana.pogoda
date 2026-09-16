const std = @import("std");

/// The whole module shares one error set so transports, shared decoders and
/// per-product parsers can be composed without error-set conversions:
/// allocation failure, malformed IMGW data, or an unreachable endpoint.
pub const Error = std.mem.Allocator.Error || error{ InvalidData, NetworkUnavailable };

/// IMGW publishes every measurement as a string and signals "no measurement"
/// with several spellings, including an empty string.
pub fn isMissing(value: []const u8) bool {
    return value.len == 0 or
        std.mem.eql(u8, value, "-") or
        std.ascii.eqlIgnoreCase(value, "brak") or
        std.ascii.eqlIgnoreCase(value, "brak.");
}

/// Parses an optional IMGW number of any numeric type, mapping every missing
/// marker to null.
pub fn optionalNumber(comptime T: type, value: ?[]const u8) Error!?T {
    const text = value orelse return null;
    if (isMissing(text)) return null;
    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, text) catch error.InvalidData,
        .int => std.fmt.parseInt(T, text, 10) catch error.InvalidData,
        else => @compileError("optionalNumber expects a float or an integer type"),
    };
}

pub fn optionalFloat(value: ?[]const u8) Error!?f64 {
    return optionalNumber(f64, value);
}

pub fn optionalInt(value: ?[]const u8) Error!?i16 {
    return optionalNumber(i16, value);
}

pub fn optionalInt32(value: ?[]const u8) Error!?i32 {
    return optionalNumber(i32, value);
}

/// Copies an optional IMGW string, mapping every missing marker to null.
/// The returned slice is owned by `allocator`.
pub fn optionalText(allocator: std.mem.Allocator, value: ?[]const u8) Error!?[]u8 {
    const text = value orelse return null;
    if (isMissing(text)) return null;
    return try allocator.dupe(u8, text);
}

/// Copies a text field the payload must contain. A missing JSON field is an
/// error, but IMGW's missing markers (`""`, `"-"`, `"brak"`) are kept verbatim:
/// a dash in a text field such as a river name is data, not an absent value.
pub fn presentText(allocator: std.mem.Allocator, value: ?[]const u8) Error![]u8 {
    return allocator.dupe(u8, value orelse return error.InvalidData);
}

/// IMGW timestamps are `"YYYY-MM-DD HH:MM:SS"` in Europe/Warsaw wall-clock
/// time, without an offset.
pub fn isTimestamp(text: []const u8) bool {
    return text.len == 19 and text[4] == '-' and text[7] == '-' and
        text[10] == ' ' and text[13] == ':' and text[16] == ':';
}

/// Validates and copies an optional IMGW timestamp, keeping its original
/// local-time form.
pub fn optionalTimestamp(allocator: std.mem.Allocator, value: ?[]const u8) Error!?[]u8 {
    const text = value orelse return null;
    if (isMissing(text)) return null;
    if (!isTimestamp(text)) return error.InvalidData;
    return try allocator.dupe(u8, text);
}

/// Rewrites an IMGW wall-clock timestamp as the ISO-like, UTC-suffixed form
/// the store keeps, for example `"2026-09-17T07:00:00Z"`.
pub fn utcTimestamp(allocator: std.mem.Allocator, local: []const u8) Error![]u8 {
    if (!isTimestamp(local)) return error.InvalidData;
    return std.fmt.allocPrint(allocator, "{s}T{s}Z", .{ local[0..10], local[11..] });
}

test "missing markers cover empty, dash and brak spellings" {
    try std.testing.expect(isMissing(""));
    try std.testing.expect(isMissing("-"));
    try std.testing.expect(isMissing("brak"));
    try std.testing.expect(isMissing("Brak."));
    try std.testing.expect(!isMissing("0"));
    try std.testing.expect(!isMissing("Brak opadów"));
}

test "optional numbers treat missing markers as null" {
    try std.testing.expectEqual(@as(?f64, null), try optionalFloat(""));
    try std.testing.expectEqual(@as(?f64, null), try optionalFloat("brak"));
    try std.testing.expectEqual(@as(?f64, 12.5), try optionalFloat("12.5"));
    try std.testing.expectEqual(@as(?i16, -1), try optionalInt("-1"));
    try std.testing.expectEqual(@as(?i32, 300), try optionalInt32("300"));
    try std.testing.expectError(error.InvalidData, optionalFloat("n/a"));
    try std.testing.expectError(error.InvalidData, optionalInt("1.5"));
}

test "present text keeps IMGW markers but rejects absent fields" {
    const river = try presentText(std.testing.allocator, "-");
    defer std.testing.allocator.free(river);
    try std.testing.expectEqualStrings("-", river);

    const empty = try presentText(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    try std.testing.expectError(error.InvalidData, presentText(std.testing.allocator, null));
}

test "timestamps must look like IMGW local time" {
    const text = (try optionalTimestamp(std.testing.allocator, "2026-09-17 07:00:00")).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2026-09-17 07:00:00", text);

    try std.testing.expectEqual(@as(?[]u8, null), try optionalTimestamp(std.testing.allocator, "Brak."));
    try std.testing.expectError(error.InvalidData, optionalTimestamp(std.testing.allocator, "2026-09-17"));
}

test "local timestamps are rewritten with a UTC suffix" {
    const utc = try utcTimestamp(std.testing.allocator, "2026-09-17 07:00:00");
    defer std.testing.allocator.free(utc);
    try std.testing.expectEqualStrings("2026-09-17T07:00:00Z", utc);

    try std.testing.expectError(error.InvalidData, utcTimestamp(std.testing.allocator, "2026-09-17"));
}
