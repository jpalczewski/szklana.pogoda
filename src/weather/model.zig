//! The weather domain model.
//!
//! The types the IMGW sources map into and the store persists, with a single
//! ownership rule: every slice field is owned by the allocator that built it
//! and released by the matching `deinit` below.

const std = @import("std");

/// One measurement of a station at a point in time. `observed_at` is the
/// ISO-like UTC form the store keeps, for example `"2026-09-17T07:00:00Z"`.
pub const Observation = struct {
    station_id: []const u8,
    station_name: []const u8,
    observed_at: []const u8,
    temperature_c: ?f64,
    wind_speed_m_s: ?f64,
    wind_direction_deg: ?i16,
    relative_humidity_percent: ?f64,
    precipitation_mm: ?f64,
    pressure_hpa: ?f64,
};

/// A station with its newest observation time, as the stations listing reports
/// it.
pub const Station = struct {
    station_id: []const u8,
    station_name: []const u8,
    last_observed_at: []const u8,
};

/// A river gauge with its newest measurement, the station's alarm thresholds
/// and the classification of the current level against them.
pub const HydroStation = struct {
    station_id: []const u8,
    station_name: []const u8,
    river: []const u8,
    voivodeship: []const u8,
    longitude: ?f64,
    latitude: ?f64,
    founded_year: ?i32,
    gauge_zero_m: ?f64,
    river_km: ?f64,
    warning_level_cm: ?f64,
    alarm_level_cm: ?f64,
    water_level_cm: ?f64,
    water_level_observed_at: ?[]const u8,
    water_temperature_c: ?f64,
    water_temperature_observed_at: ?[]const u8,
    flow_m3_s: ?f64,
    flow_observed_at: ?[]const u8,
    ice_phenomenon: ?i32,
    ice_phenomenon_observed_at: ?[]const u8,
    overgrowth_phenomenon: ?i32,
    overgrowth_phenomenon_observed_at: ?[]const u8,
    water_level_status: []const u8,
};

/// The same gauge reading, named for the history endpoints that return a series
/// of them.
pub const HydroObservation = HydroStation;

pub fn deinitObservations(allocator: std.mem.Allocator, items: []Observation) void {
    deinitObservationItems(allocator, items);
    allocator.free(items);
}

/// Releases the items of a decoded slice without releasing the slice itself, so
/// a decoder can clean up a partial batch.
pub fn deinitObservationItems(allocator: std.mem.Allocator, items: []Observation) void {
    for (items) |item| {
        allocator.free(item.station_id);
        allocator.free(item.station_name);
        allocator.free(item.observed_at);
    }
}

pub fn deinitStations(allocator: std.mem.Allocator, items: []Station) void {
    for (items) |item| {
        allocator.free(item.station_id);
        allocator.free(item.station_name);
        allocator.free(item.last_observed_at);
    }
    allocator.free(items);
}

/// Releases the items of a decoded batch without releasing the slice itself, so
/// a decoder can clean up a partial batch.
pub fn deinitHydroItems(allocator: std.mem.Allocator, items: []HydroObservation) void {
    for (items) |item| {
        allocator.free(item.station_id);
        allocator.free(item.station_name);
        allocator.free(item.river);
        allocator.free(item.voivodeship);
        allocator.free(item.water_level_status);
        inline for (.{ "water_level_observed_at", "water_temperature_observed_at", "flow_observed_at", "ice_phenomenon_observed_at", "overgrowth_phenomenon_observed_at" }) |field| {
            if (@field(item, field)) |value| allocator.free(value);
        }
    }
}

pub fn deinitHydro(allocator: std.mem.Allocator, items: []HydroObservation) void {
    deinitHydroItems(allocator, items);
    allocator.free(items);
}
