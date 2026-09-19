const std = @import("std");
const http = std.http;
const Io = std.Io;
const antistorm = @import("antistorm/mod.zig");
const metrics = @import("metrics/mod.zig");
const weather = @import("weather/mod.zig");
const openmeteo = @import("openmeteo/mod.zig");
const trusted_proxies = @import("trusted_proxies.zig");

pub const App = struct {
    max_body_bytes: usize,
    /// Peers whose forwarded-address headers are believed; empty trusts none.
    trusted_proxies: trusted_proxies.TrustedProxies = .{},
    metrics: ?*metrics.Registry = null,
    weather_store: ?*weather.Store = null,
    /// Antistorm readings; left null by tests that do not exercise the storm
    /// routes.
    storm: ?*antistorm.Client = null,
    /// Open-Meteo forecasts; left null by tests that do not exercise the
    /// forecast route.
    forecast: ?*openmeteo.Client = null,
    /// Wall clock used by handlers that need "now"; left null by tests that
    /// do not exercise time dependent paths.
    io: ?Io = null,
};

pub const AppError = std.mem.Allocator.Error || error{
    BadRequest,
    BodyReadFailed,
    MemoryStatisticsUnavailable,
    WeatherStoreUnavailable,
    /// The Antistorm endpoint could not be reached or answered with unusable
    /// data. The site's own HTML error page for an id it does not know also
    /// arrives here.
    StormUnavailable,
    /// The storm route was asked for a city that is not in the published table.
    UnknownCity,
    /// The Open-Meteo endpoint could not be reached or answered with unusable
    /// data.
    ForecastUnavailable,
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
    /// Sent as `Cache-Control` when set. Without it the response carries no
    /// caching policy, and a CDN in front picks one for the file type.
    cache_control: ?[]const u8 = null,

    pub fn html(body: []const u8) Response {
        return .{ .status = .ok, .content_type = "text/html; charset=utf-8", .body = body };
    }

    pub fn css(body: []const u8) Response {
        return .{ .status = .ok, .content_type = "text/css; charset=utf-8", .body = body };
    }

    pub fn svg(body: []const u8) Response {
        return .{ .status = .ok, .content_type = "image/svg+xml", .body = body };
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
    /// Reaching the end of the body is reported as a short read, never as an
    /// error, which is what `readSliceShort` already does.
    pub fn read(self: *Body, buffer: []u8) AppError!usize {
        if (buffer.len == 0) return 0;

        if (self.remaining == 0) {
            // zlinter-disable-next-line no_undefined - overwritten by readSliceShort before being read
            var probe: [1]u8 = undefined;
            const n = self.reader.readSliceShort(&probe) catch return error.BodyReadFailed;
            if (n == 0) return 0;
            return error.PayloadTooLarge;
        }

        const n = self.reader.readSliceShort(buffer[0..@min(buffer.len, self.remaining)]) catch return error.BodyReadFailed;
        self.remaining -= n;
        return n;
    }

    pub fn readAll(self: *Body, allocator: std.mem.Allocator) AppError![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);

        // zlinter-disable-next-line no_undefined - overwritten by self.read before being read
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

    /// Looks up the first query parameter called `name`. Values are returned
    /// verbatim: the keys the API accepts are ASCII identifiers and their values
    /// are handed to the store as they arrive.
    pub fn param(self: *const RequestContext, name: []const u8) ?[]const u8 {
        var pairs = std.mem.splitScalar(u8, self.query orelse return null, '&');
        while (pairs.next()) |pair| {
            const separator = std.mem.findScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..separator], name)) return pair[separator + 1 ..];
        }
        return null;
    }
};

pub const Handler = *const fn (*App, *RequestContext) AppError!Response;

pub const Route = struct {
    method: http.Method,
    path: []const u8,
    handler: Handler,
    /// For a route that machines call all day (a healthcheck, a scrape): its
    /// requests are neither counted in the HTTP metrics nor written to the
    /// access log, except a failed one, which is logged.
    quiet: bool = false,
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
    const query_start = std.mem.findScalar(u8, target, '?') orelse return .{ .path = target, .query = null };
    return .{ .path = target[0..query_start], .query = target[query_start + 1 ..] };
}

pub fn errorResponse(allocator: std.mem.Allocator, path: []const u8, err: AppError) Response {
    return switch (err) {
        error.BadRequest, error.BodyReadFailed => errorFor(allocator, path, .bad_request, .bad_request),
        error.PayloadTooLarge => errorFor(allocator, path, .payload_too_large, .payload_too_large),
        error.UnknownCity => errorFor(allocator, path, .not_found, .city_not_found),
        error.StormUnavailable => errorFor(allocator, path, .bad_gateway, .storm_unavailable),
        error.ForecastUnavailable => errorFor(allocator, path, .bad_gateway, .forecast_unavailable),
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
    city_not_found,
    forecast_unavailable,
    internal_server_error,
    method_not_allowed,
    not_found,
    payload_too_large,
    storm_unavailable,

    fn apiText(self: ErrorMessage) []const u8 {
        return switch (self) {
            .bad_request => "Bad request",
            .city_not_found => "City not found",
            .forecast_unavailable => "Forecast data unavailable",
            .internal_server_error => "Internal server error",
            .method_not_allowed => "Method not allowed",
            .not_found => "Not found",
            .payload_too_large => "Payload too large",
            .storm_unavailable => "Storm data unavailable",
        };
    }

    fn text(self: ErrorMessage) []const u8 {
        return switch (self) {
            .bad_request => "bad request",
            .city_not_found => "city not found",
            .forecast_unavailable => "forecast data unavailable",
            .internal_server_error => "internal server error",
            .method_not_allowed => "method not allowed",
            .not_found => "not found",
            .payload_too_large => "payload too large",
            .storm_unavailable => "storm data unavailable",
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

test "router maps storm failures onto 404 and 502" {
    const unknown = errorResponse(std.testing.allocator, "/api/storm/city", error.UnknownCity);
    defer std.testing.allocator.free(unknown.body);
    try std.testing.expectEqual(http.Status.not_found, unknown.status);
    try std.testing.expectEqualStrings("{\"error\":\"City not found\"}", unknown.body);

    const unavailable = errorResponse(std.testing.allocator, "/api/storm/city", error.StormUnavailable);
    defer std.testing.allocator.free(unavailable.body);
    try std.testing.expectEqual(http.Status.bad_gateway, unavailable.status);
    try std.testing.expectEqualStrings("{\"error\":\"Storm data unavailable\"}", unavailable.body);
}

test "router maps forecast failures onto 502" {
    const unavailable = errorResponse(std.testing.allocator, "/api/forecast", error.ForecastUnavailable);
    defer std.testing.allocator.free(unavailable.body);
    try std.testing.expectEqual(http.Status.bad_gateway, unavailable.status);
    try std.testing.expectEqualStrings("{\"error\":\"Forecast data unavailable\"}", unavailable.body);
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

test "request context reads query parameters" {
    const request: RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/weather/history",
        .query = "station_id=12424&since=2026-09-16T00:00:00Z&empty=&flag",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectEqualStrings("12424", request.param("station_id").?);
    try std.testing.expectEqualStrings("2026-09-16T00:00:00Z", request.param("since").?);
    try std.testing.expectEqualStrings("", request.param("empty").?);
    try std.testing.expect(request.param("flag") == null);
    try std.testing.expect(request.param("missing") == null);
    // A parameter name must match whole, not as a prefix.
    try std.testing.expect(request.param("station") == null);

    const without_query: RequestContext = .{ .allocator = std.testing.allocator, .method = .GET, .path = "/api/ping", .query = null, .headers = &.{}, .body = null };
    try std.testing.expect(without_query.param("station_id") == null);
}
