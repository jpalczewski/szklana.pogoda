//! The weather domain model.
//!
//! The types the IMGW sources map into and the store persists, with a single
//! ownership rule: every slice field is owned by the allocator that built it
//! and released by the matching `deinit` below.

const std = @import("std");

/// The measurement products that share the observation table, named exactly as
/// the `source_state` labels, the stored `source` column and the API's
/// `?source=` filter spell them. Both are measurement products, so they stay
/// out of the domain types and are only a label on the stored row.
pub const observation_source_labels = [_][]const u8{ "synop", "meteo" };

pub fn isObservationSource(value: []const u8) bool {
    for (observation_source_labels) |label| {
        if (std.mem.eql(u8, label, value)) return true;
    }
    return false;
}

/// One measurement of a station at a point in time. `observed_at` is the
/// ISO-like UTC form the store keeps, for example `"2026-09-17T07:00:00Z"`.
/// The coordinates are the station's position as the product published it;
/// products that publish none leave both null.
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
    longitude: ?f64 = null,
    latitude: ?f64 = null,
};

/// A station with its newest observation time, as the stations listing reports
/// it. The coordinates are null for a product that publishes none.
pub const Station = struct {
    station_id: []const u8,
    station_name: []const u8,
    last_observed_at: []const u8,
    longitude: ?f64 = null,
    latitude: ?f64 = null,
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

/// The hydro timestamp fields, in the order the parser fills them. They all
/// carry the same IMGW wall-clock form and all have to reach the store as UTC.
pub const hydro_timestamp_fields = [_][]const u8{
    "water_level_observed_at",
    "water_temperature_observed_at",
    "flow_observed_at",
    "ice_phenomenon_observed_at",
    "overgrowth_phenomenon_observed_at",
};

/// Rewrites every timestamp of a hydro batch from Europe/Warsaw wall clock to
/// the UTC form the store keeps, through `resolve` (which returns an owned
/// string per reading). The replacements are made in place, so the batch's
/// ownership rules do not change.
pub fn utcHydroTimestamps(
    allocator: std.mem.Allocator,
    items: []HydroObservation,
    context: anytype,
    comptime resolve: fn (@TypeOf(context), std.mem.Allocator, []const u8) anyerror![]u8,
) !void {
    for (items) |*item| {
        inline for (hydro_timestamp_fields) |field| {
            if (@field(item, field)) |local| {
                const utc = try resolve(context, allocator, local);
                allocator.free(local);
                @field(item, field) = utc;
            }
        }
    }
}
