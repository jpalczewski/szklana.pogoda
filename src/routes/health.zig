const std = @import("std");
const router = @import("../router.zig");

/// The container's healthcheck. It answers from the router alone, with no
/// database, network or `/proc` read, so it proves the server takes requests
/// and nothing else. It is registered `quiet`: a probe every few seconds would
/// otherwise be most of the access log and most of the request metrics.
pub fn health(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return .{ .status = .ok, .content_type = "text/plain; charset=utf-8", .body = "ok\n" };
}

test "the healthcheck answers ok without any application state" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/healthz",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const response = try health(&app, &request);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqualStrings("ok\n", response.body);
}
