const std = @import("std");
const router = @import("../router.zig");
const process_memory = @import("../process_memory.zig");
const weather_store = @import("../weather_store.zig");

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

pub fn weatherHistory(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const store = app.weather_store orelse return error.WeatherStoreUnavailable;
    const station_id = queryValue(request.query, "station_id") orelse return error.BadRequest;
    if (station_id.len == 0) return error.BadRequest;
    const since = queryValue(request.query, "since") orelse "";

    const observations = store.history(request.allocator, station_id, since) catch |err| {
        std.log.err("weather history unavailable: {t}", .{err});
        return error.WeatherStoreUnavailable;
    };
    defer weather_store.Store.deinitHistory(request.allocator, observations);
    return router.Response.jsonValue(request.allocator, .ok, .{
        .station_id = station_id,
        .observations = observations,
    });
}

pub fn weatherStations(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const store = app.weather_store orelse return error.WeatherStoreUnavailable;
    const stations = store.stations(request.allocator) catch |err| {
        std.log.err("weather stations unavailable: {t}", .{err});
        return error.WeatherStoreUnavailable;
    };
    defer weather_store.Store.deinitStations(request.allocator, stations);
    return router.Response.jsonValue(request.allocator, .ok, .{ .stations = stations });
}

pub fn hydroStations(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const store = app.weather_store orelse return error.WeatherStoreUnavailable;
    const stations = store.hydroStations(request.allocator) catch |err| {
        std.log.err("hydro stations unavailable: {t}", .{err});
        return error.WeatherStoreUnavailable;
    };
    defer weather_store.Store.deinitHydro(request.allocator, stations);
    return router.Response.jsonValue(request.allocator, .ok, .{ .stations = stations });
}

pub fn hydroHistory(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const store = app.weather_store orelse return error.WeatherStoreUnavailable;
    const station_id = queryValue(request.query, "station_id") orelse return error.BadRequest;
    if (station_id.len == 0) return error.BadRequest;
    const since = queryValue(request.query, "since") orelse "";
    const observations = store.hydroHistory(request.allocator, station_id, since) catch |err| {
        std.log.err("hydro history unavailable: {t}", .{err});
        return error.WeatherStoreUnavailable;
    };
    defer weather_store.Store.deinitHydro(request.allocator, observations);
    return router.Response.jsonValue(request.allocator, .ok, .{ .station_id = station_id, .observations = observations });
}

fn queryValue(query: ?[]const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query orelse return null, '&');
    while (pairs.next()) |pair| {
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..separator], name)) return pair[separator + 1 ..];
    }
    return null;
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

test "weather history returns observations for one station" {
    var store = try weather_store.Store.initMemory();
    defer store.deinit();
    try store.record(.{
        .station_id = "12424",
        .station_name = "Wrocław",
        .observed_at = "2026-09-16T17:00:00Z",
        .temperature_c = 18.5,
        .wind_speed_m_s = null,
        .wind_direction_deg = null,
        .relative_humidity_percent = 71.5,
        .precipitation_mm = 0,
        .pressure_hpa = 1012.4,
    });
    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/weather/history",
        .query = "station_id=12424&since=2026-09-16T00:00:00Z",
        .headers = &.{},
        .body = null,
    };

    const response = try weatherHistory(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqualStrings(
        "{\"station_id\":\"12424\",\"observations\":[{\"station_id\":\"12424\",\"station_name\":\"Wrocław\",\"observed_at\":\"2026-09-16T17:00:00Z\",\"temperature_c\":18.5,\"wind_speed_m_s\":null,\"wind_direction_deg\":null,\"relative_humidity_percent\":71.5,\"precipitation_mm\":0,\"pressure_hpa\":1012.4}]}",
        response.body,
    );
}

test "weather history requires a station ID" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/weather/history",
        .query = "since=2026-09-16T00:00:00Z",
        .headers = &.{},
        .body = null,
    };

    try std.testing.expectError(error.BadRequest, weatherHistory(&app, &request));
}

test "hydro history requires a station ID" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/hydro/history",
        .query = "since=2026-09-16 00:00:00",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.BadRequest, hydroHistory(&app, &request));
}

test "weather stations returns city to station mapping" {
    var store = try weather_store.Store.initMemory();
    defer store.deinit();
    try store.record(.{
        .station_id = "12424",
        .station_name = "Wrocław",
        .observed_at = "2026-09-16T17:00:00Z",
        .temperature_c = null,
        .wind_speed_m_s = null,
        .wind_direction_deg = null,
        .relative_humidity_percent = null,
        .precipitation_mm = null,
        .pressure_hpa = null,
    });
    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/weather/stations",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const response = try weatherStations(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings(
        "{\"stations\":[{\"station_id\":\"12424\",\"station_name\":\"Wrocław\",\"last_observed_at\":\"2026-09-16T17:00:00Z\"}]}",
        response.body,
    );
}
