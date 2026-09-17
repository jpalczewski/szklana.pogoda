//! The measurement fields shared by the observation products.
//!
//! Synop and meteo publish the same measurements under different IMGW field
//! names and derive the observation time differently, so each product maps its
//! own wire struct onto `Fields` and hands over an already allocated
//! `observed_at`. Everything else — text ownership, missing markers and numeric
//! coercion — happens once, here.

const std = @import("std");
const value = @import("value.zig");
const model = @import("../weather/model.zig");

pub const Error = value.Error;

/// One observation in IMGW's string-valued form. A missing JSON key and a
/// missing marker such as `"brak"` are both `null`. Only some products publish
/// the station's position, so a product without those keys leaves them null.
pub const Fields = struct {
    station_id: ?[]const u8 = null,
    station_name: ?[]const u8 = null,
    temperature: ?[]const u8 = null,
    wind_speed: ?[]const u8 = null,
    wind_direction: ?[]const u8 = null,
    humidity: ?[]const u8 = null,
    precipitation: ?[]const u8 = null,
    pressure: ?[]const u8 = null,
    longitude: ?[]const u8 = null,
    latitude: ?[]const u8 = null,
};

/// Maps one record into the model and takes ownership of `observed_at`, which
/// the product allocates because only it knows how to read the timestamp.
pub fn decode(allocator: std.mem.Allocator, fields: Fields, observed_at: []u8) Error!model.Observation {
    errdefer allocator.free(observed_at);

    // Numbers are coerced first so a malformed value fails without allocating.
    const temperature = try value.optionalFloat(fields.temperature);
    const wind_speed = try value.optionalFloat(fields.wind_speed);
    const wind_direction = try value.optionalInt(fields.wind_direction);
    const humidity = try value.optionalFloat(fields.humidity);
    const precipitation = try value.optionalFloat(fields.precipitation);
    const pressure = try value.optionalFloat(fields.pressure);
    const longitude = try value.optionalFloat(fields.longitude);
    const latitude = try value.optionalFloat(fields.latitude);

    const station_id = try value.presentText(allocator, fields.station_id);
    errdefer allocator.free(station_id);
    const station_name = try value.presentText(allocator, fields.station_name);
    errdefer allocator.free(station_name);

    return .{
        .station_id = station_id,
        .station_name = station_name,
        .observed_at = observed_at,
        .temperature_c = temperature,
        .wind_speed_m_s = wind_speed,
        .wind_direction_deg = wind_direction,
        .relative_humidity_percent = humidity,
        .precipitation_mm = precipitation,
        .pressure_hpa = pressure,
        .longitude = longitude,
        .latitude = latitude,
    };
}

test "maps IMGW fields and preserves missing measurements" {
    const observed_at = try std.testing.allocator.dupe(u8, "2026-09-16T07:00:00Z");
    const observation = try decode(std.testing.allocator, .{
        .station_id = "12424",
        .station_name = "Wrocław",
        .temperature = "18.5",
        .wind_speed = "",
        .wind_direction = "220",
        .humidity = "71.5",
        .precipitation = "0",
        .pressure = null,
        .longitude = "16.8858",
        .latitude = "51.1026",
    }, observed_at);
    defer {
        std.testing.allocator.free(observation.station_id);
        std.testing.allocator.free(observation.station_name);
        std.testing.allocator.free(observation.observed_at);
    }

    try std.testing.expectEqualStrings("12424", observation.station_id);
    try std.testing.expectEqualStrings("2026-09-16T07:00:00Z", observation.observed_at);
    try std.testing.expectApproxEqAbs(@as(f64, 18.5), observation.temperature_c.?, 0.001);
    try std.testing.expect(observation.wind_speed_m_s == null);
    try std.testing.expectEqual(@as(?i16, 220), observation.wind_direction_deg);
    try std.testing.expect(observation.pressure_hpa == null);
    try std.testing.expectApproxEqAbs(@as(f64, 16.8858), observation.longitude.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 51.1026), observation.latitude.?, 0.0001);
}

test "a product without coordinates maps them to null" {
    const observed_at = try std.testing.allocator.dupe(u8, "2026-09-16T07:00:00Z");
    const observation = try decode(std.testing.allocator, .{
        .station_id = "12424",
        .station_name = "Wrocław",
    }, observed_at);
    defer {
        std.testing.allocator.free(observation.station_id);
        std.testing.allocator.free(observation.station_name);
        std.testing.allocator.free(observation.observed_at);
    }

    try std.testing.expect(observation.longitude == null);
    try std.testing.expect(observation.latitude == null);
}

test "a malformed coordinate invalidates the record" {
    const observed_at = try std.testing.allocator.dupe(u8, "2026-09-16T07:00:00Z");
    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, .{
        .station_id = "1",
        .station_name = "Test",
        .longitude = "n/a",
        .latitude = "51.1",
    }, observed_at));
}

test "rejects malformed numbers without leaking the timestamp" {
    const observed_at = try std.testing.allocator.dupe(u8, "2026-09-16T07:00:00Z");
    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, .{
        .station_id = "1",
        .station_name = "Test",
        .temperature = "not-a-number",
    }, observed_at));
}

test "requires a station identifier" {
    const observed_at = try std.testing.allocator.dupe(u8, "2026-09-16T07:00:00Z");
    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, .{
        .station_name = "Test",
    }, observed_at));
}
