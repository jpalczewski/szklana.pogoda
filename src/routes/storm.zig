//! `/api/storm/*` handlers: the city table and one city's Antistorm reading.
//!
//! Both routes are reads. They never store anything, because Antistorm
//! recomputes its probabilities every fifteen minutes and the client already
//! holds the newest reading of each city for its configured TTL.

const std = @import("std");
const router = @import("../router.zig");
const antistorm = @import("../antistorm/mod.zig");

/// The whole response for one city: the reading plus the coordinates from the
/// embedded table, which a map view needs and the Antistorm payload does not
/// publish.
const StormPayload = struct {
    city_id: u16,
    city_name: []const u8,
    latitude: f64,
    longitude: f64,
    storm_probability: u8,
    storm_minutes: u8,
    storm_alarm: bool,
    rain_probability: u8,
    rain_minutes: u8,
    rain_alarm: bool,
    active_storm: u8,
    fetched_age_seconds: u64,
};

const StormResponse = struct {
    storm: StormPayload,
};

/// One entry of the city table. Only the fields a client needs to offer the
/// city: the id it passes back and the name it shows.
const CityPayload = struct {
    city_id: u16,
    city_name: []const u8,
    latitude: f64,
    longitude: f64,
};

const CitiesResponse = struct {
    count: usize,
    cities: []const CityPayload,
};

/// `GET /api/storm/cities` lists the embedded city table, optionally narrowed
/// with `?q=`, which matches anywhere in the name after the same case and
/// diacritic folding the lookup uses.
pub fn cities(_: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const filter = request.param("q") orelse request.param("query") orelse "";
    var needle_buffer: [antistorm.cities.max_name_bytes]u8 = undefined;
    const needle = foldFilter(filter, &needle_buffer);

    var matches: std.ArrayList(CityPayload) = .empty;
    defer matches.deinit(request.allocator);
    for (antistorm.cities.all, 0..) |entry, index| {
        var candidate: [antistorm.cities.max_name_bytes]u8 = undefined;
        const name = antistorm.cities.fold(entry.name, &candidate);
        if (needle.len != 0 and std.mem.indexOf(u8, name, needle) == null) continue;
        try matches.append(request.allocator, .{
            .city_id = @intCast(index),
            .city_name = entry.name,
            .latitude = entry.latitude,
            .longitude = entry.longitude,
        });
    }

    return router.Response.jsonValue(request.allocator, .ok, CitiesResponse{
        .count = matches.items.len,
        .cities = matches.items,
    });
}

/// `GET /api/storm/city?city=<name>` (or `?id=<id>`) answers one city's newest
/// reading. The selector is the same one the client resolves; an unknown city
/// is a 404 and an unreachable Antistorm is a 502.
pub fn city(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const client = app.storm orelse return error.StormUnavailable;

    const selector = request.param("city") orelse request.param("id") orelse return error.BadRequest;
    if (selector.len == 0) return error.BadRequest;

    var reading = client.get(selector) catch |err| switch (err) {
        error.UnknownCity => return error.UnknownCity,
        else => {
            std.log.warn("storm reading for \"{s}\" failed: {t}", .{ selector, err });
            return error.StormUnavailable;
        },
    };
    defer reading.deinit(request.allocator);

    return router.Response.jsonValue(request.allocator, .ok, StormResponse{
        .storm = .{
            .city_id = reading.city_id,
            .city_name = reading.city_name,
            .latitude = reading.latitude,
            .longitude = reading.longitude,
            .storm_probability = reading.storm_probability,
            .storm_minutes = reading.storm_minutes,
            .storm_alarm = reading.storm_alarm,
            .rain_probability = reading.rain_probability,
            .rain_minutes = reading.rain_minutes,
            .rain_alarm = reading.rain_alarm,
            .active_storm = reading.active_storm,
            .fetched_age_seconds = reading.fetched_age_seconds,
        },
    });
}

/// The fold buffer for `?q=`. A filter longer than the longest city name cannot
/// match anything, so it is truncated; the result then simply has no matches.
fn foldFilter(filter: []const u8, buffer: *[antistorm.cities.max_name_bytes]u8) []const u8 {
    const wanted = std.mem.trim(u8, filter, " \t");
    return antistorm.cities.fold(wanted, buffer);
}

test "cities lists the whole table when no filter is given" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/storm/cities",
        .query = null,
        .headers = &.{},
        .body = null,
    };

    const response = try cities(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);

    var parsed = try std.json.parseFromSlice(CitiesResponse, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, antistorm.cities.count), parsed.value.count);

    // The first entry is the id the webservice expects for it.
    try std.testing.expectEqual(@as(u16, 0), parsed.value.cities[0].city_id);
    try std.testing.expectEqualStrings("Aleksandrów Kujawski", parsed.value.cities[0].city_name);
}

test "cities folds the filter" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/storm/cities",
        .query = "q=gorzow",
        .headers = &.{},
        .body = null,
    };

    const response = try cities(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);

    var parsed = try std.json.parseFromSlice(CitiesResponse, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.count);
    try std.testing.expectEqual(@as(u16, 87), parsed.value.cities[0].city_id);
    try std.testing.expectEqualStrings("Gorzów Wielkopolski", parsed.value.cities[0].city_name);
}

test "cities answers an empty list when nothing matches" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/storm/cities",
        .query = "q=zzzz",
        .headers = &.{},
        .body = null,
    };

    const response = try cities(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("{\"count\":0,\"cities\":[]}", response.body);
}

/// A client whose reading is fixed, so the route contract can be asserted
/// without a network or a clock.
fn fixtureClient() antistorm.Client {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .ttl_seconds = 300,
        .fetch = &fetchFixture,
    };
}

fn fetchFixture(allocator: std.mem.Allocator, io: std.Io, _: []const u8) antistorm.Error![]u8 {
    _ = io;
    return allocator.dupe(u8, "{\"m\": \"Zakopane\", \"p_b\": 20, \"t_b\": 30, \"a_b\": 1, \"p_o\": 120, \"t_o\": 32, \"a_o\": 1, \"s\": 0}");
}

test "city returns one reading as JSON" {
    var client = fixtureClient();
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .storm = &client, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/storm/city",
        .query = "city=zakopane",
        .headers = &.{},
        .body = null,
    };

    const response = try city(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqualStrings(
        "{\"storm\":{\"city_id\":416,\"city_name\":\"Zakopane\",\"latitude\":49.289,\"longitude\":19.959," ++
            "\"storm_probability\":20,\"storm_minutes\":30,\"storm_alarm\":true,\"rain_probability\":120," ++
            "\"rain_minutes\":32,\"rain_alarm\":true,\"active_storm\":0,\"fetched_age_seconds\":0}}",
        response.body,
    );
}

test "city accepts the numeric id as the selector" {
    var client = fixtureClient();
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .storm = &client, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/storm/city",
        .query = "id=416",
        .headers = &.{},
        .body = null,
    };

    const response = try city(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expect(std.mem.startsWith(u8, response.body, "{\"storm\":{\"city_id\":416,"));
}

test "city asks for a city that exists" {
    var client = fixtureClient();
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .storm = &client, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/storm/city",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.BadRequest, city(&app, &request));

    request.query = "city=";
    try std.testing.expectError(error.BadRequest, city(&app, &request));

    request.query = "city=Nieistniejace";
    try std.testing.expectError(error.UnknownCity, city(&app, &request));
}

test "city reports an unreachable Antistorm" {
    var client = fixtureClient();
    client.fetch = &fetchUnavailable;
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .storm = &client, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/storm/city",
        .query = "city=Zakopane",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.StormUnavailable, city(&app, &request));
}

fn fetchUnavailable(_: std.mem.Allocator, _: std.Io, _: []const u8) antistorm.Error![]u8 {
    return error.NetworkUnavailable;
}

test "city needs a storm client" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/storm/city",
        .query = "city=Zakopane",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.StormUnavailable, city(&app, &request));
}

test "the storm routes answer with JSON and only allow GET" {
    const routes = [_]router.Route{
        .{ .method = .GET, .path = "/api/storm/cities", .handler = cities },
        .{ .method = .GET, .path = "/api/storm/city", .handler = city },
    };
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .POST,
        .path = "/api/storm/city",
        .query = "city=Zakopane",
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
