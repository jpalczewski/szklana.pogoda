const std = @import("std");
const Io = std.Io;
const value = @import("value.zig");
const http_fetch = @import("../http_fetch.zig");

pub const Error = value.Error;

/// Fetches an IMGW JSON document. The caller owns the returned bytes.
pub fn get(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]u8 {
    return http_fetch.get(allocator, io, url);
}

/// Fetches `url` and hands the body to `parse`, which owns the result. Every
/// product composes its endpoint with `parse` through this helper.
pub fn fetchParsed(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: Io,
    url: []const u8,
    comptime parse: fn (std.mem.Allocator, []const u8) Error!T,
) Error!T {
    const body = try get(allocator, io, url);
    defer allocator.free(body);
    return parse(allocator, body);
}
