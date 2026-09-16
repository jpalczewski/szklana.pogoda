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

pub const std_options: std.Options = .{
    .logFn = app_log.logFn,
};

const default_port: u16 = 8080;
const default_metrics_port: u16 = 9090;
const default_host = "0.0.0.0";
const default_max_body_bytes: usize = 16 * 1024;
const default_max_connections_per_cpu: usize = 4;

const routes = [_]router.Route{
    .{ .method = .GET, .path = "/", .handler = pages.home },
    .{ .method = .GET, .path = "/en/", .handler = pages.home_en },
    .{ .method = .GET, .path = "/98.css", .handler = pages.style },
    .{ .method = .GET, .path = "/app.css", .handler = pages.app_style },
    .{ .method = .GET, .path = "/app.js", .handler = pages.app_script },
    .{ .method = .GET, .path = "/alpine.js", .handler = pages.alpine_script },
    .{ .method = .POST, .path = "/api/ping", .handler = api.ping },
    .{ .method = .GET, .path = "/api/memory", .handler = api.memory },
};

const metrics_routes = [_]router.Route{
    .{ .method = .GET, .path = "/metrics", .handler = metrics_route.metrics },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const environ = init.environ_map;

    const host = envStr(environ, "HOST", default_host);
    const port = try envInt(u16, environ, "PORT", default_port);
    const metrics_port = try envInt(u16, environ, "METRICS_PORT", default_metrics_port);
    const max_body_bytes = try envInt(usize, environ, "MAX_BODY_BYTES", default_max_body_bytes);
    const max_connections_per_cpu = try envInt(usize, environ, "MAX_CONNECTIONS_PER_CPU", default_max_connections_per_cpu);
    const trust_proxy = try envBool(environ, "TRUST_PROXY", false);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    var threaded: Io.Threaded = .init(gpa, .{
        .concurrent_limit = .limited(cpu_count * max_connections_per_cpu + 2),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var address = try net.IpAddress.parseIp4(host, port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var metrics_address = try net.IpAddress.parseIp4(host, metrics_port);
    var metrics_listener = try metrics_address.listen(io, .{ .reuse_address = true });
    defer metrics_listener.deinit(io);

    var metrics_registry = metrics.Registry.init(gpa);
    defer metrics_registry.deinit();
    var app: router.App = .{ .max_body_bytes = max_body_bytes, .trust_proxy = trust_proxy, .metrics = &metrics_registry };
    var metrics_app: router.App = .{ .max_body_bytes = max_body_bytes, .trust_proxy = trust_proxy, .metrics = &metrics_registry };
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

    std.log.info("szklana.pogoda listening on {s}:{d}", .{ host, port });
    std.log.info("metrics listening on {s}:{d}", .{ host, metrics_port });

    try listeners.concurrent(io, server.serve, .{ gpa, io, &app_listener_config, &connections });
    try listeners.concurrent(io, server.serve, .{ gpa, io, &metrics_listener_config, &connections });
    try listeners.await(io);
}

fn envInt(comptime T: type, environ: *const std.process.Environ.Map, name: []const u8, default: T) !T {
    const raw = environ.get(name) orelse return default;
    return std.fmt.parseInt(T, raw, 10) catch |err| {
        std.log.err("invalid {s}=\"{s}\": {t}", .{ name, raw, err });
        return err;
    };
}

fn envStr(environ: *const std.process.Environ.Map, name: []const u8, default: []const u8) []const u8 {
    return environ.get(name) orelse default;
}

fn envBool(environ: *const std.process.Environ.Map, name: []const u8, default: bool) !bool {
    const raw = environ.get(name) orelse return default;
    if (std.ascii.eqlIgnoreCase(raw, "true")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    std.log.err("invalid {s}=\"{s}\": expected true or false", .{ name, raw });
    return error.InvalidBoolean;
}
