const std = @import("std");
const http = std.http;
const Io = std.Io;
const net = Io.net;

// Defaults; every one of these is overridable via an environment variable
// of the same name (see envInt/envStr below), so the server can be tuned
// without a rebuild.
const default_port: u16 = 8080;
const default_host = "0.0.0.0";
const default_max_body_bytes: usize = 16 * 1024;
// Connections are I/O-bound (mostly waiting on the network), so allowing
// several per CPU core keeps throughput up without letting an unbounded
// number of 16 MiB thread stacks pile up under a connection flood.
const default_max_connections_per_cpu: usize = 4;

const index_html = @embedFile("web/index.html");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const environ = init.environ_map;

    const host = envStr(environ, "HOST", default_host);
    const port = try envInt(u16, environ, "PORT", default_port);
    const max_body_bytes = try envInt(usize, environ, "MAX_BODY_BYTES", default_max_body_bytes);
    const max_connections_per_cpu = try envInt(usize, environ, "MAX_CONNECTIONS_PER_CPU", default_max_connections_per_cpu);

    // init.io's default Threaded instance has an unlimited concurrent_limit,
    // so Group.concurrent below would spawn one thread per connection with
    // no cap. Build our own with an explicit limit instead.
    const cpu_count = std.Thread.getCpuCount() catch 1;
    var threaded: Io.Threaded = .init(gpa, .{
        .concurrent_limit = .limited(cpu_count * max_connections_per_cpu),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var address = try net.IpAddress.parseIp4(host, port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    // Tasks release their resources as soon as each one finishes, not when
    // the group as a whole is awaited, so it's fine to keep adding
    // connections to this one long-lived group for the life of the process.
    var connections: Io.Group = .init;
    defer connections.await(io) catch {};

    std.log.info("szklana.pogoda listening on {s}:{d}", .{ host, port });

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            continue;
        };
        // .concurrent (rather than .async) asks the Io implementation for
        // real concurrency, so accept() keeps looping while this connection
        // is blocked on I/O elsewhere. init.io defaults to std.Io.Threaded,
        // which supports it; fall back to handling inline if it can't.
        connections.concurrent(io, handleConnectionTask, .{ gpa, io, stream, max_body_bytes }) catch |err| {
            std.log.err("spawn failed, handling inline: {t}", .{err});
            handleConnectionTask(gpa, io, stream, max_body_bytes);
        };
    }
}

/// Reads `name` from the environment as an integer, falling back to
/// `default` when unset. An invalid value is a startup-config error, not
/// silently ignored.
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

fn handleConnectionTask(gpa: std.mem.Allocator, io: Io, stream: net.Stream, max_body_bytes: usize) void {
    handleConnection(gpa, io, stream, max_body_bytes) catch |err| {
        std.log.err("connection error: {t}", .{err});
    };
}

fn handleConnection(gpa: std.mem.Allocator, io: Io, stream_in: net.Stream, max_body_bytes: usize) !void {
    var stream = stream_in;
    defer stream.close(io);

    var send_buffer: [8192]u8 = undefined;
    var recv_buffer: [8192]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    var request = server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

    // request.head.target aliases the connection reader's buffer. Reading
    // the body below tosses/refills that same buffer, so target must be
    // copied out before any body read or its bytes get overwritten.
    const method = request.head.method;
    const target = try gpa.dupe(u8, request.head.target);
    defer gpa.free(target);

    // A request with neither content-length nor chunked transfer-encoding is
    // unframed — std.http's bodyReader falls back to the raw connection
    // reader in that case (reads until the peer closes), which would hang
    // against a keep-alive client still waiting on a response. Treat
    // unframed as "no body" instead of ever reading from that reader.
    const has_framed_body = request.head.content_length != null or
        request.head.transfer_encoding == .chunked;

    if (has_framed_body) {
        const body_reader = request.readerExpectContinue(&.{}) catch |err| {
            try request.respond("bad request", .{ .status = .bad_request, .keep_alive = false });
            return err;
        };
        const body = body_reader.allocRemaining(gpa, Io.Limit.limited(max_body_bytes)) catch {
            try request.respond("payload too large", .{ .status = .payload_too_large, .keep_alive = false });
            return;
        };
        gpa.free(body);
    }

    if (method == .GET and std.mem.eql(u8, target, "/")) {
        try request.respond(index_html, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
        return;
    }

    if (method == .POST and std.mem.eql(u8, target, "/api/ping")) {
        try request.respond("pong", .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
            },
        });
        return;
    }

    try request.respond("not found", .{ .status = .not_found, .keep_alive = false });
}
