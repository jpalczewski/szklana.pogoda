const std = @import("std");
const router = @import("../router.zig");
const process_memory = @import("../process_memory.zig");

pub fn ping(_: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    return router.Response.jsonValue(request.allocator, .ok, .{ .status = "pong" });
}

pub fn memory(_: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const usage = process_memory.read() catch |err| {
        std.log.err("memory statistics unavailable: {t}", .{err});
        return error.MemoryStatisticsUnavailable;
    };
    return router.Response.jsonValue(request.allocator, .ok, usage);
}

test "ping endpoint returns JSON status" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .POST,
        .path = "/api/ping",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const response = try ping(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", response.content_type);
    try std.testing.expectEqualStrings("{\"status\":\"pong\"}", response.body);
}

test "memory endpoint returns JSON memory statistics" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/memory",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const response = try memory(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", response.content_type);
    try std.testing.expect(std.mem.startsWith(u8, response.body, "{\"rss_bytes\":"));
    try std.testing.expect(std.mem.indexOf(u8, response.body, ",\"virtual_memory_bytes\":") != null);
    try std.testing.expect(std.mem.endsWith(u8, response.body, "}"));
}

test "memory endpoint only allows GET" {
    const routes = [_]router.Route{.{ .method = .GET, .path = "/api/memory", .handler = memory }};
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .POST,
        .path = "/api/memory",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const response = try router.dispatch(&routes, &app, &request);
    defer std.testing.allocator.free(response.allow.?);
    try std.testing.expectEqual(.method_not_allowed, response.status);
    try std.testing.expectEqualStrings("GET", response.allow.?);
}
