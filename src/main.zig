const std = @import("std");
const Io = std.Io;
const net = Io.net;

const router = @import("router.zig");
const server = @import("server.zig");
const api = @import("routes/api.zig");
const account_route = @import("routes/account.zig");
const favorites_route = @import("routes/favorites.zig");
const credentials_route = @import("routes/credentials.zig");
const accounts = @import("accounts/mod.zig");
const pages = @import("routes/pages.zig");
const storm = @import("routes/storm.zig");
const forecast_route = @import("routes/forecast.zig");
const app_log = @import("app_log.zig");
const metrics = @import("metrics/mod.zig");
const metrics_family = @import("metrics/family.zig");
const metrics_route = @import("routes/metrics.zig");
const health_route = @import("routes/health.zig");
const antistorm = @import("antistorm/mod.zig");
const openmeteo = @import("openmeteo/mod.zig");
const imgw = @import("imgw/mod.zig");
const weather = @import("weather/mod.zig");
const timestamps = @import("timestamps.zig");
const warnings = @import("warnings.zig");
const process_memory = @import("process_memory.zig");
const http_fetch = @import("http_fetch.zig");
const trusted_proxies = @import("trusted_proxies.zig");
const link_preview = @import("link_preview.zig");

/// Every module of the server, named once so the analysis below and the test
/// collection at the end of this file cannot drift apart.
const modules = .{
    app_log,
    metrics,
    metrics_family,
    process_memory,
    router,
    server,
    timestamps,
    warnings,
    api,
    pages,
    metrics_route,
    health_route,
    storm,
    forecast_route,
    antistorm,
    openmeteo,
    imgw,
    weather,
    http_fetch,
    trusted_proxies,
    link_preview,
    accounts,
    account_route,
    favorites_route,
    credentials_route,
};

/// Forces the semantic analyzer over every function of a module, so production
/// builds keep checking code that no call path reaches. Referencing a
/// declaration as a value is not enough for that; its address is.
fn analyzeDecls(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => analyzeDecls(@field(T, decl.name)),
                else => {},
            }
        } else if (@typeInfo(@TypeOf(@field(T, decl.name))) == .@"fn") {
            _ = &@field(T, decl.name);
        }
    }
}

comptime {
    for (modules) |module| analyzeDecls(module);
}

// `zig build test` only collects the tests of files reached from a test context,
// so every module has to be referenced here. Without it a failing router or API
// test does not fail the build.
test {
    inline for (modules) |module| _ = module;
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
    trusted_proxies: trusted_proxies.TrustedProxies = .{},
    database_path: []const u8 = "weather.db",
    /// The accounts file, apart from the weather database: IMGW can be
    /// downloaded again, what users keep here cannot.
    accounts_database_path: []const u8 = "accounts.db",
    /// The origin the site is served from, e.g. `https://szklana.pogoda`. Its
    /// scheme decides whether the session cookie is `__Host-` and `Secure`, and
    /// the requests that change state must name it in `Origin`.
    public_origin: ?[]const u8 = null,
    /// How many anonymous accounts one address may make in an hour. An address
    /// is shared by everyone behind a carrier or an office, so it is not small.
    new_sessions_per_hour: u32 = 30,
    imgw_interval_seconds: u64 = 10 * 60,
    imgw_warnings_interval_seconds: u64 = 5 * 60,
    /// How long one Antistorm reading is reused. Antistorm recomputes every
    /// fifteen minutes and asks not to be polled harder than that.
    storm_cache_seconds: u64 = 5 * 60,
    /// How long one Open-Meteo grid cell's forecast is reused. The underlying
    /// model does not update every request.
    forecast_cache_seconds: u64 = 15 * 60,

    // The host borrows storage from environ, which must outlive this config.
    fn fromEnv(environ: *const std.process.Environ.Map) !Config {
        const defaults: Config = .{};
        // TRUST_PROXY believed a forwarded header from any peer, which a
        // request sent straight to the origin can forge, so it is gone.
        if (environ.get("TRUST_PROXY") != null) {
            std.log.warn("TRUST_PROXY is no longer read; list the proxies in TRUSTED_PROXIES to trust their forwarded headers", .{});
        }
        const config: Config = .{
            .host = environ.get("HOST") orelse defaults.host,
            .port = try envInt(u16, environ, "PORT", defaults.port),
            .metrics_port = try envInt(u16, environ, "METRICS_PORT", defaults.metrics_port),
            .max_body_bytes = try envInt(usize, environ, "MAX_BODY_BYTES", defaults.max_body_bytes),
            .max_connections_per_cpu = try envInt(usize, environ, "MAX_CONNECTIONS_PER_CPU", defaults.max_connections_per_cpu),
            .trusted_proxies = try envProxies(environ, "TRUSTED_PROXIES", defaults.trusted_proxies),
            .database_path = environ.get("DATABASE_PATH") orelse defaults.database_path,
            .accounts_database_path = environ.get("ACCOUNTS_DATABASE_PATH") orelse defaults.accounts_database_path,
            .public_origin = environ.get("PUBLIC_ORIGIN") orelse defaults.public_origin,
            .new_sessions_per_hour = try envInt(u32, environ, "NEW_SESSIONS_PER_HOUR", defaults.new_sessions_per_hour),
            .imgw_interval_seconds = try envInt(u64, environ, "IMGW_INTERVAL_SECONDS", defaults.imgw_interval_seconds),
            .imgw_warnings_interval_seconds = try envInt(u64, environ, "IMGW_WARNINGS_INTERVAL_SECONDS", defaults.imgw_warnings_interval_seconds),
            .storm_cache_seconds = try envInt(u64, environ, "STORM_CACHE_SECONDS", defaults.storm_cache_seconds),
            .forecast_cache_seconds = try envInt(u64, environ, "FORECAST_CACHE_SECONDS", defaults.forecast_cache_seconds),
        };
        try config.validate();
        return config;
    }

    /// The cookie's form follows the scheme the site is served over. Without a
    /// configured origin it is the plain, development form.
    fn cookiePolicy(self: Config) accounts.cookie.Policy {
        const origin = self.public_origin orelse return .plain;
        return if (std.mem.startsWith(u8, origin, "https://")) .secure else .plain;
    }

    fn validate(self: Config) !void {
        if (self.public_origin) |origin| {
            const host_start = if (std.mem.startsWith(u8, origin, "https://")) "https://".len else if (std.mem.startsWith(u8, origin, "http://")) "http://".len else return error.InvalidPublicOrigin;
            const host = origin[host_start..];
            if (host.len == 0 or std.mem.findScalar(u8, host, '/') != null) return error.InvalidPublicOrigin;
        }
        if (self.new_sessions_per_hour == 0) return error.InvalidNewSessionsPerHour;
        if (self.max_connections_per_cpu == 0) return error.InvalidMaxConnectionsPerCpu;
        if (self.imgw_interval_seconds == 0) return error.InvalidImgwInterval;
        if (self.imgw_warnings_interval_seconds == 0) return error.InvalidImgwWarningsInterval;
        if (self.storm_cache_seconds == 0) return error.InvalidStormCacheInterval;
        if (self.forecast_cache_seconds == 0) return error.InvalidForecastCacheInterval;
    }

    fn concurrentLimit(self: Config, cpu_count: usize) !usize {
        try self.validate();
        const connections = try std.math.mul(usize, cpu_count, self.max_connections_per_cpu);
        // Reserve one task for each listener.
        return std.math.add(usize, connections, 2);
    }
};

/// How many sign-in codes one address may ask for in an hour.
const code_requests_per_hour = 20;

/// How many codes one address may try in ten minutes. A transfer code is ten
/// characters and lives ten minutes, so this leaves a guess with no chance.
const login_attempts_per_window = 10;
const login_window_seconds = 10 * std.time.s_per_min;

const routes = [_]router.Route{
    .{ .method = .GET, .path = "/", .handler = pages.home },
    .{ .method = .GET, .path = "/en/", .handler = pages.homeEn },
    .{ .method = .GET, .path = "/98.css", .handler = pages.style },
    .{ .method = .GET, .path = "/app.css", .handler = pages.appStyle },
    .{ .method = .GET, .path = "/app.js", .handler = pages.appScript },
    .{ .method = .GET, .path = "/alpine.js", .handler = pages.alpineScript },
    .{ .method = .GET, .path = "/icons.svg", .handler = pages.iconSprite },
    .{ .method = .GET, .path = "/favicon.svg", .handler = pages.favicon },
    .{ .method = .POST, .path = "/api/ping", .handler = api.ping },
    .{ .method = .GET, .path = "/healthz", .handler = health_route.health, .quiet = true },
    .{ .method = .GET, .path = "/api/memory", .handler = api.memory },
    .{ .method = .GET, .path = "/api/weather/history", .handler = api.weatherHistory },
    .{ .method = .GET, .path = "/api/weather/stations", .handler = api.weatherStations },
    .{ .method = .GET, .path = "/api/hydro/stations", .handler = api.hydroStations },
    .{ .method = .GET, .path = "/api/hydro/history", .handler = api.hydroHistory },
    .{ .method = .GET, .path = "/api/warnings", .handler = api.warningsActive },
    .{ .method = .GET, .path = "/api/warnings/history", .handler = api.warningsHistory },
    .{ .method = .GET, .path = "/api/warnings/revisions", .handler = api.warningsRevisions },
    .{ .method = .GET, .path = "/api/storm/cities", .handler = storm.cities },
    .{ .method = .GET, .path = "/api/storm/city", .handler = storm.city },
    .{ .method = .GET, .path = "/api/forecast", .handler = forecast_route.forecast },
    .{ .method = .GET, .path = "/api/me", .handler = account_route.sessionStatus },
    .{ .method = .DELETE, .path = "/api/me/session", .handler = account_route.signOut },
    .{ .method = .POST, .path = "/api/me/transfer-code", .handler = credentials_route.transferCode },
    .{ .method = .POST, .path = "/api/me/recovery-code", .handler = credentials_route.recoveryCode },
    .{ .method = .POST, .path = "/api/me/login", .handler = credentials_route.login },
    .{ .method = .GET, .path = "/api/me/favorites", .handler = favorites_route.list },
    .{ .method = .POST, .path = "/api/me/favorites", .handler = favorites_route.add },
    .{ .method = .DELETE, .path = "/api/me/favorites", .handler = favorites_route.remove },
};

const metrics_routes = [_]router.Route{
    .{ .method = .GET, .path = "/metrics", .handler = metrics_route.metrics, .quiet = true },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const config = try Config.fromEnv(init.environ_map);
    const database_path = try gpa.dupeSentinel(u8, config.database_path, 0);
    defer gpa.free(database_path);
    const accounts_database_path = try gpa.dupeSentinel(u8, config.accounts_database_path, 0);
    defer gpa.free(accounts_database_path);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    var threaded: Io.Threaded = .init(gpa, .{
        .concurrent_limit = .limited(try config.concurrentLimit(cpu_count)),
    });
    defer threaded.deinit();
    const io = threaded.io();

    // The timezone database has to be read before any listener starts, so the
    // clock every task reads is complete before the first task runs.
    timestamps.initSystemTimeZone(gpa, io) catch |err| {
        std.log.warn("no timezone database ({t}), using the fixed Warsaw rule", .{err});
        timestamps.useFallbackClock();
    };
    var observations = try weather.Store.initFile(gpa, database_path, timestamps.clock().*);
    defer observations.deinit();
    var account_store = try accounts.Store.initFile(accounts_database_path);
    defer account_store.deinit();
    var new_session_limiter: accounts.Limiter = .init(gpa, config.new_sessions_per_hour, std.time.s_per_hour, .allow);
    defer new_session_limiter.deinit();
    // Asking for a code is rare, so a table that fills up refuses: a stolen
    // cookie must not be able to mint recovery codes past the limit.
    var login_limiter: accounts.Limiter = .init(gpa, login_attempts_per_window, login_window_seconds, .refuse);
    defer login_limiter.deinit();
    var code_limiter: accounts.Limiter = .init(gpa, code_requests_per_hour, std.time.s_per_hour, .refuse);
    defer code_limiter.deinit();
    if (config.public_origin == null) {
        std.log.warn("PUBLIC_ORIGIN is not set: session cookies are not Secure and the Origin of a state-changing request is compared with its Host", .{});
    }
    var metrics_registry = metrics.Registry.init(gpa);
    defer metrics_registry.deinit();
    metrics_registry.declareUpstreams();
    metrics_registry.declareSessions();
    server.declareMetrics(&metrics_registry);
    weather.updater.declareMetrics(&metrics_registry);
    var storm_client = antistorm.Client.init(gpa, io, config.storm_cache_seconds);
    defer storm_client.deinit();
    storm_client.metrics = &metrics_registry;
    var forecast_client = openmeteo.Client.init(gpa, io, config.forecast_cache_seconds);
    defer forecast_client.deinit();
    forecast_client.metrics = &metrics_registry;

    var address = try net.IpAddress.parseIp4(config.host, config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var metrics_address = try net.IpAddress.parseIp4(config.host, config.metrics_port);
    var metrics_listener = try metrics_address.listen(io, .{ .reuse_address = true });
    defer metrics_listener.deinit(io);

    var app: router.App = .{ .max_body_bytes = config.max_body_bytes, .trusted_proxies = config.trusted_proxies, .metrics = &metrics_registry, .weather_store = &observations, .accounts = &account_store, .new_session_limiter = &new_session_limiter, .code_limiter = &code_limiter, .login_limiter = &login_limiter, .cookie_policy = config.cookiePolicy(), .public_origin = config.public_origin, .storm = &storm_client, .forecast = &forecast_client, .io = io };
    var metrics_app: router.App = .{ .max_body_bytes = config.max_body_bytes, .trusted_proxies = config.trusted_proxies, .metrics = &metrics_registry };
    var connections: Io.Group = .init;
    defer connections.await(io) catch |err| std.log.warn("connections did not shut down cleanly: {t}", .{err});
    var listeners: Io.Group = .init;
    defer listeners.await(io) catch |err| std.log.warn("listeners did not shut down cleanly: {t}", .{err});

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
    // A poll decodes megabytes and stores them immediately, so its scratch
    // memory is handed to an allocator that returns pages to the kernel rather
    // than to the one the process keeps its long-lived state in.
    try connections.concurrent(io, weather.updater.run, .{ std.heap.page_allocator, io, &observations, &metrics_registry, config.imgw_interval_seconds });
    try connections.concurrent(io, weather.updater.runWarnings, .{ std.heap.page_allocator, io, &observations, &metrics_registry, config.imgw_warnings_interval_seconds });
    try listeners.await(io);
}

fn envInt(comptime T: type, environ: *const std.process.Environ.Map, name: []const u8, default: T) !T {
    const raw = environ.get(name) orelse return default;
    return std.fmt.parseInt(T, raw, 10) catch |err| {
        std.log.err("invalid {s}=\"{s}\": {t}", .{ name, raw, err });
        return err;
    };
}

fn envProxies(environ: *const std.process.Environ.Map, name: []const u8, default: trusted_proxies.TrustedProxies) !trusted_proxies.TrustedProxies {
    const raw = environ.get(name) orelse return default;
    return trusted_proxies.TrustedProxies.parse(raw) catch |err| {
        std.log.err("invalid {s}=\"{s}\": {t}", .{ name, raw, err });
        return err;
    };
}

test "config uses defaults for an empty environment" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    const config = try Config.fromEnv(&environ);
    try std.testing.expectEqualDeep(Config{}, config);
    try std.testing.expectEqual(@as(usize, 10), try config.concurrentLimit(2));
}

test "config reads environment overrides" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOST", "127.0.0.1");
    try environ.put("PORT", "18080");
    try environ.put("METRICS_PORT", "19090");
    try environ.put("MAX_BODY_BYTES", "2048");
    try environ.put("MAX_CONNECTIONS_PER_CPU", "8");
    try environ.put("TRUSTED_PROXIES", "172.18.0.0/16, 10.0.0.1");
    try environ.put("DATABASE_PATH", "var/weather.db");
    try environ.put("ACCOUNTS_DATABASE_PATH", "var/accounts.db");
    try environ.put("PUBLIC_ORIGIN", "https://szklana.pogoda");
    try environ.put("NEW_SESSIONS_PER_HOUR", "5");
    try environ.put("IMGW_WARNINGS_INTERVAL_SECONDS", "120");
    try environ.put("STORM_CACHE_SECONDS", "60");
    try environ.put("FORECAST_CACHE_SECONDS", "30");

    const config = try Config.fromEnv(&environ);
    try std.testing.expectEqualDeep(Config{
        .host = "127.0.0.1",
        .port = 18080,
        .metrics_port = 19090,
        .max_body_bytes = 2048,
        .max_connections_per_cpu = 8,
        .trusted_proxies = try trusted_proxies.TrustedProxies.parse("172.18.0.0/16,10.0.0.1"),
        .database_path = "var/weather.db",
        .accounts_database_path = "var/accounts.db",
        .public_origin = "https://szklana.pogoda",
        .new_sessions_per_hour = 5,
        .imgw_warnings_interval_seconds = 120,
        .storm_cache_seconds = 60,
        .forecast_cache_seconds = 30,
    }, config);
    try std.testing.expectEqual(@as(usize, 26), try config.concurrentLimit(3));
}

test "the cookie policy follows the scheme of the public origin" {
    try std.testing.expectEqual(accounts.cookie.Policy.plain, (Config{}).cookiePolicy());
    try std.testing.expectEqual(accounts.cookie.Policy.plain, (Config{ .public_origin = "http://localhost:8080" }).cookiePolicy());
    try std.testing.expectEqual(accounts.cookie.Policy.secure, (Config{ .public_origin = "https://szklana.pogoda" }).cookiePolicy());
}

test "config rejects a public origin that is not a bare origin" {
    for ([_][]const u8{ "szklana.pogoda", "https://", "https://szklana.pogoda/", "https://szklana.pogoda/en", "ftp://szklana.pogoda" }) |origin| {
        var environ = std.process.Environ.Map.init(std.testing.allocator);
        defer environ.deinit();
        try environ.put("PUBLIC_ORIGIN", origin);
        try std.testing.expectError(error.InvalidPublicOrigin, Config.fromEnv(&environ));
    }
}

test "config rejects zero new sessions per hour" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("NEW_SESSIONS_PER_HOUR", "0");
    try std.testing.expectError(error.InvalidNewSessionsPerHour, Config.fromEnv(&environ));
}

test "config rejects zero connections per CPU" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("MAX_CONNECTIONS_PER_CPU", "0");
    try std.testing.expectError(error.InvalidMaxConnectionsPerCpu, Config.fromEnv(&environ));
}

test "config rejects zero IMGW warnings interval" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("IMGW_WARNINGS_INTERVAL_SECONDS", "0");
    try std.testing.expectError(error.InvalidImgwWarningsInterval, Config.fromEnv(&environ));
}

test "config rejects zero IMGW interval" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("IMGW_INTERVAL_SECONDS", "0");
    try std.testing.expectError(error.InvalidImgwInterval, Config.fromEnv(&environ));
}

test "config rejects zero storm cache interval" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("STORM_CACHE_SECONDS", "0");
    try std.testing.expectError(error.InvalidStormCacheInterval, Config.fromEnv(&environ));
}

test "config rejects zero forecast cache interval" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("FORECAST_CACHE_SECONDS", "0");
    try std.testing.expectError(error.InvalidForecastCacheInterval, Config.fromEnv(&environ));
}

test "config detects multiplication and listener reservation overflow" {
    const config: Config = .{ .max_connections_per_cpu = std.math.maxInt(usize) };
    try std.testing.expectError(error.Overflow, config.concurrentLimit(2));
    try std.testing.expectError(error.Overflow, config.concurrentLimit(1));

    const largest_valid: Config = .{ .max_connections_per_cpu = std.math.maxInt(usize) - 2 };
    try std.testing.expectEqual(std.math.maxInt(usize), try largest_valid.concurrentLimit(1));
}
