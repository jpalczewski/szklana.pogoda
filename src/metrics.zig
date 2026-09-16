const std = @import("std");

const buckets = [_]struct { label: []const u8, nanoseconds: u64 }{
    .{ .label = "0.005", .nanoseconds = 5 * std.time.ns_per_ms },
    .{ .label = "0.01", .nanoseconds = 10 * std.time.ns_per_ms },
    .{ .label = "0.025", .nanoseconds = 25 * std.time.ns_per_ms },
    .{ .label = "0.05", .nanoseconds = 50 * std.time.ns_per_ms },
    .{ .label = "0.1", .nanoseconds = 100 * std.time.ns_per_ms },
    .{ .label = "0.25", .nanoseconds = 250 * std.time.ns_per_ms },
    .{ .label = "0.5", .nanoseconds = 500 * std.time.ns_per_ms },
    .{ .label = "1", .nanoseconds = std.time.ns_per_s },
    .{ .label = "2.5", .nanoseconds = 2500 * std.time.ns_per_ms },
    .{ .label = "5", .nanoseconds = 5 * std.time.ns_per_s },
    .{ .label = "10", .nanoseconds = 10 * std.time.ns_per_s },
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    in_flight: std.ArrayList(InFlight) = .empty,
    series: std.ArrayList(Series) = .empty,

    const InFlight = struct {
        method: []const u8,
        route: []const u8,
        count: u64 = 0,
    };

    const Series = struct {
        method: []const u8,
        route: []const u8,
        status: u16,
        requests: u64 = 0,
        duration_sum_ns: u64 = 0,
        duration_buckets: [buckets.len]u64 = [_]u64{0} ** buckets.len,
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.in_flight.deinit(self.allocator);
        self.series.deinit(self.allocator);
    }

    pub fn begin(self: *Registry, method: []const u8, route: []const u8) void {
        self.lock();
        defer self.unlock();

        const item = self.findOrCreateInFlight(method, route) catch return;
        item.count +|= 1;
    }

    pub fn finish(self: *Registry, method: []const u8, route: []const u8, status: u16, duration_ns: u64) void {
        self.lock();
        defer self.unlock();

        const item = self.findOrCreateSeries(method, route, status) catch return;
        item.requests +|= 1;
        item.duration_sum_ns +|= duration_ns;
        for (buckets, 0..) |bucket, index| {
            if (duration_ns <= bucket.nanoseconds) item.duration_buckets[index] +|= 1;
        }
    }

    pub fn end(self: *Registry, method: []const u8, route: []const u8) void {
        self.lock();
        defer self.unlock();

        if (self.findInFlight(method, route)) |item| item.count -|= 1;
    }

    pub fn render(self: *Registry, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        self.lock();
        defer self.unlock();

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        try output.appendSlice(
            allocator,
            "# HELP szklana_pogoda_http_requests_total Total completed HTTP requests.\n" ++
                "# TYPE szklana_pogoda_http_requests_total counter\n",
        );
        for (self.series.items) |item| {
            try appendLine(&output, allocator, "szklana_pogoda_http_requests_total{{method=\"{s}\",route=\"{s}\",status=\"{d}\"}} {d}\n", .{ item.method, item.route, item.status, item.requests });
        }

        try output.appendSlice(
            allocator,
            "# HELP szklana_pogoda_http_in_flight_requests HTTP requests currently being handled.\n" ++
                "# TYPE szklana_pogoda_http_in_flight_requests gauge\n",
        );
        for (self.in_flight.items) |item| {
            try appendLine(&output, allocator, "szklana_pogoda_http_in_flight_requests{{method=\"{s}\",route=\"{s}\"}} {d}\n", .{ item.method, item.route, item.count });
        }

        try output.appendSlice(
            allocator,
            "# HELP szklana_pogoda_http_request_duration_seconds HTTP request duration in seconds.\n" ++
                "# TYPE szklana_pogoda_http_request_duration_seconds histogram\n",
        );
        for (self.series.items) |item| {
            for (buckets, 0..) |bucket, index| {
                try appendLine(&output, allocator, "szklana_pogoda_http_request_duration_seconds_bucket{{method=\"{s}\",route=\"{s}\",status=\"{d}\",le=\"{s}\"}} {d}\n", .{ item.method, item.route, item.status, bucket.label, item.duration_buckets[index] });
            }
            try appendLine(&output, allocator, "szklana_pogoda_http_request_duration_seconds_bucket{{method=\"{s}\",route=\"{s}\",status=\"{d}\",le=\"+Inf\"}} {d}\n", .{ item.method, item.route, item.status, item.requests });
            const duration_seconds: f64 = @as(f64, @floatFromInt(item.duration_sum_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
            try appendLine(&output, allocator, "szklana_pogoda_http_request_duration_seconds_sum{{method=\"{s}\",route=\"{s}\",status=\"{d}\"}} {d}\n", .{ item.method, item.route, item.status, duration_seconds });
            try appendLine(&output, allocator, "szklana_pogoda_http_request_duration_seconds_count{{method=\"{s}\",route=\"{s}\",status=\"{d}\"}} {d}\n", .{ item.method, item.route, item.status, item.requests });
        }

        return try output.toOwnedSlice(allocator);
    }

    fn findInFlight(self: *Registry, method: []const u8, route: []const u8) ?*InFlight {
        for (self.in_flight.items) |*item| {
            if (std.mem.eql(u8, item.method, method) and std.mem.eql(u8, item.route, route)) return item;
        }
        return null;
    }

    fn findOrCreateInFlight(self: *Registry, method: []const u8, route: []const u8) std.mem.Allocator.Error!*InFlight {
        if (self.findInFlight(method, route)) |item| return item;
        try self.in_flight.append(self.allocator, .{ .method = method, .route = route });
        return &self.in_flight.items[self.in_flight.items.len - 1];
    }

    fn findOrCreateSeries(self: *Registry, method: []const u8, route: []const u8, status: u16) std.mem.Allocator.Error!*Series {
        for (self.series.items) |*item| {
            if (item.status == status and std.mem.eql(u8, item.method, method) and std.mem.eql(u8, item.route, route)) return item;
        }
        try self.series.append(self.allocator, .{ .method = method, .route = route, .status = status });
        return &self.series.items[self.series.items.len - 1];
    }

    fn lock(self: *Registry) void {
        while (!self.mutex.tryLock()) {}
    }

    fn unlock(self: *Registry) void {
        self.mutex.unlock();
    }
};

fn appendLine(output: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) std.mem.Allocator.Error!void {
    var buffer: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    try output.appendSlice(allocator, line);
}

test "registry renders Prometheus counters and histogram" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    registry.begin("GET", "/");
    registry.finish("GET", "/", 200, 10 * std.time.ns_per_ms);
    registry.end("GET", "/");

    const rendered = try registry.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "# TYPE szklana_pogoda_http_requests_total counter\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "szklana_pogoda_http_requests_total{method=\"GET\",route=\"/\",status=\"200\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "le=\"0.005\"} 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "le=\"0.01\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "le=\"+Inf\"} 1\n") != null);
}
