const router = @import("../router.zig");

pub fn metrics(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const registry = app.metrics orelse return error.OutOfMemory;
    const body = try registry.render(request.allocator);
    return .{
        .status = .ok,
        .content_type = "text/plain; version=0.0.4; charset=utf-8",
        .body = body,
    };
}
