const std = @import("std");
const Io = std.Io;
const value = @import("value.zig");
const http_fetch = @import("../http_fetch.zig");

pub const Error = value.Error;

/// Fetches an IMGW JSON document. The caller owns the returned bytes.
pub fn get(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]u8 {
    return http_fetch.get(allocator, io, url);
}

/// IMGW answers a product that has no records right now with a 404 and this
/// message, not with an empty array.
const no_products_message = "No products were found";

/// Whether an answer is IMGW saying the product is empty, as opposed to the
/// endpoint being gone or unreachable, which stays an error.
fn isNoProducts(status: std.http.Status, body: []const u8) bool {
    return status == .not_found and std.mem.find(u8, body, no_products_message) != null;
}

/// Like `get`, but an empty product (see `isNoProducts`) is `null`.
pub fn getOrNone(allocator: std.mem.Allocator, io: Io, url: []const u8) Error!?[]u8 {
    const answer = try http_fetch.getAnswer(allocator, io, url);
    if (answer.status == .ok) return answer.body;
    defer allocator.free(answer.body);
    if (isNoProducts(answer.status, answer.body)) return null;
    return error.NetworkUnavailable;
}

/// Like `fetchParsed`, for a product that IMGW leaves empty at times: an empty
/// product is an empty batch, owned by `allocator` like any other.
pub fn fetchParsedOrEmpty(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: Io,
    url: []const u8,
    comptime parse: fn (std.mem.Allocator, []const u8) Error!T,
) Error!T {
    const body = try getOrNone(allocator, io, url) orelse return allocator.alloc(std.meta.Child(T), 0);
    defer allocator.free(body);
    return parse(allocator, body);
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

test "only IMGW's own no-products answer is an empty product" {
    const message = "{\"status\":false,\"message\":\"No products were found\"}";
    try std.testing.expect(isNoProducts(.not_found, message));
    // A gone endpoint, a server error and a 404 page are failures, not silence.
    try std.testing.expect(!isNoProducts(.not_found, "<html>Not Found</html>"));
    try std.testing.expect(!isNoProducts(.internal_server_error, message));
    try std.testing.expect(!isNoProducts(.ok, message));
}
