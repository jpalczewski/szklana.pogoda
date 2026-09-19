//! Every metric the server exposes, declared once.
//!
//! `family.zig` holds the metric types; this file names each metric, gives it
//! its labels and collects them in `Registry`. Adding a metric means adding a
//! family type here and one field (with its `init`) to `Families`: `deinit` and
//! `render` walk the fields, so neither needs to learn about it.

const std = @import("std");
const Io = std.Io;

const family = @import("family.zig");

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

const HttpHeadErrorLabels = struct {
    reason: []const u8,
};

const HttpHeadErrors = family.Counter(
    "szklana_pogoda_http_head_errors_total",
    "Connections whose request head could not be read, by error.",
    HttpHeadErrorLabels,
);

/// How one poll of an IMGW product ended. `fresh` means nothing was
/// downloaded because the stored rows were recent enough; every other result
/// after `freshness_check_failed` is the stage at which a download failed.
pub const PollResult = enum {
    convert_failed,
    fetch_failed,
    fresh,
    freshness_check_failed,
    record_failed,
    save_failed,
    saved,
};

const PollLabels = struct {
    source: []const u8,
    result: PollResult,
};

const PollSourceLabels = struct {
    source: []const u8,
};

const PollTotal = family.Counter(
    "szklana_pogoda_poll_total",
    "Polls of an IMGW product, by source and how they ended.",
    PollLabels,
);

const PollDuration = family.Histogram(
    "szklana_pogoda_poll_duration_seconds",
    "Time a poll that went to the network spent downloading, decoding and storing, in seconds.",
    PollSourceLabels,
    &family.slow_bounds_ns,
);

const PollRecordsSaved = family.Counter(
    "szklana_pogoda_poll_records_saved_total",
    "Rows a poll wrote to the store.",
    PollSourceLabels,
);

const PollLastSuccess = family.Gauge(
    "szklana_pogoda_poll_last_success_timestamp_seconds",
    "Unix time at which the last successful poll of a source started.",
    PollSourceLabels,
);

/// The in-memory caches in front of an on-demand upstream.
pub const Cache = enum {
    forecast,
    storm,
};

pub const CacheResult = enum {
    hit,
    miss,
};

/// The on-demand upstreams. IMGW is polled, so it reports as `PollResult`.
pub const Upstream = enum {
    antistorm,
    openmeteo,
};

/// `network_error` is an endpoint that could not be reached or did not answer
/// 200; `invalid_data` is one that answered with something unusable.
pub const UpstreamResult = enum {
    invalid_data,
    network_error,
    succeeded,
};

const CacheLabels = struct {
    cache: Cache,
    result: CacheResult,
};

const UpstreamLabels = struct {
    upstream: Upstream,
    result: UpstreamResult,
};

const UpstreamNameLabels = struct {
    upstream: Upstream,
};

const CacheLookups = family.Counter(
    "szklana_pogoda_cache_lookups_total",
    "Lookups in an upstream response cache, by cache and whether they hit.",
    CacheLabels,
);

const UpstreamRequests = family.Counter(
    "szklana_pogoda_upstream_requests_total",
    "Requests to an on-demand upstream, by upstream and how they ended.",
    UpstreamLabels,
);

const UpstreamDuration = family.Histogram(
    "szklana_pogoda_upstream_request_duration_seconds",
    "Time spent downloading and decoding one upstream response, in seconds.",
    UpstreamNameLabels,
    &family.slow_bounds_ns,
);

const no_labels = struct {};

const ProcessResidentMemory = family.Gauge(
    "process_resident_memory_bytes",
    "Resident memory size of the process, in bytes.",
    no_labels,
);

const ProcessVirtualMemory = family.Gauge(
    "process_virtual_memory_bytes",
    "Virtual memory size of the process, in bytes.",
    no_labels,
);

const ProcessOwnMemory = family.Gauge(
    "szklana_pogoda_process_own_memory_bytes",
    "Memory the process owns, without the file-backed pages of its executable and libraries, in bytes.",
    no_labels,
);

/// Measures a span on the monotonic clock, in nanoseconds, so that a request
/// answered from memory does not read as zero.
pub const Timer = struct {
    started_at: Io.Timestamp,

    pub fn start(io: Io) Timer {
        return .{ .started_at = Io.Clock.awake.now(io) };
    }

    pub fn elapsedNs(self: Timer, io: Io) u64 {
        const elapsed = self.started_at.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
        return std.math.lossyCast(u64, elapsed);
    }
};

pub const Registry = struct {
    families: Families,

    /// Render order is field order.
    const Families = struct {
        http_requests: HttpRequests,
        http_in_flight: HttpInFlight,
        http_duration: HttpDuration,
        http_head_errors: HttpHeadErrors,
        poll_total: PollTotal,
        poll_duration: PollDuration,
        poll_records_saved: PollRecordsSaved,
        poll_last_success: PollLastSuccess,
        cache_lookups: CacheLookups,
        upstream_requests: UpstreamRequests,
        upstream_duration: UpstreamDuration,
        process_resident_memory: ProcessResidentMemory,
        process_virtual_memory: ProcessVirtualMemory,
        process_own_memory: ProcessOwnMemory,
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .families = .{
            .http_requests = .init(allocator),
            .http_in_flight = .init(allocator),
            .http_duration = .init(allocator),
            .http_head_errors = .init(allocator),
            .poll_total = .init(allocator),
            .poll_duration = .init(allocator),
            .poll_records_saved = .init(allocator),
            .poll_last_success = .init(allocator),
            .cache_lookups = .init(allocator),
            .upstream_requests = .init(allocator),
            .upstream_duration = .init(allocator),
            .process_resident_memory = .init(allocator),
            .process_virtual_memory = .init(allocator),
            .process_own_memory = .init(allocator),
        } };
    }

    pub fn deinit(self: *Registry) void {
        inline for (std.meta.fields(Families)) |field| @field(self.families, field.name).deinit();
        self.* = undefined;
    }

    /// Makes the series of a polled source exist before its first poll ends,
    /// with every counter at 0 and the last success at 0. A series that only
    /// appears once something happens cannot be alerted on: `time() -
    /// last_success` and `rate(errors)` both evaluate to nothing for a source
    /// that has never succeeded. At 0, "never" is an age of about the epoch.
    pub fn declarePollSource(self: *Registry, source: []const u8) void {
        inline for (std.enums.values(PollResult)) |result| {
            self.families.poll_total.declare(.{ .source = source, .result = result });
        }
        self.families.poll_records_saved.declare(.{ .source = source });
        self.families.poll_last_success.declare(.{ .source = source });
    }

    /// The same for the series whose labels are enums, so they are known
    /// without asking any module: the caches and the on-demand upstreams.
    pub fn declareUpstreams(self: *Registry) void {
        inline for (std.enums.values(Cache)) |cache| {
            inline for (std.enums.values(CacheResult)) |result| {
                self.families.cache_lookups.declare(.{ .cache = cache, .result = result });
            }
        }
        inline for (std.enums.values(Upstream)) |upstream| {
            inline for (std.enums.values(UpstreamResult)) |result| {
                self.families.upstream_requests.declare(.{ .upstream = upstream, .result = result });
            }
        }
    }

    /// The same for one reason of `headError`, which the listener knows.
    pub fn declareHeadError(self: *Registry, reason: []const u8) void {
        self.families.http_head_errors.declare(.{ .reason = reason });
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

    /// A connection whose request head was unreadable, so it never became a
    /// request with a route to count. `reason` is an error name.
    pub fn headError(self: *Registry, reason: []const u8) void {
        self.families.http_head_errors.inc(.{ .reason = reason });
    }

    /// One poll of `source` has ended. `took_ns` is how long it ran and
    /// `saved` how many rows it wrote, even when a later step failed;
    /// `started_at` is the epoch second the poll began, which is what a
    /// successful poll is dated by.
    pub fn poll(self: *Registry, source: []const u8, result: PollResult, took_ns: u64, saved: usize, started_at: u64) void {
        self.families.poll_total.inc(.{ .source = source, .result = result });
        switch (result) {
            // Nothing went to the network, so there is no duration to record.
            .fresh, .freshness_check_failed => return,
            else => {},
        }
        self.families.poll_duration.observe(.{ .source = source }, took_ns);
        if (saved > 0) self.families.poll_records_saved.add(.{ .source = source }, saved);
        if (result == .saved) self.families.poll_last_success.set(.{ .source = source }, started_at);
    }

    pub fn cacheLookup(self: *Registry, cache: Cache, result: CacheResult) void {
        self.families.cache_lookups.inc(.{ .cache = cache, .result = result });
    }

    /// One request to `upstream` has ended after `took_ns`.
    pub fn upstreamRequest(self: *Registry, upstream: Upstream, result: UpstreamResult, took_ns: u64) void {
        self.families.upstream_requests.inc(.{ .upstream = upstream, .result = result });
        self.families.upstream_duration.observe(.{ .upstream = upstream }, took_ns);
    }

    /// The process's memory as the kernel reports it now. Unlike the counters
    /// this is not recorded as things happen; the scrape reads it and sets it.
    pub fn setProcessMemory(self: *Registry, resident_bytes: u64, virtual_bytes: u64, own_bytes: u64) void {
        self.families.process_resident_memory.set(.{}, resident_bytes);
        self.families.process_virtual_memory.set(.{}, virtual_bytes);
        self.families.process_own_memory.set(.{}, own_bytes);
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

test "registry counts unreadable request heads by reason" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    registry.headError("HttpHeadersInvalid");
    registry.headError("HttpHeadersInvalid");

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_http_head_errors_total{reason=\"HttpHeadersInvalid\"} 2\n") != null);
}

test "declared series render at zero and are not changed by recording" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    registry.declarePollSource("meteo warning");
    registry.declareUpstreams();
    registry.declareHeadError("HttpHeadersInvalid");
    registry.poll("meteo warning", .saved, std.time.ns_per_s, 2, 1_000);
    registry.declarePollSource("meteo warning");

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    for ([_][]const u8{
        "szklana_pogoda_poll_total{source=\"meteo warning\",result=\"fetch_failed\"} 0\n",
        "szklana_pogoda_poll_total{source=\"meteo warning\",result=\"saved\"} 1\n",
        "szklana_pogoda_poll_records_saved_total{source=\"meteo warning\"} 2\n",
        "szklana_pogoda_poll_last_success_timestamp_seconds{source=\"meteo warning\"} 1000\n",
        "szklana_pogoda_http_head_errors_total{reason=\"HttpHeadersInvalid\"} 0\n",
        "szklana_pogoda_cache_lookups_total{cache=\"forecast\",result=\"miss\"} 0\n",
        "szklana_pogoda_upstream_requests_total{upstream=\"openmeteo\",result=\"network_error\"} 0\n",
    }) |expected| {
        try std.testing.expect(std.mem.find(u8, rendered, expected) != null);
    }
}

test "a declared source that never succeeded reports a last success of zero" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    registry.declarePollSource("hydro");
    registry.poll("hydro", .fetch_failed, std.time.ns_per_s, 0, 1_000);

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_poll_last_success_timestamp_seconds{source=\"hydro\"} 0\n") != null);
}

test "timer never runs backwards" {
    const timer: Timer = .start(std.testing.io);
    const first = timer.elapsedNs(std.testing.io);
    const second = timer.elapsedNs(std.testing.io);
    try std.testing.expect(second >= first);
    try std.testing.expect(second < std.time.ns_per_s);
}

test "registry records a poll by source and result" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    registry.poll("synop", .saved, 2 * std.time.ns_per_s, 60, 1_000);
    registry.poll("synop", .fresh, 10, 0, 1_100);
    registry.poll("hydro", .fetch_failed, 3 * std.time.ns_per_s, 0, 1_200);

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_poll_total{source=\"synop\",result=\"saved\"} 1\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_poll_total{source=\"synop\",result=\"fresh\"} 1\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_poll_total{source=\"hydro\",result=\"fetch_failed\"} 1\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_poll_records_saved_total{source=\"synop\"} 60\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_poll_last_success_timestamp_seconds{source=\"synop\"} 1000\n") != null);
    // A skipped poll is not a timed download, and a failed one is not a success.
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_poll_duration_seconds_count{source=\"synop\"} 1\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_poll_duration_seconds_count{source=\"hydro\"} 1\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "last_success_timestamp_seconds{source=\"hydro\"}") == null);
}

test "registry records cache lookups and upstream requests" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    registry.cacheLookup(.storm, .miss);
    registry.cacheLookup(.storm, .hit);
    registry.cacheLookup(.storm, .hit);
    registry.upstreamRequest(.antistorm, .succeeded, 200 * std.time.ns_per_ms);
    registry.upstreamRequest(.openmeteo, .network_error, 5 * std.time.ns_per_s);

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    for ([_][]const u8{
        "szklana_pogoda_cache_lookups_total{cache=\"storm\",result=\"miss\"} 1\n",
        "szklana_pogoda_cache_lookups_total{cache=\"storm\",result=\"hit\"} 2\n",
        "szklana_pogoda_upstream_requests_total{upstream=\"antistorm\",result=\"succeeded\"} 1\n",
        "szklana_pogoda_upstream_requests_total{upstream=\"openmeteo\",result=\"network_error\"} 1\n",
        "szklana_pogoda_upstream_request_duration_seconds_count{upstream=\"openmeteo\"} 1\n",
    }) |expected| {
        try std.testing.expect(std.mem.find(u8, rendered, expected) != null);
    }
}

test "registry renders the process memory gauges" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    registry.setProcessMemory(100, 300, 40);
    registry.setProcessMemory(110, 300, 45);

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "process_resident_memory_bytes 110\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "process_virtual_memory_bytes 300\n") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_process_own_memory_bytes 45\n") != null);
}
