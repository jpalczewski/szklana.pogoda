const std = @import("std");
const router = @import("../router.zig");
const process_memory = @import("../process_memory.zig");

pub fn metrics(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const registry = app.metrics orelse return error.OutOfMemory;
    // The memory gauges are read at scrape time. A platform that cannot
    // report them still answers the rest of the metrics.
    if (process_memory.read()) |usage| {
        registry.setProcessMemory(usage.rss_bytes, usage.virtual_memory_bytes, usage.own_bytes);
    } else |err| {
        std.log.warn("process memory left out of the scrape: {t}", .{err});
    }
    const body = try registry.renderAlloc(request.allocator);
    return .{
        .status = .ok,
        .content_type = "text/plain; version=0.0.4; charset=utf-8",
        .body = body,
    };
}

test "a scrape renders the request metrics and the process memory" {
    const metrics_module = @import("../metrics.zig");
    var registry = metrics_module.Registry.init(std.testing.allocator);
    defer registry.deinit();
    registry.begin("GET", "/");
    registry.finish("GET", "/", 200, std.time.ns_per_ms);
    registry.end("GET", "/");

    var app: router.App = .{ .max_body_bytes = 16, .metrics = &registry };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/metrics",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const response = try metrics(&app, &request);
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expect(std.mem.find(u8, response.body, "szklana_pogoda_http_requests_total{method=\"GET\",route=\"/\",status=\"200\"} 1\n") != null);
    if (process_memory.read()) |_| {
        try std.testing.expect(std.mem.find(u8, response.body, "process_resident_memory_bytes ") != null);
    } else |_| {}
}
