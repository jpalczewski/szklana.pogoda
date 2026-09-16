const std = @import("std");
const Io = std.Io;
const value = @import("value.zig");
const http = @import("http.zig");
const records = @import("records.zig");
const model = @import("../weather/model.zig");

pub const Error = value.Error;

/// The meteo product describes the same observations as synop but with
/// per-measurement timestamps and different field names.
pub const endpoint = "https://danepubliczne.imgw.pl/api/data/meteo/";

/// Field names are IMGW's Polish JSON keys; the comments are English glosses.
const Raw = struct {
    kod_stacji: []const u8, // station code
    nazwa_stacji: []const u8, // station name
    temperatura_powietrza: ?[]const u8 = null, // air temperature (deg C)
    temperatura_powietrza_data: ?[]const u8 = null, // air temperature timestamp
    wiatr_kierunek: ?[]const u8 = null, // wind direction (degrees)
    wiatr_kierunek_data: ?[]const u8 = null, // wind direction timestamp
    wiatr_srednia_predkosc: ?[]const u8 = null, // mean wind speed (m/s)
    wilgotnosc_wzgledna: ?[]const u8 = null, // relative humidity (percent)
    wilgotnosc_wzgledna_data: ?[]const u8 = null, // relative humidity timestamp
    opad_10min: ?[]const u8 = null, // precipitation in the last 10 minutes (mm)
    opad_10min_data: ?[]const u8 = null, // precipitation timestamp
};

pub fn fetch(allocator: std.mem.Allocator, io: Io) Error![]model.Observation {
    return http.fetchParsed([]model.Observation, allocator, io, endpoint, parse);
}

/// Meteo records stand alone, so one malformed station is skipped instead of
/// discarding the whole response.
pub fn parse(allocator: std.mem.Allocator, body: []const u8) Error![]model.Observation {
    return records.decode(
        model.Observation,
        Raw,
        parseRaw,
        model.deinitObservationItems,
        allocator,
        body,
        .{ .label = "meteo" },
    );
}

fn parseRaw(allocator: std.mem.Allocator, raw: Raw) Error!model.Observation {
    const station_id = try value.presentText(allocator, raw.kod_stacji);
    errdefer allocator.free(station_id);
    const station_name = try value.presentText(allocator, raw.nazwa_stacji);
    errdefer allocator.free(station_name);
    const source_time = raw.temperatura_powietrza_data orelse raw.wilgotnosc_wzgledna_data orelse raw.opad_10min_data orelse return error.InvalidData;
    const observed_at = try value.utcTimestamp(allocator, source_time);
    errdefer allocator.free(observed_at);
    return .{
        .station_id = station_id,
        .station_name = station_name,
        .observed_at = observed_at,
        .temperature_c = try value.optionalFloat(raw.temperatura_powietrza),
        .wind_speed_m_s = try value.optionalFloat(raw.wiatr_srednia_predkosc),
        .wind_direction_deg = try value.optionalInt(raw.wiatr_kierunek),
        .relative_humidity_percent = try value.optionalFloat(raw.wilgotnosc_wzgledna),
        .precipitation_mm = try value.optionalFloat(raw.opad_10min),
        .pressure_hpa = null,
    };
}

test "parses meteo records using the first available timestamp" {
    const body =
        \\[{"kod_stacji":"12424","nazwa_stacji":"Wrocław","temperatura_powietrza":"18.5","temperatura_powietrza_data":"2026-09-16 07:00:00","wiatr_kierunek":"220","wiatr_srednia_predkosc":"3.5","wilgotnosc_wzgledna":"71.5","wilgotnosc_wzgledna_data":"2026-09-16 07:00:00","opad_10min":"0","opad_10min_data":"2026-09-16 07:00:00"}]
    ;
    const observations = try parse(std.testing.allocator, body);
    defer model.deinitObservations(std.testing.allocator, observations);

    try std.testing.expectEqual(@as(usize, 1), observations.len);
    try std.testing.expectEqualStrings("2026-09-16T07:00:00Z", observations[0].observed_at);
    try std.testing.expectApproxEqAbs(@as(f64, 18.5), observations[0].temperature_c.?, 0.001);
    try std.testing.expectEqual(@as(?i16, 220), observations[0].wind_direction_deg);
}

test "skips a meteo record without any timestamp" {
    const body =
        \\[{"kod_stacji":"1","nazwa_stacji":"Bez czasu","temperatura_powietrza":"18.5"}]
    ;
    const observations = try parse(std.testing.allocator, body);
    defer model.deinitObservations(std.testing.allocator, observations);
    try std.testing.expectEqual(@as(usize, 0), observations.len);
}
