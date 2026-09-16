const std = @import("std");
const Io = std.Io;
const net = Io.net;

const router = @import("router.zig");
const server = @import("server.zig");
const api = @import("routes/api.zig");
const pages = @import("routes/pages.zig");
const app_log = @import("app_log.zig");
const metrics = @import("metrics.zig");
const metrics_route = @import("routes/metrics.zig");
const weather_store = @import("weather_store.zig");
const imgw_client = @import("imgw_client.zig");
const imgw_warnings = @import("imgw_warnings.zig");
const warnings = @import("warnings.zig");
const weather_updater = @import("weather_updater.zig");

comptime {
    _ = imgw_client.parse;
    _ = imgw_client.parseMeteo;
    _ = imgw_client.fetch;
    _ = imgw_warnings.parseMeteo;
    _ = imgw_warnings.parseHydro;
    _ = imgw_warnings.fetchMeteo;
    _ = warnings.localNow;
    _ = warnings.warsawOffsetSeconds;
    _ = weather_updater.run;
    _ = weather_updater.runWarnings;
}

pub const std_options: std.Options = .{
    .logFn = app_log.logFn,
};

const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    metrics_port: u16 = 9090,
    max_body_bytes: usize = 16 * 1024,
    max_connections_per_cpu: usize = 4,
    trust_proxy: bool = false,
    database_path: []const u8 = "weather.db",
    imgw_interval_seconds: u64 = 10 * 60,
    imgw_warnings_interval_seconds: u64 = 5 * 60,

    // The host borrows storage from environ, which must outlive this config.
    fn from_env(environ: *const std.process.Environ.Map) !Config {
        const defaults: Config = .{};
        const config: Config = .{
            .host = environ.get("HOST") orelse defaults.host,
            .port = try envInt(u16, environ, "PORT", defaults.port),
            .metrics_port = try envInt(u16, environ, "METRICS_PORT", defaults.metrics_port),
            .max_body_bytes = try envInt(usize, environ, "MAX_BODY_BYTES", defaults.max_body_bytes),
            .max_connections_per_cpu = try envInt(usize, environ, "MAX_CONNECTIONS_PER_CPU", defaults.max_connections_per_cpu),
            .trust_proxy = try envBool(environ, "TRUST_PROXY", defaults.trust_proxy),
            .database_path = environ.get("DATABASE_PATH") orelse defaults.database_path,
            .imgw_interval_seconds = try envInt(u64, environ, "IMGW_INTERVAL_SECONDS", defaults.imgw_interval_seconds),
            .imgw_warnings_interval_seconds = try envInt(u64, environ, "IMGW_WARNINGS_INTERVAL_SECONDS", defaults.imgw_warnings_interval_seconds),
        };
        try config.validate();
        return config;
    }

    fn validate(self: Config) !void {
        if (self.max_connections_per_cpu == 0) return error.InvalidMaxConnectionsPerCpu;
        if (self.imgw_interval_seconds == 0) return error.InvalidImgwInterval;
        if (self.imgw_warnings_interval_seconds == 0) return error.InvalidImgwWarningsInterval;
    }

    fn concurrent_limit(self: Config, cpu_count: usize) !usize {
        try self.validate();
        const connections = try std.math.mul(usize, cpu_count, self.max_connections_per_cpu);
        // Reserve one task for each listener.
        return std.math.add(usize, connections, 2);
    }
};

const routes = [_]router.Route{
    .{ .method = .GET, .path = "/", .handler = pages.home },
    .{ .method = .GET, .path = "/en/", .handler = pages.home_en },
    .{ .method = .GET, .path = "/98.css", .handler = pages.style },
    .{ .method = .GET, .path = "/app.css", .handler = pages.app_style },
    .{ .method = .GET, .path = "/app.js", .handler = pages.app_script },
    .{ .method = .GET, .path = "/alpine.js", .handler = pages.alpine_script },
    .{ .method = .POST, .path = "/api/ping", .handler = api.ping },
    .{ .method = .GET, .path = "/api/memory", .handler = api.memory },
    .{ .method = .GET, .path = "/api/weather/history", .handler = api.weatherHistory },
    .{ .method = .GET, .path = "/api/weather/stations", .handler = api.weatherStations },
    .{ .method = .GET, .path = "/api/weather/meteo/history", .handler = api.weatherHistory },
    .{ .method = .GET, .path = "/api/weather/meteo/stations", .handler = api.weatherStations },
    .{ .method = .GET, .path = "/api/hydro/stations", .handler = api.hydroStations },
    .{ .method = .GET, .path = "/api/hydro/history", .handler = api.hydroHistory },
    .{ .method = .GET, .path = "/api/warnings", .handler = api.warningsActive },
    .{ .method = .GET, .path = "/api/warnings/history", .handler = api.warningsHistory },
    .{ .method = .GET, .path = "/api/warnings/revisions", .handler = api.warningsRevisions },
};

const metrics_routes = [_]router.Route{
    .{ .method = .GET, .path = "/metrics", .handler = metrics_route.metrics },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const config = try Config.from_env(init.environ_map);
    const database_path = try gpa.dupeZ(u8, config.database_path);
    defer gpa.free(database_path);
    var observations = try weather_store.Store.initFile(database_path);
    defer observations.deinit();

    const cpu_count = std.Thread.getCpuCount() catch 1;
    var threaded: Io.Threaded = .init(gpa, .{
        .concurrent_limit = .limited(try config.concurrent_limit(cpu_count)),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var address = try net.IpAddress.parseIp4(config.host, config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var metrics_address = try net.IpAddress.parseIp4(config.host, config.metrics_port);
    var metrics_listener = try metrics_address.listen(io, .{ .reuse_address = true });
    defer metrics_listener.deinit(io);

    var metrics_registry = metrics.Registry.init(gpa);
    defer metrics_registry.deinit();
    var app: router.App = .{ .max_body_bytes = config.max_body_bytes, .trust_proxy = config.trust_proxy, .metrics = &metrics_registry, .weather_store = &observations, .io = io };
    var metrics_app: router.App = .{ .max_body_bytes = config.max_body_bytes, .trust_proxy = config.trust_proxy, .metrics = &metrics_registry };
    var connections: Io.Group = .init;
    defer connections.await(io) catch {};
    var listeners: Io.Group = .init;
    defer listeners.await(io) catch {};

    const app_listener_config: server.ListenerConfig = .{
        .name = "application",
        .listener = &listener,
        .app = &app,
        .routes = &routes,
        .instrument_requests = true,
    };
    const metrics_listener_config: server.ListenerConfig = .{
        .name = "metrics",
        .listener = &metrics_listener,
        .app = &metrics_app,
        .routes = &metrics_routes,
        .instrument_requests = false,
    };

    std.log.info("szklana.pogoda listening on {s}:{d}", .{ config.host, config.port });
    std.log.info("metrics listening on {s}:{d}", .{ config.host, config.metrics_port });

    try listeners.concurrent(io, server.serve, .{ gpa, io, &app_listener_config, &connections });
    try listeners.concurrent(io, server.serve, .{ gpa, io, &metrics_listener_config, &connections });
    try connections.concurrent(io, weather_updater.run, .{ gpa, io, &observations, weather_updater.default_url, config.imgw_interval_seconds });
    try connections.concurrent(io, weather_updater.runWarnings, .{ gpa, io, &observations, config.imgw_warnings_interval_seconds });
    try listeners.await(io);
}

fn envInt(comptime T: type, environ: *const std.process.Environ.Map, name: []const u8, default: T) !T {
    const raw = environ.get(name) orelse return default;
    return std.fmt.parseInt(T, raw, 10) catch |err| {
        std.log.err("invalid {s}=\"{s}\": {t}", .{ name, raw, err });
        return err;
    };
}

fn envBool(environ: *const std.process.Environ.Map, name: []const u8, default: bool) !bool {
    const raw = environ.get(name) orelse return default;
    if (std.ascii.eqlIgnoreCase(raw, "true")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    std.log.err("invalid {s}=\"{s}\": expected true or false", .{ name, raw });
    return error.InvalidBoolean;
}

test "config uses defaults for an empty environment" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    const config = try Config.from_env(&environ);
    try std.testing.expectEqualDeep(Config{}, config);
    try std.testing.expectEqual(@as(usize, 10), try config.concurrent_limit(2));
}

test "config reads environment overrides" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOST", "127.0.0.1");
    try environ.put("PORT", "18080");
    try environ.put("METRICS_PORT", "19090");
    try environ.put("MAX_BODY_BYTES", "2048");
    try environ.put("MAX_CONNECTIONS_PER_CPU", "8");
    try environ.put("TRUST_PROXY", "TrUe");
    try environ.put("DATABASE_PATH", "var/weather.db");
    try environ.put("IMGW_WARNINGS_INTERVAL_SECONDS", "120");

    const config = try Config.from_env(&environ);
    try std.testing.expectEqualDeep(Config{
        .host = "127.0.0.1",
        .port = 18080,
        .metrics_port = 19090,
        .max_body_bytes = 2048,
        .max_connections_per_cpu = 8,
        .trust_proxy = true,
        .database_path = "var/weather.db",
        .imgw_warnings_interval_seconds = 120,
    }, config);
    try std.testing.expectEqual(@as(usize, 26), try config.concurrent_limit(3));

    try environ.put("TRUST_PROXY", "FALSE");
    try std.testing.expect(!(try Config.from_env(&environ)).trust_proxy);
}

test "config rejects zero connections per CPU" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("MAX_CONNECTIONS_PER_CPU", "0");
    try std.testing.expectError(error.InvalidMaxConnectionsPerCpu, Config.from_env(&environ));
}

test "config rejects zero IMGW warnings interval" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("IMGW_WARNINGS_INTERVAL_SECONDS", "0");
    try std.testing.expectError(error.InvalidImgwWarningsInterval, Config.from_env(&environ));
}

test "config rejects zero IMGW interval" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("IMGW_INTERVAL_SECONDS", "0");
    try std.testing.expectError(error.InvalidImgwInterval, Config.from_env(&environ));
}

test "config detects multiplication and listener reservation overflow" {
    const config: Config = .{ .max_connections_per_cpu = std.math.maxInt(usize) };
    try std.testing.expectError(error.Overflow, config.concurrent_limit(2));
    try std.testing.expectError(error.Overflow, config.concurrent_limit(1));

    const largest_valid: Config = .{ .max_connections_per_cpu = std.math.maxInt(usize) - 2 };
    try std.testing.expectEqual(std.math.maxInt(usize), try largest_valid.concurrent_limit(1));
}
