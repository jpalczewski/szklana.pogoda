const std = @import("std");
const Io = std.Io;
const value = @import("value.zig");

pub const Error = value.Error;

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
