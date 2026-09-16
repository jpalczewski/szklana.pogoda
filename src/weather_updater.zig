const std = @import("std");
const Io = std.Io;

const imgw_client = @import("imgw_client.zig");
const imgw_warnings = @import("imgw_warnings.zig");
const warnings = @import("warnings.zig");
const weather_store = @import("weather_store.zig");

pub const default_url = "https://danepubliczne.imgw.pl/api/data/synop";
pub const meteo_url = "https://danepubliczne.imgw.pl/api/data/meteo/";
// IMGW's documented URL is HTTP, but it redirects to HTTPS; use the final
// URL because the Zig HTTP client cannot follow that redirect safely here.
pub const hydro_url = "https://danepubliczne.imgw.pl/api/data/hydro/";
pub const warnings_meteo_url = "https://danepubliczne.imgw.pl/api/data/warningsmeteo";
pub const warnings_hydro_url = "https://danepubliczne.imgw.pl/api/data/warningshydro";

pub fn updateOnce(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store, url: []const u8) void {
    const observations = imgw_client.fetch(allocator, io, url) catch |err| {
        std.log.err("IMGW fetch failed: {t}", .{err});
        return;
    };
    defer weather_store.Store.deinitHistory(allocator, observations);

    var saved: usize = 0;
    for (observations) |observation| {
        store.record(observation) catch |err| {
            std.log.err("saving IMGW observation for {s} failed: {t}", .{ observation.station_id, err });
            continue;
        };
        saved += 1;
    }
    std.log.info("IMGW update saved {d}/{d} observations", .{ saved, observations.len });
}

pub fn updateMeteoOnce(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store) void {
    updateOnce(allocator, io, store, meteo_url);
}

pub fn updateHydroOnce(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store) void {
    const stations = imgw_client.fetchHydro(allocator, io, hydro_url) catch |err| {
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

pub fn run(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store, url: []const u8, interval_seconds: u64) void {
    while (true) {
        updateOnce(allocator, io, store, url);
        updateMeteoOnce(allocator, io, store);
        updateHydroOnce(allocator, io, store);
        sleep(io, interval_seconds) catch return;
    }
}

/// Warnings change independently of the measurements, so they run on their own
/// cadence and against their own endpoints.
pub fn runWarnings(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store, interval_seconds: u64) void {
    while (true) {
        updateWarningsOnce(allocator, io, store);
        sleep(io, interval_seconds) catch return;
    }
}

pub fn updateWarningsOnce(allocator: std.mem.Allocator, io: Io, store: *weather_store.Store) void {
    const seen_at = warnings.localNow(allocator, io) catch |err| {
        std.log.err("reading the wall clock failed: {t}", .{err});
        return;
    };
    defer allocator.free(seen_at);

    storeWarnings(allocator, store, seen_at, "meteo", imgw_warnings.fetchMeteo(allocator, io, warnings_meteo_url));
    storeWarnings(allocator, store, seen_at, "hydro", imgw_warnings.fetchHydro(allocator, io, warnings_hydro_url));
}

/// Each source is stored independently so one failing endpoint does not hide
/// the warnings of the other.
fn storeWarnings(
    allocator: std.mem.Allocator,
    store: *weather_store.Store,
    seen_at: []const u8,
    label: []const u8,
    fetched: imgw_warnings.Error![]weather_store.Warning,
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
