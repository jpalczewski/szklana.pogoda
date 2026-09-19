//! Every metric the server exposes, declared once.
//!
//! `family.zig` holds the metric types; this file names each metric, gives it
//! its labels and collects them in `Registry`. Adding a metric means adding a
//! family type here and one field (with its `init`) to `Families`: `deinit` and
//! `render` walk the fields, so neither needs to learn about it.

const std = @import("std");
const Io = std.Io;

const family = @import("metrics/family.zig");

const HttpRequestLabels = struct {
    method: []const u8,
    route: []const u8,
    status: u16,
};

const HttpRouteLabels = struct {
    method: []const u8,
    route: []const u8,
};

const HttpRequests = family.Counter(
    "szklana_pogoda_http_requests_total",
    "Total completed HTTP requests.",
    HttpRequestLabels,
);

const HttpInFlight = family.Gauge(
    "szklana_pogoda_http_in_flight_requests",
    "HTTP requests currently being handled.",
    HttpRouteLabels,
);

const HttpDuration = family.Histogram(
    "szklana_pogoda_http_request_duration_seconds",
    "HTTP request duration in seconds.",
    HttpRequestLabels,
    &family.latency_bounds_ns,
);

pub const Registry = struct {
    families: Families,

    /// Render order is field order.
    const Families = struct {
        http_requests: HttpRequests,
        http_in_flight: HttpInFlight,
        http_duration: HttpDuration,
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .families = .{
            .http_requests = .init(allocator),
            .http_in_flight = .init(allocator),
            .http_duration = .init(allocator),
        } };
    }

    pub fn deinit(self: *Registry) void {
        inline for (std.meta.fields(Families)) |field| @field(self.families, field.name).deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Registry, method: []const u8, route: []const u8) void {
        self.families.http_in_flight.inc(.{ .method = method, .route = route });
    }

    pub fn finish(self: *Registry, method: []const u8, route: []const u8, status: u16, duration_ns: u64) void {
        const labels: HttpRequestLabels = .{ .method = method, .route = route, .status = status };
        self.families.http_requests.inc(labels);
        self.families.http_duration.observe(labels, duration_ns);
    }

    pub fn end(self: *Registry, method: []const u8, route: []const u8) void {
        self.families.http_in_flight.dec(.{ .method = method, .route = route });
    }

    /// Writes every family in the Prometheus text format.
    pub fn render(self: *Registry, writer: *Io.Writer) Io.Writer.Error!void {
        inline for (std.meta.fields(Families)) |field| try @field(self.families, field.name).render(writer);
    }

    /// `render` into memory owned by the caller.
    pub fn renderAlloc(self: *Registry, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        // An allocating writer fails only when it runs out of memory.
        self.render(&output.writer) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }
};

test "registry renders Prometheus counters and histogram" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    registry.begin("GET", "/");
    registry.finish("GET", "/", 200, 10 * std.time.ns_per_ms);
    registry.end("GET", "/");

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "# TYPE szklana_pogoda_http_requests_total counter\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_http_requests_total{method=\"GET\",route=\"/\",status=\"200\"} 1\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "le=\"0.005\"} 0\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "le=\"0.01\"} 1\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "le=\"+Inf\"} 1\n") != null);
}

test "registry keeps the in-flight gauge at zero after the request ends" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    registry.begin("GET", "/");
    registry.end("GET", "/");

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_http_in_flight_requests{method=\"GET\",route=\"/\"} 0\n") != null);
}
