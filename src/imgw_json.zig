const std = @import("std");
const Io = std.Io;

pub const Error = std.mem.Allocator.Error || error{ InvalidData, NetworkUnavailable };

/// Fetches an IMGW JSON document. The caller owns the returned bytes.
pub fn get(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_body: Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response_body.writer,
    }) catch return error.NetworkUnavailable;
    if (result.status != .ok) return error.NetworkUnavailable;

    return response_body.toOwnedSlice() catch return error.OutOfMemory;
}

/// IMGW uses several spellings for "no measurement", including an empty string.
pub fn isMissing(value: []const u8) bool {
    return value.len == 0 or
        std.mem.eql(u8, value, "-") or
        std.ascii.eqlIgnoreCase(value, "brak") or
        std.ascii.eqlIgnoreCase(value, "brak.");
}

pub fn optionalFloat(value: ?[]const u8) !?f64 {
    const text = value orelse return null;
    if (isMissing(text)) return null;
    return std.fmt.parseFloat(f64, text) catch error.InvalidData;
}

pub fn optionalInt(value: ?[]const u8) !?i16 {
    const text = value orelse return null;
    if (isMissing(text)) return null;
    return std.fmt.parseInt(i16, text, 10) catch error.InvalidData;
}

pub fn optionalInt32(value: ?[]const u8) !?i32 {
    const text = value orelse return null;
    if (isMissing(text)) return null;
    return std.fmt.parseInt(i32, text, 10) catch error.InvalidData;
}

pub fn optionalText(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const text = value orelse return null;
    if (isMissing(text)) return null;
    return try allocator.dupe(u8, text);
}

/// Validates and copies an IMGW timestamp, keeping its original
/// `"YYYY-MM-DD HH:MM:SS"` local-time form.
pub fn optionalTimestamp(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    const text = value orelse return null;
    if (isMissing(text)) return null;
    if (text.len != 19 or text[10] != ' ' or text[4] != '-' or text[7] != '-' or
        text[13] != ':' or text[16] != ':') return error.InvalidData;
    return try allocator.dupe(u8, text);
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
    try std.testing.expectError(error.InvalidData, optionalFloat("n/a"));
}

test "timestamps must look like IMGW local time" {
    const text = (try optionalTimestamp(std.testing.allocator, "2026-09-17 07:00:00")).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2026-09-17 07:00:00", text);

    try std.testing.expectEqual(@as(?[]u8, null), try optionalTimestamp(std.testing.allocator, "Brak."));
    try std.testing.expectError(error.InvalidData, optionalTimestamp(std.testing.allocator, "2026-09-17"));
}
