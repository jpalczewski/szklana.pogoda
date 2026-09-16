const std = @import("std");
const http = std.http;
const Io = std.Io;
const metrics = @import("metrics.zig");
const weather_store = @import("weather_store.zig");

pub const App = struct {
    max_body_bytes: usize,
    trust_proxy: bool = false,
    metrics: ?*metrics.Registry = null,
    weather_store: ?*weather_store.Store = null,
};

pub const AppError = std.mem.Allocator.Error || error{
    BadRequest,
    BodyReadFailed,
    MemoryStatisticsUnavailable,
    WeatherStoreUnavailable,
    PayloadTooLarge,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    status: http.Status,
    content_type: []const u8,
    body: []const u8,
    allow: ?[]const u8 = null,

    pub fn html(body: []const u8) Response {
        return .{ .status = .ok, .content_type = "text/html; charset=utf-8", .body = body };
    }

    pub fn css(body: []const u8) Response {
        return .{ .status = .ok, .content_type = "text/css; charset=utf-8", .body = body };
    }

    pub fn javascript(body: []const u8) Response {
        return .{ .status = .ok, .content_type = "text/javascript; charset=utf-8", .body = body };
    }

    pub fn json(status: http.Status, body: []const u8) Response {
        return .{ .status = status, .content_type = "application/json; charset=utf-8", .body = body };
    }

    pub fn jsonValue(allocator: std.mem.Allocator, status: http.Status, value: anytype) std.mem.Allocator.Error!Response {
        return json(status, try std.json.Stringify.valueAlloc(allocator, value, .{}));
    }

    pub fn text(status: http.Status, body: []const u8) Response {
        return .{ .status = status, .content_type = "text/plain; charset=utf-8", .body = body };
    }
};

pub const Body = struct {
    reader: *Io.Reader,
    remaining: usize,

    pub fn init(reader: *Io.Reader, max_bytes: usize) Body {
        return .{ .reader = reader, .remaining = max_bytes };
    }

    /// Reads at most `max_body_bytes` in total. A read after the limit is
    /// reached probes the source for one byte, allowing chunked bodies that
    /// exceed the limit to become a 413 instead of silently looking complete.
    pub fn read(self: *Body, buffer: []u8) AppError!usize {
        if (buffer.len == 0) return 0;

        if (self.remaining == 0) {
            var probe: [1]u8 = undefined;
            const n = self.reader.readSliceShort(&probe) catch |err| switch (err) {
                error.EndOfStream => return 0,
                error.ReadFailed => return error.BodyReadFailed,
            };
            if (n == 0) return 0;
            return error.PayloadTooLarge;
        }

        const n = self.reader.readSliceShort(buffer[0..@min(buffer.len, self.remaining)]) catch |err| switch (err) {
            error.EndOfStream => return 0,
            error.ReadFailed => return error.BodyReadFailed,
        };
        self.remaining -= n;
        return n;
    }

    pub fn readAll(self: *Body, allocator: std.mem.Allocator) AppError![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = try self.read(&chunk);
            if (n == 0) break;
            try bytes.appendSlice(allocator, chunk[0..n]);
        }
        return try bytes.toOwnedSlice(allocator);
    }
};

pub const RequestContext = struct {
    allocator: std.mem.Allocator,
    method: http.Method,
    path: []const u8,
    query: ?[]const u8,
    headers: []const Header,
    body: ?*Body,

    pub fn header(self: *const RequestContext, name: []const u8) ?[]const u8 {
        for (self.headers) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }
};

pub const Handler = *const fn (*App, *RequestContext) AppError!Response;

pub const Route = struct {
    method: http.Method,
    path: []const u8,
    handler: Handler,
};

pub fn dispatch(routes: []const Route, app: *App, request: *RequestContext) AppError!Response {
    var path_exists = false;
    for (routes) |route| {
        if (!std.mem.eql(u8, route.path, request.path)) continue;
        path_exists = true;
        if (route.method == request.method) return route.handler(app, request);
    }

    if (!path_exists) return notFound(request.allocator, request.path);
    return methodNotAllowed(routes, request);
}

pub fn splitTarget(target: []const u8) struct { path: []const u8, query: ?[]const u8 } {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return .{ .path = target, .query = null };
    return .{ .path = target[0..query_start], .query = target[query_start + 1 ..] };
}

pub fn errorResponse(allocator: std.mem.Allocator, path: []const u8, err: AppError) Response {
    return switch (err) {
        error.BadRequest, error.BodyReadFailed => errorFor(allocator, path, .bad_request, .bad_request),
        error.PayloadTooLarge => errorFor(allocator, path, .payload_too_large, .payload_too_large),
        error.MemoryStatisticsUnavailable, error.WeatherStoreUnavailable, error.OutOfMemory => errorFor(allocator, path, .internal_server_error, .internal_server_error),
    };
}

fn notFound(allocator: std.mem.Allocator, path: []const u8) Response {
    return errorFor(allocator, path, .not_found, .not_found);
}

fn methodNotAllowed(routes: []const Route, request: *RequestContext) Response {
    var allow: std.ArrayList(u8) = .empty;
    for (routes) |route| {
        if (!std.mem.eql(u8, route.path, request.path)) continue;
        if (allow.items.len != 0) allow.appendSlice(request.allocator, ", ") catch return errorFor(request.allocator, request.path, .internal_server_error, .internal_server_error);
        allow.appendSlice(request.allocator, @tagName(route.method)) catch return errorFor(request.allocator, request.path, .internal_server_error, .internal_server_error);
    }

    var response = errorFor(request.allocator, request.path, .method_not_allowed, .method_not_allowed);
    response.allow = allow.toOwnedSlice(request.allocator) catch return errorFor(request.allocator, request.path, .internal_server_error, .internal_server_error);
    return response;
}

const ErrorMessage = enum {
    bad_request,
    internal_server_error,
    method_not_allowed,
    not_found,
    payload_too_large,

    fn apiText(self: ErrorMessage) []const u8 {
        return switch (self) {
            .bad_request => "Bad request",
            .internal_server_error => "Internal server error",
            .method_not_allowed => "Method not allowed",
            .not_found => "Not found",
            .payload_too_large => "Payload too large",
        };
    }

    fn text(self: ErrorMessage) []const u8 {
        return switch (self) {
            .bad_request => "bad request",
            .internal_server_error => "internal server error",
            .method_not_allowed => "method not allowed",
            .not_found => "not found",
            .payload_too_large => "payload too large",
        };
    }
};

fn errorFor(allocator: std.mem.Allocator, path: []const u8, status: http.Status, message: ErrorMessage) Response {
    if (isApiPath(path)) {
        return Response.jsonValue(allocator, status, .{ .@"error" = message.apiText() }) catch Response.json(.internal_server_error, internal_server_error_json);
    }
    return Response.text(status, message.text());
}

const internal_server_error_json = "{\"error\":\"Internal server error\"}";

pub fn isApiPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/");
}

test "router matches path independently of query string" {
    const target = splitTarget("/api/ping?trace=1");
    try std.testing.expectEqualStrings("/api/ping", target.path);
    try std.testing.expectEqualStrings("trace=1", target.query.?);
}

test "router returns 405 with every allowed method" {
    const testHandler = struct {
        fn handle(_: *App, _: *RequestContext) AppError!Response {
            return Response.text(.ok, "ok");
        }
    }.handle;
    const test_routes = [_]Route{
        .{ .method = .GET, .path = "/item", .handler = testHandler },
        .{ .method = .POST, .path = "/item", .handler = testHandler },
    };
    var app: App = .{ .max_body_bytes = 16 };
    var request: RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .PUT,
        .path = "/item",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const response = try dispatch(&test_routes, &app, &request);
    defer if (response.allow) |allow| std.testing.allocator.free(allow);
    try std.testing.expectEqual(http.Status.method_not_allowed, response.status);
    try std.testing.expectEqualStrings("GET, POST", response.allow.?);
}

test "router returns JSON errors for API routes" {
    const test_routes = [_]Route{.{ .method = .GET, .path = "/api/item", .handler = unreachableHandler }};
    var app: App = .{ .max_body_bytes = 16 };
    var request: RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .POST,
        .path = "/api/item",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const method_response = try dispatch(&test_routes, &app, &request);
    defer std.testing.allocator.free(method_response.body);
    defer std.testing.allocator.free(method_response.allow.?);
    try std.testing.expectEqual(http.Status.method_not_allowed, method_response.status);
    try std.testing.expectEqualStrings("{\"error\":\"Method not allowed\"}", method_response.body);
    try std.testing.expectEqualStrings("GET", method_response.allow.?);

    request.path = "/api/missing";
    const missing_response = try dispatch(&test_routes, &app, &request);
    defer std.testing.allocator.free(missing_response.body);
    try std.testing.expectEqual(http.Status.not_found, missing_response.status);
    try std.testing.expectEqualStrings("{\"error\":\"Not found\"}", missing_response.body);
}

fn unreachableHandler(_: *App, _: *RequestContext) AppError!Response {
    unreachable;
}

test "limit is enforced while body is read" {
    var source = Io.Reader.fixed("hello");
    var body = Body.init(&source, 4);
    try std.testing.expectError(error.PayloadTooLarge, body.readAll(std.testing.allocator));
}

test "request context looks up headers without case sensitivity" {
    const headers = [_]Header{.{ .name = "Content-Type", .value = "application/json" }};
    const request: RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .POST,
        .path = "/api/ping",
        .query = null,
        .headers = &headers,
        .body = null,
    };
    try std.testing.expectEqualStrings("application/json", request.header("content-type").?);
}
