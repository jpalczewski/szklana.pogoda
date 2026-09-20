//! Gzip for the pages and assets the server sends. The build compresses what it
//! embeds once (`tools/i18n_gen.zig` imports this file), and a response built
//! per request is compressed here when it is asked for.

const std = @import("std");
const flate = std.compress.flate;

pub const Options = flate.Compress.Options;

/// `input` as one gzip member. The output is the same for the same input and
/// options: the header carries no timestamp, so a rebuild changes nothing it
/// need not.
pub fn gzip(allocator: std.mem.Allocator, input: []const u8, options: Options) std.mem.Allocator.Error![]u8 {
    // The compressor's tables are far too large for a request thread's stack.
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    const compressor = try allocator.create(flate.Compress);
    defer allocator.destroy(compressor);

    // Writing to memory fails only when memory runs out.
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, input.len / 3 + 64);
    errdefer output.deinit();
    compressor.* = flate.Compress.init(&output.writer, window, .gzip, options) catch return error.OutOfMemory;
    compressor.writer.writeAll(input) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

/// Whether an `Accept-Encoding` value lists gzip and does not refuse it with
/// `q=0`. A wildcard is not taken as consent: the plain body is always right.
pub fn acceptsGzip(header: ?[]const u8) bool {
    const value = header orelse return false;
    var codings = std.mem.tokenizeScalar(u8, value, ',');
    while (codings.next()) |coding| {
        var parts = std.mem.splitScalar(u8, coding, ';');
        const name = std.mem.trim(u8, parts.first(), " \t");
        if (!std.ascii.eqlIgnoreCase(name, "gzip") and !std.ascii.eqlIgnoreCase(name, "x-gzip")) continue;
        while (parts.next()) |parameter| {
            const trimmed = std.mem.trim(u8, parameter, " \t");
            if (trimmed.len < 2 or std.ascii.toLower(trimmed[0]) != 'q' or trimmed[1] != '=') continue;
            const weight = std.fmt.parseFloat(f32, trimmed[2..]) catch return true;
            return weight > 0;
        }
        return true;
    }
    return false;
}

fn gunzip(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    // zlinter-disable-next-line no_undefined - filled by the decompressor before being read
    var window: [flate.max_window_len]u8 = undefined;
    var decompressor: flate.Decompress = .init(&input, .gzip, &window);
    return decompressor.reader.allocRemaining(allocator, .unlimited);
}

test "gzip round-trips and shrinks repetitive text" {
    const text = "<li role=\"tab\" x-show=\"open\">Prognoza</li>\n" ** 200;
    const compressed = try gzip(std.testing.allocator, text, .best);
    defer std.testing.allocator.free(compressed);

    try std.testing.expect(compressed.len < text.len / 10);
    try std.testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, compressed[0..2]);
    const restored = try gunzip(std.testing.allocator, compressed);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(text, restored);
}

test "gzip handles an empty input and one longer than the window" {
    const empty = try gzip(std.testing.allocator, "", .default);
    defer std.testing.allocator.free(empty);
    const restored_empty = try gunzip(std.testing.allocator, empty);
    defer std.testing.allocator.free(restored_empty);
    try std.testing.expectEqualStrings("", restored_empty);

    const long = try std.testing.allocator.alloc(u8, flate.history_len * 3 + 17);
    defer std.testing.allocator.free(long);
    for (long, 0..) |*byte, index| byte.* = @intCast((index * 7 + index / 251) % 256);
    const compressed = try gzip(std.testing.allocator, long, .fastest);
    defer std.testing.allocator.free(compressed);
    const restored = try gunzip(std.testing.allocator, compressed);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualSlices(u8, long, restored);
}

test "gzip gives the same bytes for the same input" {
    const first = try gzip(std.testing.allocator, "same input, same output", .best);
    defer std.testing.allocator.free(first);
    const second = try gzip(std.testing.allocator, "same input, same output", .best);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
}

test "acceptsGzip reads the usual browser headers" {
    try std.testing.expect(acceptsGzip("gzip, deflate, br"));
    try std.testing.expect(acceptsGzip("br;q=1.0, gzip;q=0.8, *;q=0.1"));
    try std.testing.expect(acceptsGzip("deflate,GZIP"));
    try std.testing.expect(acceptsGzip("x-gzip"));
    try std.testing.expect(acceptsGzip("gzip;q=0.001"));
}

test "acceptsGzip says no when gzip is absent, refused or the header is missing" {
    try std.testing.expect(!acceptsGzip(null));
    try std.testing.expect(!acceptsGzip(""));
    try std.testing.expect(!acceptsGzip("br, deflate"));
    try std.testing.expect(!acceptsGzip("identity"));
    try std.testing.expect(!acceptsGzip("*"));
    try std.testing.expect(!acceptsGzip("gzip;q=0"));
    try std.testing.expect(!acceptsGzip("gzip; q=0.0, br"));
    try std.testing.expect(!acceptsGzip("notgzip"));
}
