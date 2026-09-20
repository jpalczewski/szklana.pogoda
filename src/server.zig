const std = @import("std");
const http = std.http;
const Io = std.Io;
const net = Io.net;

const app_log = @import("app_log.zig");
const metrics = @import("metrics/mod.zig");
const router = @import("router.zig");
const trusted_proxies = @import("trusted_proxies.zig");

pub const ListenerConfig = struct {
    name: []const u8,
    listener: *net.Server,
    app: *router.App,
    routes: []const router.Route,
    instrument_requests: bool,
};

const Observation = struct {
    registry: ?*metrics.Registry,
    timer: metrics.Timer,
    peer_ip: []const u8,
    client_ip: []const u8,
    method: []const u8,
    route: []const u8,
    target: []const u8,
    headers: []const router.Header,
    /// The route is `quiet`: its access line is written only when it failed.
    /// Its metrics are left out by giving it no `registry`.
    quiet: bool = false,

    fn begin(self: *const Observation) void {
        if (self.registry) |registry| registry.begin(self.method, self.route);
    }

    fn end(self: *const Observation) void {
        if (self.registry) |registry| registry.end(self.method, self.route);
    }

    fn finish(self: *const Observation, io: Io, response: router.Response) void {
        const duration_ns = self.timer.elapsedNs(io);
        if (self.logsAccess(response.status)) {
            app_log.logAccess(.{
                .client_ip = self.client_ip,
                .peer_ip = self.peer_ip,
                .method = self.method,
                .target = self.target,
                .status = @intCast(@intFromEnum(response.status)),
                .duration_ms = duration_ns / std.time.ns_per_ms,
                .user_agent = findHeader(self.headers, "user-agent"),
                .referer = findHeader(self.headers, "referer"),
                .response_bytes = response.body.len,
            });
        }
        self.count(response.status, duration_ns);
    }

    fn logsAccess(self: *const Observation, status: http.Status) bool {
        return !self.quiet or status.class() != .success;
    }

    fn count(self: *const Observation, status: http.Status, duration_ns: u64) void {
        if (self.registry) |registry| registry.finish(self.method, self.route, @intCast(@intFromEnum(status)), duration_ns);
    }
};

/// Makes the head-error series exist before the first error, one per error
/// `handleConnection` counts (a closing connection is not an error).
pub fn declareMetrics(registry: *metrics.Registry) void {
    inline for (@typeInfo(http.Server.ReceiveHeadError).error_set.?) |head_error| {
        if (comptime !std.mem.eql(u8, head_error.name, "HttpConnectionClosing")) registry.declareHeadError(head_error.name);
    }
}

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
    const registry = instrumentedRegistry(config);

    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => {
            if (registry) |instrumented| instrumented.headError(@errorName(err));
            return err;
        },
    };
    // Timed from here: the wait for the client to send its head is the
    // client's, not the handler's, and would otherwise fill the histogram.
    const timer: metrics.Timer = .start(io);

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
    const client_ip = clientIp(config.app.trusted_proxies, stream.socket.address, headers, peer_ip);
    const route = matchRoute(config.routes, target_parts.path);
    const quiet = if (route) |matched| matched.quiet else false;
    const observation: Observation = .{
        .registry = if (quiet) null else registry,
        .quiet = quiet,
        .timer = timer,
        .peer_ip = peer_ip,
        .client_ip = client_ip,
        .method = @tagName(method),
        .route = if (route) |matched| matched.path else "unmatched",
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
        .client_ip = client_ip,
    };

    const response = router.dispatch(config.routes, config.app, &context) catch |err| router.errorResponse(allocator, context.path, err);
    try writeResponseAndLog(io, &request, response, &observation);
}

/// The registry a listener reports to, if it reports at all: the metrics
/// listener does not count its own scrapes.
fn instrumentedRegistry(config: *const ListenerConfig) ?*metrics.Registry {
    return if (config.instrument_requests) config.app.metrics else null;
}

/// The route registered for `path`, whatever its method. Its `path` is the
/// metrics label, which is why the label is bounded by the route table and
/// never taken from the request.
fn matchRoute(routes: []const router.Route, path: []const u8) ?router.Route {
    for (routes) |route| {
        if (std.mem.eql(u8, route.path, path)) return route;
    }
    return null;
}

/// The address to attribute a request to. Forwarded headers are read only when
/// the TCP peer is a listed proxy; otherwise the header is whatever the sender
/// typed and the peer itself is the answer. Behind Cloudflare, `X-Forwarded-For`
/// holds only the edge that reached the proxy, so `CF-Connecting-IP`, which
/// Cloudflare sets to the visitor, is read first. A value that is not an IP
/// address is skipped rather than logged.
fn clientIp(proxies: trusted_proxies.TrustedProxies, peer: net.IpAddress, headers: []const router.Header, peer_ip: []const u8) []const u8 {
    if (!proxies.contains(peer)) return peer_ip;

    if (findHeader(headers, "cf-connecting-ip")) |value| {
        if (validAddress(value)) |address| return address;
    }
    if (findHeader(headers, "x-forwarded-for")) |value| {
        if (validAddress(value[0..(std.mem.findScalar(u8, value, ',') orelse value.len)])) |address| return address;
    }
    if (findHeader(headers, "x-real-ip")) |value| {
        if (validAddress(value)) |address| return address;
    }
    return peer_ip;
}

fn validAddress(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    _ = net.IpAddress.parse(trimmed, 0) catch return null;
    return trimmed;
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

    if (response.set_cookie) |set_cookie| {
        headers[count] = .{ .name = "set-cookie", .value = set_cookie };
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
    // The handler produced this status whether or not the client stayed to
    // read it, so the request is counted either way.
    defer observation.finish(io, response);
    try writeResponse(request, response);
}

test "observation stays active until scope exit including error returns" {
    const exercise = struct {
        fn run(registry: *metrics.Registry, fail: bool) !void {
            const observation: Observation = .{
                .registry = registry,
                .timer = .start(std.testing.io),
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

// Not `finish`: it writes the access log to stdout, which is the channel the
// test runner talks over, and a test that writes there hangs the build.
test "counting an observation records the request once under its status" {
    var registry = metrics.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const observation: Observation = .{
        .registry = &registry,
        .timer = .start(std.testing.io),
        .peer_ip = "192.0.2.1",
        .client_ip = "192.0.2.1",
        .method = "GET",
        .route = "/known",
        .target = "/known",
        .headers = &.{},
    };

    observation.count(.not_found, 3 * std.time.ns_per_ms);

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_http_requests_total{method=\"GET\",route=\"/known\",status=\"404\"} 1\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "_duration_seconds_count{method=\"GET\",route=\"/known\",status=\"404\"} 1\n") != null);
}

test "an unreadable head is counted only on an instrumented listener" {
    var registry = metrics.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .metrics = &registry };
    var listener: net.Server = undefined;
    const instrumented: ListenerConfig = .{ .name = "application", .listener = &listener, .app = &app, .routes = &.{}, .instrument_requests = true };
    const scrape: ListenerConfig = .{ .name = "metrics", .listener = &listener, .app = &app, .routes = &.{}, .instrument_requests = false };

    try std.testing.expect(instrumentedRegistry(&instrumented) == &registry);
    try std.testing.expect(instrumentedRegistry(&scrape) == null);
}

fn testPeer(text: []const u8) !net.IpAddress {
    return net.IpAddress.parse(text, 0);
}

fn testProxies() !trusted_proxies.TrustedProxies {
    return trusted_proxies.TrustedProxies.parse("172.18.0.0/16");
}

test "client IP is the peer address when the peer is not a trusted proxy" {
    const headers = [_]router.Header{
        .{ .name = "CF-Connecting-IP", .value = "203.0.113.9" },
        .{ .name = "X-Forwarded-For", .value = "203.0.113.4" },
    };
    // A request sent straight to the origin can carry any header it likes.
    try std.testing.expectEqualStrings("198.51.100.7", clientIp(try testProxies(), try testPeer("198.51.100.7"), &headers, "198.51.100.7"));
    try std.testing.expectEqualStrings("172.18.0.6", clientIp(.{}, try testPeer("172.18.0.6"), &headers, "172.18.0.6"));
}

test "client IP prefers CF-Connecting-IP from a trusted proxy" {
    const headers = [_]router.Header{
        .{ .name = "X-Forwarded-For", .value = "162.158.1.1" },
        .{ .name = "cf-connecting-ip", .value = " 203.0.113.9 " },
    };
    try std.testing.expectEqualStrings("203.0.113.9", clientIp(try testProxies(), try testPeer("172.18.0.6"), &headers, "172.18.0.6"));
}

test "client IP falls back from CF-Connecting-IP to the forwarded headers and the peer" {
    const peer = try testPeer("172.18.0.6");
    const forwarded = [_]router.Header{.{ .name = "X-Forwarded-For", .value = " 203.0.113.4, 198.51.100.7" }};
    try std.testing.expectEqualStrings("203.0.113.4", clientIp(try testProxies(), peer, &forwarded, "172.18.0.6"));
    const real_ip = [_]router.Header{.{ .name = "X-Real-IP", .value = " 203.0.113.5 " }};
    try std.testing.expectEqualStrings("203.0.113.5", clientIp(try testProxies(), peer, &real_ip, "172.18.0.6"));
    try std.testing.expectEqualStrings("172.18.0.6", clientIp(try testProxies(), peer, &.{}, "172.18.0.6"));
}

test "client IP skips a header that is not an address" {
    const headers = [_]router.Header{
        .{ .name = "CF-Connecting-IP", .value = "not-an-ip\",\"x\":1" },
        .{ .name = "X-Forwarded-For", .value = "" },
        .{ .name = "X-Real-IP", .value = "203.0.113.5" },
    };
    try std.testing.expectEqualStrings("203.0.113.5", clientIp(try testProxies(), try testPeer("172.18.0.6"), &headers, "172.18.0.6"));
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
    try std.testing.expectEqualStrings("/known", matchRoute(&routes, "/known").?.path);
    try std.testing.expect(matchRoute(&routes, "/other") == null);
}

test "a quiet route is logged only when it failed" {
    const observation: Observation = .{
        .registry = null,
        .quiet = true,
        .timer = .start(std.testing.io),
        .peer_ip = "192.0.2.1",
        .client_ip = "192.0.2.1",
        .method = "GET",
        .route = "/healthz",
        .target = "/healthz",
        .headers = &.{},
    };
    try std.testing.expect(!observation.logsAccess(.ok));
    try std.testing.expect(observation.logsAccess(.internal_server_error));
    try std.testing.expect(observation.logsAccess(.method_not_allowed));

    var loud = observation;
    loud.quiet = false;
    try std.testing.expect(loud.logsAccess(.ok));
}

test "a quiet route is left out of the request metrics" {
    var registry = metrics.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const routes = [_]router.Route{
        .{ .method = .GET, .path = "/healthz", .handler = okHandler, .quiet = true },
        .{ .method = .GET, .path = "/api/memory", .handler = okHandler },
    };
    for ([_][]const u8{ "/healthz", "/api/memory" }) |path| {
        const route = matchRoute(&routes, path).?;
        const observation: Observation = .{
            .registry = if (route.quiet) null else &registry,
            .quiet = route.quiet,
            .timer = .start(std.testing.io),
            .peer_ip = "192.0.2.1",
            .client_ip = "192.0.2.1",
            .method = "GET",
            .route = route.path,
            .target = path,
            .headers = &.{},
        };
        observation.begin();
        observation.count(.ok, std.time.ns_per_ms);
        observation.end();
    }

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "route=\"/healthz\"") == null);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_http_requests_total{method=\"GET\",route=\"/api/memory\",status=\"200\"} 1\n") != null);
}

fn okHandler(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return router.Response.text(.ok, "ok");
}
