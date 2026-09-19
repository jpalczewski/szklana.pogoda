const std = @import("std");
const http = std.http;
const Io = std.Io;
const net = Io.net;

const app_log = @import("app_log.zig");
const metrics = @import("metrics.zig");
const router = @import("router.zig");

pub const ListenerConfig = struct {
    name: []const u8,
    listener: *net.Server,
    app: *router.App,
    routes: []const router.Route,
    instrument_requests: bool,
};

const Observation = struct {
    registry: ?*metrics.Registry,
    started_at: Io.Timestamp,
    peer_ip: []const u8,
    client_ip: []const u8,
    method: []const u8,
    route: []const u8,
    target: []const u8,
    headers: []const router.Header,

    fn begin(self: *const Observation) void {
        if (self.registry) |registry| registry.begin(self.method, self.route);
    }

    fn end(self: *const Observation) void {
        if (self.registry) |registry| registry.end(self.method, self.route);
    }

    fn finish(self: *const Observation, io: Io, response: router.Response) void {
        const elapsed_ms = self.started_at.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
        app_log.logAccess(.{
            .client_ip = self.client_ip,
            .peer_ip = self.peer_ip,
            .method = self.method,
            .target = self.target,
            .status = @intCast(@intFromEnum(response.status)),
            .duration_ms = @intCast(@max(0, elapsed_ms)),
            .user_agent = findHeader(self.headers, "user-agent"),
            .referer = findHeader(self.headers, "referer"),
            .response_bytes = response.body.len,
        });
        if (self.registry) |registry| {
            const duration_ns = elapsed_ms * std.time.ns_per_ms;
            registry.finish(self.method, self.route, @intCast(@intFromEnum(response.status)), @intCast(@max(0, duration_ns)));
        }
    }
};

pub fn serve(gpa: std.mem.Allocator, io: Io, config: *const ListenerConfig, connections: *Io.Group) void {
    while (true) {
        const stream = config.listener.accept(io) catch |err| {
            std.log.err("{s} accept failed: {t}", .{ config.name, err });
            continue;
        };
        connections.concurrent(io, handleConnectionTask, .{ gpa, io, stream, config }) catch |err| {
            std.log.err("{s} spawn failed, handling inline: {t}", .{ config.name, err });
            handleConnectionTask(gpa, io, stream, config);
        };
    }
}

pub fn handleConnectionTask(gpa: std.mem.Allocator, io: Io, stream: net.Stream, config: *const ListenerConfig) void {
    handleConnection(gpa, io, stream, config) catch |err| {
        std.log.err("connection error: {t}", .{err});
    };
}

fn handleConnection(gpa: std.mem.Allocator, io: Io, stream_in: net.Stream, config: *const ListenerConfig) !void {
    var stream = stream_in;
    defer stream.close(io);

    var send_buffer: [8192]u8 = undefined;
    var recv_buffer: [8192]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var http_server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);
    const started_at = Io.Clock.awake.now(io);

    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var peer_ip_buffer: [64]u8 = undefined;
    const peer_ip = try formatIpAddress(&peer_ip_buffer, stream.socket.address);

    // Request-head strings alias the connection buffer and become invalid
    // when the body reader is initialized, so retain what routing needs first.
    const method = request.head.method;
    const target = try allocator.dupe(u8, request.head.target);
    const headers = try copyHeaders(&request, allocator);
    const content_length = request.head.content_length;
    const target_parts = router.splitTarget(target);
    const client_ip = clientIp(config.app.trust_proxy, headers, peer_ip);
    const observation: Observation = .{
        .registry = if (config.instrument_requests) config.app.metrics else null,
        .started_at = started_at,
        .peer_ip = peer_ip,
        .client_ip = client_ip,
        .method = @tagName(method),
        .route = routeLabel(config.routes, target_parts.path),
        .target = target,
        .headers = headers,
    };
    observation.begin();
    defer observation.end();

    if (content_length) |length| {
        if (length > config.app.max_body_bytes) {
            try writeResponseAndLog(io, &request, router.errorResponse(allocator, target_parts.path, error.PayloadTooLarge), &observation);
            return;
        }
    }

    const has_framed_body = content_length != null or request.head.transfer_encoding == .chunked;
    // zlinter-disable-next-line no_undefined - set below when has_framed_body; body_ptr stays null otherwise, so body is never read unset
    var body: router.Body = undefined;
    const body_ptr: ?*router.Body = if (has_framed_body) blk: {
        const body_reader = request.readerExpectContinue(&.{}) catch |err| {
            try writeResponseAndLog(io, &request, router.errorResponse(allocator, target_parts.path, error.BadRequest), &observation);
            return err;
        };
        body = router.Body.init(body_reader, config.app.max_body_bytes);
        break :blk &body;
    } else null;

    var context: router.RequestContext = .{
        .allocator = allocator,
        .method = method,
        .path = target_parts.path,
        .query = target_parts.query,
        .headers = headers,
        .body = body_ptr,
    };

    const response = router.dispatch(config.routes, config.app, &context) catch |err| router.errorResponse(allocator, context.path, err);
    try writeResponseAndLog(io, &request, response, &observation);
}

fn routeLabel(routes: []const router.Route, path: []const u8) []const u8 {
    for (routes) |route| {
        if (std.mem.eql(u8, route.path, path)) return route.path;
    }
    return "unmatched";
}

fn clientIp(trust_proxy: bool, headers: []const router.Header, peer_ip: []const u8) []const u8 {
    if (!trust_proxy) return peer_ip;

    if (findHeader(headers, "x-forwarded-for")) |forwarded_for| {
        const first = std.mem.trim(u8, forwarded_for[0..(std.mem.findScalar(u8, forwarded_for, ',') orelse forwarded_for.len)], " \t");
        if (first.len != 0) return first;
    }
    if (findHeader(headers, "x-real-ip")) |real_ip| {
        const trimmed = std.mem.trim(u8, real_ip, " \t");
        if (trimmed.len != 0) return trimmed;
    }
    return peer_ip;
}

fn findHeader(headers: []const router.Header, name: []const u8) ?[]const u8 {
    for (headers) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
    }
    return null;
}

fn formatIpAddress(buffer: []u8, address: net.IpAddress) ![]const u8 {
    return switch (address) {
        .ip4 => |ip4| std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3] }),
        .ip6 => |ip6| std.fmt.bufPrint(buffer, "{f}", .{net.Ip6Address.Unresolved{
            .bytes = ip6.bytes,
            .interface_name = null,
        }}),
    };
}

fn copyHeaders(request: *http.Server.Request, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const router.Header {
    var headers: std.ArrayList(router.Header) = .empty;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        try headers.append(allocator, .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
        });
    }
    return try headers.toOwnedSlice(allocator);
}

fn writeResponse(request: *http.Server.Request, response: router.Response) !void {
    const unused: http.Header = .{ .name = "", .value = "" };
    var headers = [_]http.Header{
        .{ .name = "content-type", .value = response.content_type },
        unused,
        unused,
    };
    var count: usize = 1;
    if (response.allow) |allow| {
        headers[count] = .{ .name = "allow", .value = allow };
        count += 1;
    }
    if (response.cache_control) |cache_control| {
        headers[count] = .{ .name = "cache-control", .value = cache_control };
        count += 1;
    }

    try request.respond(response.body, .{
        .status = response.status,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    });
}

fn writeResponseAndLog(
    io: Io,
    request: *http.Server.Request,
    response: router.Response,
    observation: *const Observation,
) !void {
    try writeResponse(request, response);
    observation.finish(io, response);
}

test "observation stays active until scope exit including error returns" {
    const exercise = struct {
        fn run(registry: *metrics.Registry, fail: bool) !void {
            const observation: Observation = .{
                .registry = registry,
                .started_at = Io.Clock.awake.now(std.testing.io),
                .peer_ip = "192.0.2.1",
                .client_ip = "192.0.2.1",
                .method = "GET",
                .route = "/",
                .target = "/",
                .headers = &.{},
            };
            observation.begin();
            defer observation.end();

            const active = try registry.renderAlloc(std.testing.allocator);
            defer std.testing.allocator.free(active);
            try std.testing.expect(std.mem.find(u8, active, "szklana_pogoda_http_in_flight_requests{method=\"GET\",route=\"/\"} 1\n") != null);
            if (fail) return error.TestRequestFailed;
        }
    };

    var registry = metrics.Registry.init(std.testing.allocator);
    defer registry.deinit();
    for ([_]bool{ false, true }) |fail| {
        if (fail) {
            try std.testing.expectError(error.TestRequestFailed, exercise.run(&registry, fail));
        } else {
            try exercise.run(&registry, fail);
        }
        const ended = try registry.renderAlloc(std.testing.allocator);
        defer std.testing.allocator.free(ended);
        try std.testing.expect(std.mem.find(u8, ended, "szklana_pogoda_http_in_flight_requests{method=\"GET\",route=\"/\"} 0\n") != null);
        // Only a finished request is counted; an observation that just ends is not.
        try std.testing.expect(std.mem.find(u8, ended, "szklana_pogoda_http_requests_total{") == null);
    }
}

test "client IP uses peer address unless proxy headers are trusted" {
    const headers = [_]router.Header{
        .{ .name = "X-Forwarded-For", .value = " 203.0.113.4, 198.51.100.7" },
        .{ .name = "X-Real-IP", .value = "203.0.113.5" },
    };
    try std.testing.expectEqualStrings("192.0.2.10", clientIp(false, &headers, "192.0.2.10"));
    try std.testing.expectEqualStrings("203.0.113.4", clientIp(true, &headers, "192.0.2.10"));
}

test "client IP falls back from proxy headers to peer address" {
    const real_ip_headers = [_]router.Header{.{ .name = "X-Real-IP", .value = " 203.0.113.5 " }};
    try std.testing.expectEqualStrings("203.0.113.5", clientIp(true, &real_ip_headers, "192.0.2.10"));
    try std.testing.expectEqualStrings("192.0.2.10", clientIp(true, &.{}, "192.0.2.10"));
}

test "peer address formatting omits TCP port" {
    var buffer: [64]u8 = undefined;
    const address = try net.IpAddress.parseIp4("192.0.2.10", 12345);
    try std.testing.expectEqualStrings("192.0.2.10", try formatIpAddress(&buffer, address));
}

test "route labels use a bounded unmatched value" {
    const testHandlerFn = struct {
        fn handle(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
            return router.Response.text(.ok, "ok");
        }
    }.handle;
    const routes = [_]router.Route{.{ .method = .GET, .path = "/known", .handler = testHandlerFn }};
    try std.testing.expectEqualStrings("/known", routeLabel(&routes, "/known"));
    try std.testing.expectEqualStrings("unmatched", routeLabel(&routes, "/other"));
}
