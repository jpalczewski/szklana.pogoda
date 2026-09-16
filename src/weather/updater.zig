const std = @import("std");
const Io = std.Io;

const imgw = @import("../imgw/mod.zig");
const model = @import("model.zig");
const storage = @import("store.zig");
const warnings = @import("../warnings.zig");

/// What one poll pass hands to a source: the store being written, the product
/// label used in the log lines and the wall-clock reading the warning sources
/// stamp their rows with.
const Context = struct {
    store: *storage.Store,
    label: []const u8,
    seen_at: []const u8 = "",
};

/// One IMGW product wired for polling: how to fetch a batch, how to release it
/// and how to write it. Adding a product means adding one entry to a table
/// below, not another copy of the update loop.
fn Source(comptime Item: type) type {
    return struct {
        label: []const u8,
        fetch: *const fn (std.mem.Allocator, Io) imgw.Error![]Item,
        deinit: *const fn (std.mem.Allocator, []Item) void,
        record: *const fn ([]const Item, Context) anyerror!usize,
    };
}

/// Both measurement products normalize into `model.Observation`, so only the
/// fetch differs.
const measurement_sources = [_]Source(model.Observation){
    .{ .label = "synop", .fetch = &imgw.synop.fetch, .deinit = &model.deinitObservations, .record = &recordObservations },
    .{ .label = "meteo", .fetch = &imgw.meteo.fetch, .deinit = &model.deinitObservations, .record = &recordObservations },
};

const hydro_source: Source(model.HydroObservation) = .{
    .label = "hydro",
    .fetch = &imgw.hydro.fetch,
    .deinit = &model.deinitHydro,
    .record = &recordHydroObservations,
};

/// Warnings change independently of the measurements, so they run on their own
/// cadence and against their own sources.
const warning_sources = [_]Source(warnings.Warning){
    .{ .label = "meteo warning", .fetch = &imgw.warnings.meteo.fetch, .deinit = &warnings.deinitWarnings, .record = &recordWarningBatch },
    .{ .label = "hydro warning", .fetch = &imgw.warnings.hydro.fetch, .deinit = &warnings.deinitWarnings, .record = &recordWarningBatch },
};

pub fn run(allocator: std.mem.Allocator, io: Io, store: *storage.Store, interval_seconds: u64) void {
    while (true) {
        for (measurement_sources) |source| {
            poll(model.Observation, source, allocator, io, .{ .store = store, .label = source.label });
        }
        poll(model.HydroObservation, hydro_source, allocator, io, .{ .store = store, .label = hydro_source.label });
        sleep(io, interval_seconds) catch return;
    }
}

pub fn runWarnings(allocator: std.mem.Allocator, io: Io, store: *storage.Store, interval_seconds: u64) void {
    while (true) {
        updateWarnings(allocator, io, store);
        sleep(io, interval_seconds) catch return;
    }
}

fn updateWarnings(allocator: std.mem.Allocator, io: Io, store: *storage.Store) void {
    const seen_at = warnings.localNow(allocator, io) catch |err| {
        std.log.err("reading the wall clock failed: {t}", .{err});
        return;
    };
    defer allocator.free(seen_at);

    for (warning_sources) |source| {
        poll(warnings.Warning, source, allocator, io, .{ .store = store, .label = source.label, .seen_at = seen_at });
    }
}

/// One poll of one product: fetch, store, report. Each source is stored
/// independently so one failing endpoint does not hide the others.
fn poll(comptime Item: type, source: Source(Item), allocator: std.mem.Allocator, io: Io, context: Context) void {
    const items = source.fetch(allocator, io) catch |err| {
        std.log.err("IMGW {s} fetch failed: {t}", .{ context.label, err });
        return;
    };
    defer source.deinit(allocator, items);

    const saved = source.record(items, context) catch |err| {
        std.log.err("saving IMGW {s} failed: {t}", .{ context.label, err });
        return;
    };
    std.log.info("IMGW {s} update saved {d}/{d}", .{ context.label, saved, items.len });
}

/// A failing row is logged and skipped so a single bad station does not discard
/// the rest of the batch.
fn recordObservations(items: []const model.Observation, context: Context) anyerror!usize {
    var saved: usize = 0;
    for (items) |item| {
        context.store.record(item) catch |err| {
            std.log.err("saving IMGW {s} observation for {s} failed: {t}", .{ context.label, item.station_id, err });
            continue;
        };
        saved += 1;
    }
    return saved;
}

fn recordHydroObservations(items: []const model.HydroObservation, context: Context) anyerror!usize {
    var saved: usize = 0;
    for (items) |item| {
        context.store.recordHydro(item) catch |err| {
            std.log.err("saving IMGW {s} gauge {s} failed: {t}", .{ context.label, item.station_id, err });
            continue;
        };
        saved += 1;
    }
    return saved;
}

fn recordWarningBatch(items: []const warnings.Warning, context: Context) anyerror!usize {
    return context.store.recordWarnings(items, context.seen_at);
}

fn sleep(io: Io, interval_seconds: u64) !void {
    const duration: Io.Clock.Duration = .{
        .raw = Io.Duration.fromSeconds(@intCast(interval_seconds)),
        .clock = .awake,
    };
    return duration.sleep(io);
}
