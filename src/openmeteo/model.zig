//! The Open-Meteo forecast domain model.
//!
//! Plain data, independent of fetching, caching or decoding: every slice
//! field is owned by the allocator that built it and released by `Forecast.deinit`,
//! the same ownership rule `weather/model.zig` states for the IMGW domain.

const std = @import("std");

pub const Current = struct {
    /// Open-Meteo local time, e.g. `"2026-09-18T14:00"`.
    time: []const u8,
    temperature_c: f64,
    apparent_temperature_c: f64,
    relative_humidity_percent: u8,
    precipitation_mm: f64,
    /// WMO weather code.
    weather_code: u8,
    wind_speed_kmh: f64,
    wind_direction_deg: u16,
};

pub const Day = struct {
    /// `"YYYY-MM-DD"`.
    date: []const u8,
    weather_code: u8,
    temperature_min_c: f64,
    temperature_max_c: f64,
    precipitation_sum_mm: f64,
    precipitation_chance_percent: u8,
    sunrise: []const u8,
    sunset: []const u8,
};

/// One location's forecast. `latitude`/`longitude` are the grid point
/// Open-Meteo actually answered with, not necessarily the exact coordinates
/// requested.
pub const Forecast = struct {
    latitude: f64,
    longitude: f64,
    current: Current,
    daily: []Day,
    /// Seconds since this reading was downloaded; zero for a fresh fetch.
    fetched_age_seconds: u64 = 0,

    pub fn deinit(self: Forecast, allocator: std.mem.Allocator) void {
        allocator.free(self.current.time);
        deinitDays(allocator, self.daily);
        allocator.free(self.daily);
    }
};

/// Releases the strings of a decoded day slice without releasing the slice
/// itself, so a partially built batch can be cleaned up on error.
pub fn deinitDays(allocator: std.mem.Allocator, days: []const Day) void {
    for (days) |day| {
        allocator.free(day.date);
        allocator.free(day.sunrise);
        allocator.free(day.sunset);
    }
}
