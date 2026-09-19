//! `GET /api/forecast`: Open-Meteo's current conditions, daily summary and
//! next 24 hours for one location.
//!
//! The location is either `?lat=&lon=` or `?city=<name>`, resolved through
//! Antistorm's city table the same way `routes/storm.zig` resolves a
//! selector. That coupling lives here, not in `openmeteo/client.zig`, which
//! stays a pure coordinate-only client.

const std = @import("std");
const router = @import("../router.zig");
const antistorm = @import("../antistorm/mod.zig");
const openmeteo = @import("../openmeteo/mod.zig");

const ForecastResponse = struct {
    forecast: openmeteo.Forecast,
};

const Coordinates = struct {
    latitude: f64,
    longitude: f64,
};

pub fn forecast(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const client = app.forecast orelse return error.ForecastUnavailable;
    const coordinates = try resolveCoordinates(request);

    var result = client.get(request.allocator, coordinates.latitude, coordinates.longitude) catch |err| switch (err) {
        error.InvalidCoordinates => return error.BadRequest,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidData, error.NetworkUnavailable => {
            std.log.warn("forecast for ({d},{d}) failed: {t}", .{ coordinates.latitude, coordinates.longitude, err });
            return error.ForecastUnavailable;
        },
    };
    defer result.deinit(request.allocator);

    return router.Response.jsonValue(request.allocator, .ok, ForecastResponse{ .forecast = result });
}

/// `?city=` takes precedence when both are given, since a person is more
/// likely to have edited the coordinates by hand than to have left a stray
/// city name in place.
fn resolveCoordinates(request: *router.RequestContext) router.AppError!Coordinates {
    if (request.param("city")) |name| {
        if (name.len == 0) return error.BadRequest;
        const found = antistorm.cities.find(name) orelse return error.UnknownCity;
        return .{ .latitude = found.city.latitude, .longitude = found.city.longitude };
    }

    const lat = request.param("lat") orelse request.param("latitude") orelse return error.BadRequest;
    const lon = request.param("lon") orelse request.param("longitude") orelse return error.BadRequest;
    return .{
        .latitude = std.fmt.parseFloat(f64, lat) catch return error.BadRequest,
        .longitude = std.fmt.parseFloat(f64, lon) catch return error.BadRequest,
    };
}

fn fixtureClient() openmeteo.Client {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .ttl_seconds = 900,
        .fetch = &fetchFixture,
    };
}

const fixture_body =
    \\{"latitude":52.25,"longitude":21.0,"current":{"time":"2026-09-18T14:00","temperature_2m":18.4,"apparent_temperature":17.9,"relative_humidity_2m":63,"precipitation":0.0,"weather_code":3,"wind_speed_10m":11.2,"wind_direction_10m":240},"daily":{"time":["2026-09-18"],"weather_code":[3],"temperature_2m_max":[19.5],"temperature_2m_min":[10.1],"precipitation_sum":[0.0],"precipitation_probability_max":[10],"sunrise":["2026-09-18T06:15"],"sunset":["2026-09-18T19:02"]},"hourly":{"time":["2026-09-18T14:00"],"temperature_2m":[18.4],"precipitation_probability":[10],"precipitation":[0.0],"weather_code":[3],"wind_speed_10m":[11.2],"wind_direction_10m":[240]}}
;

fn fetchFixture(allocator: std.mem.Allocator, io: std.Io, _: []const u8) openmeteo.Error![]u8 {
    _ = io;
    return allocator.dupe(u8, fixture_body);
}

fn fetchUnavailable(_: std.mem.Allocator, _: std.Io, _: []const u8) openmeteo.Error![]u8 {
    return error.NetworkUnavailable;
}

test "forecast answers one location as JSON" {
    var client = fixtureClient();
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/forecast",
        .query = "lat=52.2297&lon=21.0122",
        .headers = &.{},
        .body = null,
    };

    const response = try forecast(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expect(std.mem.startsWith(u8, response.body, "{\"forecast\":{\"latitude\":52.25,\"longitude\":21"));
    try std.testing.expect(std.mem.find(u8, response.body, "\"hourly\":[{\"time\":\"2026-09-18T14:00\",\"temperature_c\":18.4,\"precipitation_chance_percent\":10") != null);
}

test "forecast resolves a city name through the Antistorm table" {
    var client = fixtureClient();
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/forecast",
        .query = "city=zakopane",
        .headers = &.{},
        .body = null,
    };

    const response = try forecast(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);

    request.query = "city=Nieistniejace";
    try std.testing.expectError(error.UnknownCity, forecast(&app, &request));

    request.query = "city=";
    try std.testing.expectError(error.BadRequest, forecast(&app, &request));
}

test "forecast requires both coordinates or a city" {
    var client = fixtureClient();
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/forecast",
        .query = "lat=52.2297",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.BadRequest, forecast(&app, &request));

    request.query = null;
    try std.testing.expectError(error.BadRequest, forecast(&app, &request));
}

test "forecast rejects an out of range coordinate" {
    var client = fixtureClient();
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/forecast",
        .query = "lat=95&lon=21",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.BadRequest, forecast(&app, &request));
}

test "forecast reports an unreachable Open-Meteo" {
    var client = fixtureClient();
    client.fetch = &fetchUnavailable;
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/forecast",
        .query = "lat=52.2297&lon=21.0122",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.ForecastUnavailable, forecast(&app, &request));
}

test "forecast needs a client" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/forecast",
        .query = "lat=52.2297&lon=21.0122",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.ForecastUnavailable, forecast(&app, &request));
}

test "the forecast route answers with JSON and only allows GET" {
    const routes = [_]router.Route{
        .{ .method = .GET, .path = "/api/forecast", .handler = forecast },
    };
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .POST,
        .path = "/api/forecast",
        .query = "lat=52.2297&lon=21.0122",
        .headers = &.{},
        .body = null,
    };

    const response = try router.dispatch(&routes, &app, &request);
    defer std.testing.allocator.free(response.body);
    defer std.testing.allocator.free(response.allow.?);
    try std.testing.expectEqual(.method_not_allowed, response.status);
    try std.testing.expectEqualStrings("GET", response.allow.?);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", response.content_type);
}
