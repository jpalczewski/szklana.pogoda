const std = @import("std");
const Io = std.Io;

const imgw_client = @import("imgw_client.zig");
const weather_store = @import("weather_store.zig");

pub const default_url = "https://danepubliczne.imgw.pl/api/data/synop";
pub const meteo_url = "https://danepubliczne.imgw.pl/api/data/meteo/";
// IMGW's documented URL is HTTP, but it redirects to HTTPS; use the final
// URL because the Zig HTTP client cannot follow that redirect safely here.
pub const hydro_url = "https://danepubliczne.imgw.pl/api/data/hydro/";

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
        const duration: Io.Clock.Duration = .{
            .raw = Io.Duration.fromSeconds(@intCast(interval_seconds)),
            .clock = .awake,
        };
        duration.sleep(io) catch return;
    }
}
