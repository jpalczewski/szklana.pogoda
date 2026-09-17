const std = @import("std");
const router = @import("../router.zig");
const process_memory = @import("../process_memory.zig");
const timestamps = @import("../timestamps.zig");
const warnings = @import("../warnings.zig");
const weather = @import("../weather/mod.zig");

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

/// The stations endpoints answer with the newest reading per station; only the
/// store query, the optional product filter and the released fields differ.
fn stationsRoute(
    comptime T: type,
    comptime list: anytype,
    comptime deinitItems: fn (std.mem.Allocator, []T) void,
    comptime filter: fn (*router.RequestContext) router.AppError!?[]const u8,
    comptime what: []const u8,
) router.Handler {
    return struct {
        fn handle(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
            const store = app.weather_store orelse return error.WeatherStoreUnavailable;
            const source = try filter(request);
            const stations = list(store, request.allocator, source) catch |err| {
                std.log.err("{s} unavailable: {t}", .{ what, err });
                return error.WeatherStoreUnavailable;
            };
            defer deinitItems(request.allocator, stations);
            return router.Response.jsonValue(request.allocator, .ok, .{ .stations = stations });
        }
    }.handle;
}

/// The weather table holds both measurement products, so its stations endpoint
/// accepts an optional `?source=`; hydro has a single product and no filter.
fn observationSource(request: *router.RequestContext) router.AppError!?[]const u8 {
    const value = request.param("source") orelse return null;
    if (!weather.model.isObservationSource(value)) return error.BadRequest;
    return value;
}

fn noSource(_: *router.RequestContext) router.AppError!?[]const u8 {
    return null;
}

fn hydroStationsAll(store: *weather.Store, allocator: std.mem.Allocator, _: ?[]const u8) ![]weather.HydroStation {
    return store.hydroStations(allocator);
}

/// The history endpoints take a station id and an optional lower bound; only the
/// store query, the model type and the released fields differ.
fn historyRoute(
    comptime T: type,
    comptime list: anytype,
    comptime deinitItems: fn (std.mem.Allocator, []T) void,
    comptime what: []const u8,
) router.Handler {
    return struct {
        fn handle(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
            const store = app.weather_store orelse return error.WeatherStoreUnavailable;
            const station_id = request.param("station_id") orelse return error.BadRequest;
            if (station_id.len == 0) return error.BadRequest;
            const since = request.param("since") orelse "";

            const observations = list(store, request.allocator, station_id, since) catch |err| {
                std.log.err("{s} unavailable: {t}", .{ what, err });
                return error.WeatherStoreUnavailable;
            };
            defer deinitItems(request.allocator, observations);
            return router.Response.jsonValue(request.allocator, .ok, .{
                .station_id = station_id,
                .observations = observations,
            });
        }
    }.handle;
}

pub const weatherHistory = historyRoute(weather.Observation, weather.Store.history, weather.model.deinitObservations, "weather history");
pub const weatherStations = stationsRoute(weather.Station, weather.Store.stations, weather.model.deinitStations, observationSource, "weather stations");
pub const hydroStations = stationsRoute(weather.HydroStation, hydroStationsAll, weather.model.deinitHydro, noSource, "hydro stations");
pub const hydroHistory = historyRoute(weather.HydroObservation, weather.Store.hydroHistory, weather.model.deinitHydro, "hydro history");

const WarningQuery = struct {
    warning_id: ?[]const u8 = null,
    source: ?weather.WarningSource = null,
    teryt: ?[]const u8 = null,
    since: ?[]const u8 = null,
};

/// Every warning endpoint shares the same query contract: an optional source,
/// an optional county code and, for history, an optional lower bound.
fn warningQuery(request: *router.RequestContext) router.AppError!WarningQuery {
    var query: WarningQuery = .{};
    if (request.param("id")) |value| {
        if (value.len == 0) return error.BadRequest;
        query.warning_id = value;
    }
    if (request.param("source")) |value| {
        query.source = weather.WarningSource.fromQuery(value) orelse return error.BadRequest;
    }
    if (request.param("teryt")) |value| {
        if (!isTeryt(value)) return error.BadRequest;
        query.teryt = value;
    }
    if (request.param("since")) |value| {
        if (value.len == 0) return error.BadRequest;
        query.since = value;
    }
    return query;
}

fn isTeryt(value: []const u8) bool {
    if (value.len != 4) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn currentLocalTime(app: *router.App, allocator: std.mem.Allocator) router.AppError![]u8 {
    const io = app.io orelse return error.WeatherStoreUnavailable;
    return timestamps.clock().localNow(allocator, io) catch |err| {
        std.log.err("reading the wall clock failed: {t}", .{err});
        return error.WeatherStoreUnavailable;
    };
}

/// Warnings IMGW still lists as valid: the newest revision of each one.
pub fn warningsActive(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const store = app.weather_store orelse return error.WeatherStoreUnavailable;
    const query = try warningQuery(request);
    const now = try currentLocalTime(app, request.allocator);
    defer request.allocator.free(now);

    const items = store.activeWarnings(request.allocator, .{
        .warning_id = query.warning_id,
        .source = query.source,
        .teryt = query.teryt,
        .effective_to_gte = now,
        .latest_only = true,
    }) catch |err| {
        std.log.err("warning query failed: {t}", .{err});
        return error.WeatherStoreUnavailable;
    };
    defer warnings.deinitWarnings(request.allocator, items);
    return router.Response.jsonValue(request.allocator, .ok, .{ .warnings = items });
}

/// Every stored revision, expired warnings included.
pub fn warningsHistory(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const store = app.weather_store orelse return error.WeatherStoreUnavailable;
    const query = try warningQuery(request);

    const items = store.warningHistory(request.allocator, .{
        .warning_id = query.warning_id,
        .source = query.source,
        .teryt = query.teryt,
        .effective_to_gte = query.since,
    }) catch |err| {
        std.log.err("warning history unavailable: {t}", .{err});
        return error.WeatherStoreUnavailable;
    };
    defer warnings.deinitWarnings(request.allocator, items);
    return router.Response.jsonValue(request.allocator, .ok, .{ .warnings = items });
}

/// The revision chain of a single warning.
pub fn warningsRevisions(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    const store = app.weather_store orelse return error.WeatherStoreUnavailable;
    const query = try warningQuery(request);
    const source = query.source orelse return error.BadRequest;
    const warning_id = query.warning_id orelse return error.BadRequest;

    const items = store.warningRevisions(request.allocator, source, warning_id) catch |err| {
        std.log.err("warning revisions unavailable: {t}", .{err});
        return error.WeatherStoreUnavailable;
    };
    defer warnings.deinitWarnings(request.allocator, items);
    return router.Response.jsonValue(request.allocator, .ok, .{
        .source = source,
        .warning_id = warning_id,
        .revisions = items,
    });
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
    try std.testing.expect(std.mem.find(u8, response.body, ",\"virtual_memory_bytes\":") != null);
    try std.testing.expect(std.mem.find(u8, response.body, ",\"own_bytes\":") != null);
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
    defer std.testing.allocator.free(response.body);
    defer std.testing.allocator.free(response.allow.?);
    try std.testing.expectEqual(.method_not_allowed, response.status);
    try std.testing.expectEqualStrings("GET", response.allow.?);
}

test "weather history returns observations for one station" {
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    try store.record("synop", .{
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
        "{\"station_id\":\"12424\",\"observations\":[{\"station_id\":\"12424\",\"station_name\":\"Wrocław\",\"observed_at\":\"2026-09-16T17:00:00Z\",\"temperature_c\":18.5,\"wind_speed_m_s\":null,\"wind_direction_deg\":null,\"relative_humidity_percent\":71.5,\"precipitation_mm\":0,\"pressure_hpa\":1012.4,\"longitude\":null,\"latitude\":null}]}",
        response.body,
    );
}

test "weather history requires a station ID" {
    // A handler reaches the query check only once it has a store, so the test
    // provides an empty one.
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store };
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
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store };
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
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    try store.record("synop", .{
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
        "{\"stations\":[{\"station_id\":\"12424\",\"station_name\":\"Wrocław\",\"last_observed_at\":\"2026-09-16T17:00:00Z\",\"longitude\":null,\"latitude\":null}]}",
        response.body,
    );
}

test "weather stations filter by measurement product" {
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    try store.record("synop", .{
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
    try store.record("meteo", .{
        .station_id = "249180010",
        .station_name = "PSZCZYNA",
        .observed_at = "2026-09-16T17:10:00Z",
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
        .query = "source=synop",
        .headers = &.{},
        .body = null,
    };

    const synoptic = try weatherStations(&app, &request);
    defer std.testing.allocator.free(synoptic.body);
    try std.testing.expectEqualStrings(
        "{\"stations\":[{\"station_id\":\"12424\",\"station_name\":\"Wrocław\",\"last_observed_at\":\"2026-09-16T17:00:00Z\",\"longitude\":null,\"latitude\":null}]}",
        synoptic.body,
    );

    request.query = "source=meteo";
    const meteo = try weatherStations(&app, &request);
    defer std.testing.allocator.free(meteo.body);
    try std.testing.expectEqualStrings(
        "{\"stations\":[{\"station_id\":\"249180010\",\"station_name\":\"PSZCZYNA\",\"last_observed_at\":\"2026-09-16T17:10:00Z\",\"longitude\":null,\"latitude\":null}]}",
        meteo.body,
    );
}

test "weather stations reject an unknown measurement product" {
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/weather/stations",
        .query = "source=hydro",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.BadRequest, weatherStations(&app, &request));

    request.query = "source=";
    try std.testing.expectError(error.BadRequest, weatherStations(&app, &request));

    // Hydro ignores the parameter's meaning but still has to answer.
    request.path = "/api/hydro/stations";
    request.query = null;
    const response = try hydroStations(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
}

test "weather stations report the position the meteo product publishes" {
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    try store.record("meteo", .{
        .station_id = "249180010",
        .station_name = "PSZCZYNA",
        .observed_at = "2026-09-16T17:10:00Z",
        .temperature_c = 17.5,
        .wind_speed_m_s = null,
        .wind_direction_deg = null,
        .relative_humidity_percent = null,
        .precipitation_mm = null,
        .pressure_hpa = null,
        .longitude = 18.9306,
        .latitude = 49.9342,
    });
    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/weather/stations",
        .query = "source=meteo",
        .headers = &.{},
        .body = null,
    };

    const response = try weatherStations(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqualStrings(
        "{\"stations\":[{\"station_id\":\"249180010\",\"station_name\":\"PSZCZYNA\",\"last_observed_at\":\"2026-09-16T17:10:00Z\",\"longitude\":18.9306,\"latitude\":49.9342}]}",
        response.body,
    );
}

fn warningFixture() weather.Warning {
    return .{
        .source = .meteo,
        .warning_id = "Sk1",
        .event = "Silny wiatr",
        .severity = 2,
        .probability_percent = 70,
        .office = "CBPM",
        .published_at = "2026-09-16 11:43:00",
        .effective_from = "2026-09-16 23:00:00",
        .effective_to = "9999-12-31 23:59:59",
        .content = "Silny wiatr.",
        .areas = &.{.{ .teryt = "2415" }},
    };
}

test "warnings endpoint returns the active set as JSON" {
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    _ = try store.recordWarnings(&.{warningFixture()}, "2026-09-16 23:05:00");

    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/warnings",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const response = try warningsActive(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqualStrings(
        "{\"warnings\":[{\"source\":\"meteo\",\"warning_id\":\"Sk1\",\"revision\":1," ++
            "\"event\":\"Silny wiatr\",\"severity\":2,\"probability_percent\":70,\"office\":\"CBPM\"," ++
            "\"published_at\":\"2026-09-16 11:43:00\",\"effective_from\":\"2026-09-16 23:00:00\"," ++
            "\"effective_to\":\"9999-12-31 23:59:59\",\"content\":\"Silny wiatr.\",\"comment\":null," ++
            "\"first_seen_at\":\"2026-09-16 23:05:00\",\"last_seen_at\":\"2026-09-16 23:05:00\"," ++
            "\"areas\":[{\"teryt\":\"2415\",\"voivodeship\":null,\"description\":null,\"basin_code\":null}]}]}",
        response.body,
    );
}

test "warnings endpoint filters by TERYT and reports an empty result" {
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    _ = try store.recordWarnings(&.{warningFixture()}, "2026-09-16 23:05:00");

    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/warnings",
        .query = "teryt=9999",
        .headers = &.{},
        .body = null,
    };
    const response = try warningsActive(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqualStrings("{\"warnings\":[]}", response.body);
}

test "warnings endpoint rejects malformed query values" {
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/warnings",
        .query = "source=meteorologiczne",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.BadRequest, warningsActive(&app, &request));

    request.query = "teryt=24";
    try std.testing.expectError(error.BadRequest, warningsActive(&app, &request));

    request.query = "teryt=24a5";
    try std.testing.expectError(error.BadRequest, warningsActive(&app, &request));

    request.query = "since=";
    try std.testing.expectError(error.BadRequest, warningsHistory(&app, &request));
}

test "warnings revisions require a source and an identifier" {
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    _ = try store.recordWarnings(&.{warningFixture()}, "2026-09-16 23:05:00");

    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/warnings/revisions",
        .query = "source=meteo",
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.BadRequest, warningsRevisions(&app, &request));

    request.query = "id=Sk1";
    try std.testing.expectError(error.BadRequest, warningsRevisions(&app, &request));

    request.query = "source=meteo&id=Sk1";
    const response = try warningsRevisions(&app, &request);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expect(std.mem.startsWith(u8, response.body, "{\"source\":\"meteo\",\"warning_id\":\"Sk1\",\"revisions\":["));
}

test "warnings history keeps expired warnings" {
    var store = try weather.Store.initMemory(std.testing.allocator);
    defer store.deinit();
    var expired = warningFixture();
    expired.warning_id = "Sk0";
    expired.effective_to = "2020-01-01 00:00:00";
    _ = try store.recordWarnings(&.{expired}, "2020-01-01 00:05:00");

    var app: router.App = .{ .max_body_bytes = 16, .weather_store = &store, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/warnings",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    const active = try warningsActive(&app, &request);
    defer std.testing.allocator.free(active.body);
    try std.testing.expectEqualStrings("{\"warnings\":[]}", active.body);

    request.path = "/api/warnings/history";
    const history = try warningsHistory(&app, &request);
    defer std.testing.allocator.free(history.body);
    try std.testing.expect(std.mem.find(u8, history.body, "\"warning_id\":\"Sk0\"") != null);
}

test "warnings endpoint needs a store" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/warnings",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.WeatherStoreUnavailable, warningsActive(&app, &request));
}
