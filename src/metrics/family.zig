//! The metric types behind `metrics.Registry`.
//!
//! A family is one metric name with its help text, its kind and a set of
//! series, one per distinct combination of label values. A family is declared
//! by its name, its help and a struct whose fields are the labels:
//!
//! ```
//! const Requests = Counter("app_requests_total", "Completed requests.", struct {
//!     route: []const u8,
//!     status: u16,
//! });
//! ```
//!
//! The label names come from the fields, so a call site cannot misspell one or
//! leave one out, and rendering needs no per-metric code. A field is a string,
//! an integer or an enum (printed by tag name). An empty struct declares a
//! metric with no labels.
//!
//! The strings behind label values are borrowed, not copied: they have to
//! outlive the family. Every caller passes something static (a route table
//! entry, a tag name, a source label), which is also what keeps the number of
//! series bounded. Nothing here escapes a label value, so an unbounded or
//! user-controlled string does not belong in a label.
//!
//! Recording never fails the caller. A series that cannot be allocated is
//! dropped, because a metric must not turn into an error for the request or
//! the poll it measures.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Upper bounds, in nanoseconds, of the latency histogram buckets: 5 ms to 10 s,
/// the default Prometheus client buckets.
pub const latency_bounds_ns = [_]u64{
    5 * std.time.ns_per_ms,
    10 * std.time.ns_per_ms,
    25 * std.time.ns_per_ms,
    50 * std.time.ns_per_ms,
    100 * std.time.ns_per_ms,
    250 * std.time.ns_per_ms,
    500 * std.time.ns_per_ms,
    std.time.ns_per_s,
    2500 * std.time.ns_per_ms,
    5 * std.time.ns_per_s,
    10 * std.time.ns_per_s,
};

/// Upper bounds, in nanoseconds, for operations that move real data over the
/// network: 100 ms to a minute.
pub const slow_bounds_ns = [_]u64{
    100 * std.time.ns_per_ms,
    250 * std.time.ns_per_ms,
    500 * std.time.ns_per_ms,
    std.time.ns_per_s,
    2500 * std.time.ns_per_ms,
    5 * std.time.ns_per_s,
    10 * std.time.ns_per_s,
    30 * std.time.ns_per_s,
    60 * std.time.ns_per_s,
};

/// A value that only goes up.
pub fn Counter(comptime name: []const u8, comptime help: []const u8, comptime Labels: type) type {
    const Base = Family(name, help, "counter", Labels, CounterData);
    return struct {
        base: Base,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{ .base = .init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.base.deinit();
        }

        pub fn add(self: *Self, labels: Labels, amount: u64) void {
            self.base.lock();
            defer self.base.unlock();
            const series = self.base.findOrCreate(labels) catch return;
            series.data.value +|= amount;
        }

        pub fn inc(self: *Self, labels: Labels) void {
            self.add(labels, 1);
        }

        pub fn render(self: *Self, writer: *Io.Writer) Io.Writer.Error!void {
            return self.base.render(writer);
        }
    };
}

/// A value that is set or moves in both directions but never below zero: a
/// count of requests in flight, a timestamp, a size.
pub fn Gauge(comptime name: []const u8, comptime help: []const u8, comptime Labels: type) type {
    const Base = Family(name, help, "gauge", Labels, GaugeData);
    return struct {
        base: Base,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{ .base = .init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.base.deinit();
        }

        pub fn set(self: *Self, labels: Labels, value: u64) void {
            self.base.lock();
            defer self.base.unlock();
            const series = self.base.findOrCreate(labels) catch return;
            series.data.value = value;
        }

        pub fn inc(self: *Self, labels: Labels) void {
            self.base.lock();
            defer self.base.unlock();
            const series = self.base.findOrCreate(labels) catch return;
            series.data.value +|= 1;
        }

        /// Lowers a series that exists and does nothing for one that does not:
        /// a decrement whose matching increment was dropped (out of memory)
        /// must not create a series or wrap around.
        pub fn dec(self: *Self, labels: Labels) void {
            self.base.lock();
            defer self.base.unlock();
            if (self.base.find(labels)) |series| series.data.value -|= 1;
        }

        pub fn render(self: *Self, writer: *Io.Writer) Io.Writer.Error!void {
            return self.base.render(writer);
        }
    };
}

/// A distribution of durations with the given cumulative bucket upper bounds
/// in nanoseconds. It renders in seconds, which is what Prometheus expects.
pub fn Histogram(
    comptime name: []const u8,
    comptime help: []const u8,
    comptime Labels: type,
    comptime bounds_ns: []const u64,
) type {
    const Base = Family(name, help, "histogram", Labels, HistogramData(bounds_ns));
    return struct {
        base: Base,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{ .base = .init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.base.deinit();
        }

        pub fn observe(self: *Self, labels: Labels, duration_ns: u64) void {
            self.base.lock();
            defer self.base.unlock();
            const series = self.base.findOrCreate(labels) catch return;
            series.data.count +|= 1;
            series.data.sum_ns +|= duration_ns;
            for (bounds_ns, 0..) |bound, index| {
                if (duration_ns <= bound) series.data.buckets[index] +|= 1;
            }
        }

        pub fn render(self: *Self, writer: *Io.Writer) Io.Writer.Error!void {
            return self.base.render(writer);
        }
    };
}

/// What every kind shares: the series list, its lock and the header lines.
/// `Data` is one series' numbers and knows how to print them.
fn Family(
    comptime name: []const u8,
    comptime help: []const u8,
    comptime kind: []const u8,
    comptime Labels: type,
    comptime Data: type,
) type {
    return struct {
        allocator: Allocator,
        mutex: std.atomic.Mutex = .unlocked,
        series: std.ArrayList(Series) = .empty,

        const Self = @This();

        const Series = struct {
            labels: Labels,
            data: Data = .{},
        };

        fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *Self) void {
            self.series.deinit(self.allocator);
            self.* = undefined;
        }

        /// The critical sections are a few additions, so waiting is a spin.
        fn lock(self: *Self) void {
            while (!self.mutex.tryLock()) {}
        }

        fn unlock(self: *Self) void {
            self.mutex.unlock();
        }

        /// The caller holds the lock.
        fn find(self: *Self, labels: Labels) ?*Series {
            for (self.series.items) |*series| {
                if (labelsEqual(Labels, series.labels, labels)) return series;
            }
            return null;
        }

        /// The caller holds the lock.
        fn findOrCreate(self: *Self, labels: Labels) Allocator.Error!*Series {
            if (self.find(labels)) |series| return series;
            try self.series.append(self.allocator, .{ .labels = labels });
            return &self.series.items[self.series.items.len - 1];
        }

        fn render(self: *Self, writer: *Io.Writer) Io.Writer.Error!void {
            self.lock();
            defer self.unlock();

            try writer.print("# HELP {s} {s}\n# TYPE {s} {s}\n", .{ name, help, name, kind });
            for (self.series.items) |series| try series.data.write(writer, name, Labels, series.labels);
        }
    };
}

const CounterData = struct {
    value: u64 = 0,

    fn write(self: CounterData, writer: *Io.Writer, comptime name: []const u8, comptime Labels: type, labels: Labels) Io.Writer.Error!void {
        try writer.writeAll(name);
        try writeLabels(writer, Labels, labels, null);
        try writer.print(" {d}\n", .{self.value});
    }
};

const GaugeData = struct {
    value: u64 = 0,

    fn write(self: GaugeData, writer: *Io.Writer, comptime name: []const u8, comptime Labels: type, labels: Labels) Io.Writer.Error!void {
        try writer.writeAll(name);
        try writeLabels(writer, Labels, labels, null);
        try writer.print(" {d}\n", .{self.value});
    }
};

/// One histogram series: the cumulative bucket counts, then the `+Inf` bucket,
/// the sum and the count, in the order Prometheus documents.
fn HistogramData(comptime bounds_ns: []const u64) type {
    return struct {
        count: u64 = 0,
        sum_ns: u64 = 0,
        buckets: [bounds_ns.len]u64 = [_]u64{0} ** bounds_ns.len,

        fn write(self: @This(), writer: *Io.Writer, comptime name: []const u8, comptime Labels: type, labels: Labels) Io.Writer.Error!void {
            inline for (bounds_ns, 0..) |bound, index| {
                try writer.writeAll(name ++ "_bucket");
                try writeLabels(writer, Labels, labels, .{ .seconds = nanosecondsToSeconds(bound) });
                try writer.print(" {d}\n", .{self.buckets[index]});
            }
            try writer.writeAll(name ++ "_bucket");
            try writeLabels(writer, Labels, labels, .inf);
            try writer.print(" {d}\n", .{self.count});

            const sum_seconds = nanosecondsToSeconds(self.sum_ns);
            try writer.writeAll(name ++ "_sum");
            try writeLabels(writer, Labels, labels, null);
            try writer.print(" {d}\n", .{sum_seconds});
            try writer.writeAll(name ++ "_count");
            try writeLabels(writer, Labels, labels, null);
            try writer.print(" {d}\n", .{self.count});
        }
    };
}

/// A histogram bucket's `le` label: a bound in seconds, or the catch-all.
const BucketBound = union(enum) {
    inf,
    seconds: f64,
};

fn nanosecondsToSeconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / @as(f64, @floatFromInt(std.time.ns_per_s));
}

/// Prints `{name="value",...}`, with a trailing `le` label for a histogram
/// bucket, or nothing at all for a series that has no labels.
fn writeLabels(writer: *Io.Writer, comptime Labels: type, labels: Labels, le: ?BucketBound) Io.Writer.Error!void {
    const fields = @typeInfo(Labels).@"struct".fields;
    if (fields.len == 0 and le == null) return;

    try writer.writeByte('{');
    inline for (fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{s}=\"" ++ labelSpec(field.type) ++ "\"", .{ field.name, @field(labels, field.name) });
    }
    if (le) |bound| {
        if (fields.len != 0) try writer.writeByte(',');
        switch (bound) {
            .seconds => |seconds| try writer.print("le=\"{d}\"", .{seconds}),
            .inf => try writer.writeAll("le=\"+Inf\""),
        }
    }
    try writer.writeByte('}');
}

/// The format specifier that prints one label field: text as is, integers in
/// decimal, enums by tag name.
fn labelSpec(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .pointer => "{s}",
        .int => "{d}",
        .@"enum" => "{t}",
        else => @compileError("a metric label has to be a string, an integer or an enum, not " ++ @typeName(T)),
    };
}

fn labelsEqual(comptime Labels: type, a: Labels, b: Labels) bool {
    inline for (@typeInfo(Labels).@"struct".fields) |field| {
        const left = @field(a, field.name);
        const right = @field(b, field.name);
        const same = switch (@typeInfo(field.type)) {
            .pointer => std.mem.eql(u8, left, right),
            else => left == right,
        };
        if (!same) return false;
    }
    return true;
}

fn renderToOwned(family: anytype) ![]u8 {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try family.render(&out.writer);
    return out.toOwnedSlice();
}

test "counter renders its labels in declaration order" {
    var requests: Counter("app_requests_total", "Completed requests.", struct { route: []const u8, status: u16 }) = .init(std.testing.allocator);
    defer requests.deinit();

    requests.inc(.{ .route = "/", .status = 200 });
    requests.inc(.{ .route = "/", .status = 200 });
    requests.add(.{ .route = "/api", .status = 404 }, 5);

    const text = try renderToOwned(&requests);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "# HELP app_requests_total Completed requests.\n" ++
            "# TYPE app_requests_total counter\n" ++
            "app_requests_total{route=\"/\",status=\"200\"} 2\n" ++
            "app_requests_total{route=\"/api\",status=\"404\"} 5\n",
        text,
    );
}

test "label values match by content, not by address" {
    var counter: Counter("app_total", "Total.", struct { name: []const u8 }) = .init(std.testing.allocator);
    defer counter.deinit();

    var buffer = [_]u8{ 'a', 'b' };
    counter.inc(.{ .name = "ab" });
    counter.inc(.{ .name = buffer[0..] });

    try std.testing.expectEqual(@as(usize, 1), counter.base.series.items.len);
    try std.testing.expectEqual(@as(u64, 2), counter.base.series.items[0].data.value);
}

test "a family without labels renders a bare sample" {
    var gauge: Gauge("app_memory_bytes", "Memory.", struct {}) = .init(std.testing.allocator);
    defer gauge.deinit();

    gauge.set(.{}, 1234);

    const text = try renderToOwned(&gauge);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "# HELP app_memory_bytes Memory.\n# TYPE app_memory_bytes gauge\napp_memory_bytes 1234\n",
        text,
    );
}

test "an enum label prints its tag name" {
    const Result = enum { fetch_failed, saved };
    var counter: Counter("app_polls_total", "Polls.", struct { result: Result }) = .init(std.testing.allocator);
    defer counter.deinit();

    counter.inc(.{ .result = .fetch_failed });

    const text = try renderToOwned(&counter);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "app_polls_total{result=\"fetch_failed\"} 1\n") != null);
}

test "a gauge decrement never creates a series or goes below zero" {
    var gauge: Gauge("app_in_flight", "In flight.", struct { route: []const u8 }) = .init(std.testing.allocator);
    defer gauge.deinit();

    gauge.dec(.{ .route = "/" });
    try std.testing.expectEqual(@as(usize, 0), gauge.base.series.items.len);

    gauge.inc(.{ .route = "/" });
    gauge.dec(.{ .route = "/" });
    gauge.dec(.{ .route = "/" });
    try std.testing.expectEqual(@as(u64, 0), gauge.base.series.items[0].data.value);
}

test "histogram buckets are cumulative and end with +Inf, sum and count" {
    const bounds = [_]u64{ 10 * std.time.ns_per_ms, std.time.ns_per_s, 2500 * std.time.ns_per_ms };
    var latency: Histogram("app_seconds", "Latency.", struct { route: []const u8 }, &bounds) = .init(std.testing.allocator);
    defer latency.deinit();

    latency.observe(.{ .route = "/" }, 5 * std.time.ns_per_ms);
    latency.observe(.{ .route = "/" }, 2 * std.time.ns_per_s);

    const text = try renderToOwned(&latency);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "# HELP app_seconds Latency.\n" ++
            "# TYPE app_seconds histogram\n" ++
            "app_seconds_bucket{route=\"/\",le=\"0.01\"} 1\n" ++
            "app_seconds_bucket{route=\"/\",le=\"1\"} 1\n" ++
            "app_seconds_bucket{route=\"/\",le=\"2.5\"} 2\n" ++
            "app_seconds_bucket{route=\"/\",le=\"+Inf\"} 2\n" ++
            "app_seconds_sum{route=\"/\"} 2.005\n" ++
            "app_seconds_count{route=\"/\"} 2\n",
        text,
    );
}

test "the latency bounds print as Prometheus's default bucket labels" {
    var latency: Histogram("app_seconds", "Latency.", struct {}, &latency_bounds_ns) = .init(std.testing.allocator);
    defer latency.deinit();
    latency.observe(.{}, 1);

    const text = try renderToOwned(&latency);
    defer std.testing.allocator.free(text);
    for ([_][]const u8{ "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2.5", "5", "10", "+Inf" }) |label| {
        var expected: [48]u8 = undefined;
        const line = try std.fmt.bufPrint(&expected, "app_seconds_bucket{{le=\"{s}\"}} 1\n", .{label});
        try std.testing.expect(std.mem.find(u8, text, line) != null);
    }
}
