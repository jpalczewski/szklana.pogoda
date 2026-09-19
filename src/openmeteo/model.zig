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

pub const Hour = struct {
    /// Open-Meteo local time on the hour, e.g. `"2026-09-18T14:00"`.
    time: []const u8,
    temperature_c: f64,
    /// Null when Open-Meteo has no probability for that hour.
    precipitation_chance_percent: ?u8,
    precipitation_mm: f64,
    /// WMO weather code.
    weather_code: u8,
    wind_speed_kmh: f64,
    wind_direction_deg: u16,
};

/// One location's forecast. `latitude`/`longitude` are the grid point
/// Open-Meteo actually answered with, not necessarily the exact coordinates
/// requested. `hourly` covers the hours from the current one onwards.
pub const Forecast = struct {
    latitude: f64,
    longitude: f64,
    current: Current,
    daily: []Day,
    hourly: []Hour,
    /// Seconds since this reading was downloaded; zero for a fresh fetch.
    fetched_age_seconds: u64 = 0,

    pub fn deinit(self: Forecast, allocator: std.mem.Allocator) void {
        allocator.free(self.current.time);
        deinitDays(allocator, self.daily);
        allocator.free(self.daily);
        deinitHours(allocator, self.hourly);
        allocator.free(self.hourly);
    }
};

/// Releases the strings of a decoded hour slice without releasing the slice
/// itself, like `deinitDays`.
pub fn deinitHours(allocator: std.mem.Allocator, hours: []const Hour) void {
    for (hours) |hour| allocator.free(hour.time);
}

/// Releases the strings of a decoded day slice without releasing the slice
/// itself, so a partially built batch can be cleaned up on error.
pub fn deinitDays(allocator: std.mem.Allocator, days: []const Day) void {
    for (days) |day| {
        allocator.free(day.date);
        allocator.free(day.sunrise);
        allocator.free(day.sunset);
    }
}

/// The few groups of WMO weather interpretation codes the site has a word and
/// a picture for. The names are the ones of the icons in
/// `src/web/weather_icons.txt` and the `wmo_*` locale keys.
pub const Condition = enum {
    clear,
    partly,
    cloudy,
    fog,
    drizzle,
    rain,
    showers,
    snow,
    thunderstorm,
};

/// The group a WMO code belongs to, or null for a code the site does not
/// describe. `weather_group` in `src/web/app.js` folds the same codes the same
/// way, so the page and a link preview name one weather alike.
pub fn condition(code: u8) ?Condition {
    return switch (code) {
        0 => .clear,
        1, 2 => .partly,
        3 => .cloudy,
        45, 48 => .fog,
        51...57 => .drizzle,
        61...67 => .rain,
        71...77, 85, 86 => .snow,
        80...82 => .showers,
        95...99 => .thunderstorm,
        else => null,
    };
}

test "condition folds WMO codes into the groups the page names" {
    try std.testing.expectEqual(Condition.clear, condition(0).?);
    try std.testing.expectEqual(Condition.partly, condition(2).?);
    try std.testing.expectEqual(Condition.cloudy, condition(3).?);
    try std.testing.expectEqual(Condition.fog, condition(48).?);
    try std.testing.expectEqual(Condition.drizzle, condition(53).?);
    try std.testing.expectEqual(Condition.rain, condition(63).?);
    try std.testing.expectEqual(Condition.snow, condition(75).?);
    try std.testing.expectEqual(Condition.snow, condition(86).?);
    try std.testing.expectEqual(Condition.showers, condition(81).?);
    try std.testing.expectEqual(Condition.thunderstorm, condition(96).?);
}

test "condition has no group for a code the site does not describe" {
    try std.testing.expect(condition(4) == null);
    try std.testing.expect(condition(58) == null);
    try std.testing.expect(condition(83) == null);
    try std.testing.expect(condition(255) == null);
}
