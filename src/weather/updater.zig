const std = @import("std");
const Io = std.Io;

const imgw = @import("../imgw/mod.zig");
const warnings = @import("../warnings.zig");
const weather_store = @import("store.zig");

/// Both measurement products normalize into `weather_store.Observation`, so
/// only the fetch differs.
const ObservationProduct = enum { synop, meteo };

pub fn run(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store, interval_seconds: u64) void {
    while (true) {
        updateObservations(allocator, io, store, .synop);
        updateObservations(allocator, io, store, .meteo);
        updateHydro(allocator, io, store);
        sleep(io, interval_seconds) catch return;
    }
}

/// Warnings change independently of the measurements, so they run on their own
/// cadence and against their own endpoints.
pub fn runWarnings(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store, interval_seconds: u64) void {
    while (true) {
        updateWarnings(allocator, io, store);
        sleep(io, interval_seconds) catch return;
    }
}

fn updateObservations(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store, product: ObservationProduct) void {
    const fetched = switch (product) {
        .synop => imgw.synop.fetch(allocator, io),
        .meteo => imgw.meteo.fetch(allocator, io),
    };
    const observations = fetched catch |err| {
        std.log.err("IMGW {s} fetch failed: {t}", .{ @tagName(product), err });
        return;
    };
    defer weather_store.Store.deinitHistory(allocator, observations);

    var saved: usize = 0;
    for (observations) |observation| {
        store.record(observation) catch |err| {
            std.log.err("saving IMGW {s} observation for {s} failed: {t}", .{ @tagName(product), observation.station_id, err });
            continue;
        };
        saved += 1;
    }
    std.log.info("IMGW {s} update saved {d}/{d} observations", .{ @tagName(product), saved, observations.len });
}

fn updateHydro(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store) void {
    const stations = imgw.hydro.fetch(allocator, io) catch |err| {
        std.log.err("IMGW hydro fetch failed: {t}", .{err});
        return;
    };
    defer weather_store.Store.deinitHydro(allocator, stations);

    var saved: usize = 0;
    for (stations) |station| {
        store.recordHydro(station) catch |err| {
            std.log.err("saving IMGW hydro station {s} failed: {t}", .{ station.station_id, err });
            continue;
        };
        saved += 1;
    }
    std.log.info("IMGW hydro update saved {d}/{d} stations", .{ saved, stations.len });
}

fn updateWarnings(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store) void {
    const seen_at = warnings.localNow(allocator, io) catch |err| {
        std.log.err("reading the wall clock failed: {t}", .{err});
        return;
    };
    defer allocator.free(seen_at);

    storeWarnings(allocator, store, seen_at, "meteo", imgw.warnings.meteo.fetch(allocator, io));
    storeWarnings(allocator, store, seen_at, "hydro", imgw.warnings.hydro.fetch(allocator, io));
}

/// Each source is stored independently so one failing endpoint does not hide
/// the warnings of the other.
fn storeWarnings(
    allocator: std.mem.Allocator,
    store: *weather_store.Store,
    seen_at: []const u8,
    label: []const u8,
    fetched: imgw.Error![]weather_store.Warning,
) void {
    const items = fetched catch |err| {
        std.log.err("IMGW {s} warnings fetch failed: {t}", .{ label, err });
        return;
    };
    defer weather_store.Store.deinitWarnings(allocator, items);

    const saved = store.recordWarnings(items, seen_at) catch |err| {
        std.log.err("saving IMGW {s} warnings failed: {t}", .{ label, err });
        return;
    };
    std.log.info("IMGW {s} warnings update saved {d}/{d}", .{ label, saved, items.len });
}

fn sleep(io: Io, interval_seconds: u64) !void {
    const duration: Io.Clock.Duration = .{
        .raw = Io.Duration.fromSeconds(@intCast(interval_seconds)),
        .clock = .awake,
    };
    return duration.sleep(io);
}
