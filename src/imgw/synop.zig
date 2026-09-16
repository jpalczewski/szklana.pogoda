const std = @import("std");
const Io = std.Io;
const value = @import("value.zig");
const http = @import("http.zig");
const records = @import("records.zig");
const weather_store = @import("../weather/store.zig");

pub const Error = value.Error;

/// The synoptic product: one record per station with the classic IMGW field
/// names and a separate date and hour.
pub const endpoint = "https://danepubliczne.imgw.pl/api/data/synop";

/// Field names are IMGW's Polish JSON keys; the comments are English glosses.
const Raw = struct {
    id_stacji: []const u8, // station ID
    stacja: []const u8, // station name
    data_pomiaru: []const u8, // measurement date
    godzina_pomiaru: []const u8, // measurement hour
    temperatura: ?[]const u8 = null, // air temperature (deg C)
    predkosc_wiatru: ?[]const u8 = null, // wind speed (m/s)
    kierunek_wiatru: ?[]const u8 = null, // wind direction (degrees)
    wilgotnosc_wzgledna: ?[]const u8 = null, // relative humidity (percent)
    suma_opadu: ?[]const u8 = null, // precipitation total (mm)
    cisnienie: ?[]const u8 = null, // pressure (hPa)
};

pub fn fetch(allocator: std.mem.Allocator, io: Io) Error![]weather_store.Observation {
    return http.fetchParsed([]weather_store.Observation, allocator, io, endpoint, parse);
}

/// Converts the API's string-valued records into the application's typed model.
/// The returned strings are owned by `allocator` and must be released with
/// `weather_store.Store.deinitHistory`.
pub fn parse(allocator: std.mem.Allocator, body: []const u8) Error![]weather_store.Observation {
    return records.decode(
        weather_store.Observation,
        Raw,
        parseRaw,
        weather_store.Store.deinitHistoryItems,
        allocator,
        body,
        .{ .label = "synop", .strict = true },
    );
}

fn parseRaw(allocator: std.mem.Allocator, raw: Raw) Error!weather_store.Observation {
    const temperature = try value.optionalFloat(raw.temperatura);
    const wind_speed = try value.optionalFloat(raw.predkosc_wiatru);
    const wind_direction = try value.optionalInt(raw.kierunek_wiatru);
    const humidity = try value.optionalFloat(raw.wilgotnosc_wzgledna);
    const precipitation = try value.optionalFloat(raw.suma_opadu);
    const pressure = try value.optionalFloat(raw.cisnienie);

    const station_id = try value.presentText(allocator, raw.id_stacji);
    errdefer allocator.free(station_id);
    const station_name = try value.presentText(allocator, raw.stacja);
    errdefer allocator.free(station_name);
    const observed_at = try observedAt(allocator, raw.data_pomiaru, raw.godzina_pomiaru);
    errdefer allocator.free(observed_at);

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
    };
}

/// The synoptic product splits date and hour; the store keeps the ISO-like
/// form every other product uses.
fn observedAt(allocator: std.mem.Allocator, date: []const u8, hour: []const u8) Error![]u8 {
    if (date.len != 10 or hour.len == 0) return error.InvalidData;
    const hour_number = std.fmt.parseInt(u8, hour, 10) catch return error.InvalidData;
    if (hour_number > 23) return error.InvalidData;
    const local = try std.fmt.allocPrint(allocator, "{s} {d:0>2}:00:00", .{ date, hour_number });
    defer allocator.free(local);
    return value.utcTimestamp(allocator, local);
}

test "parses IMGW records and preserves missing measurements" {
    const body =
        \\[{"id_stacji":"12424","stacja":"Wrocław","data_pomiaru":"2026-09-16","godzina_pomiaru":"7","temperatura":"18.5","predkosc_wiatru":"","kierunek_wiatru":"220","wilgotnosc_wzgledna":"71.5","suma_opadu":"0","cisnienie":null,"nieznane":"ok"}]
    ;
    const observations = try parse(std.testing.allocator, body);
    defer weather_store.Store.deinitHistory(std.testing.allocator, observations);

    try std.testing.expectEqual(@as(usize, 1), observations.len);
    try std.testing.expectEqualStrings("12424", observations[0].station_id);
    try std.testing.expectEqualStrings("2026-09-16T07:00:00Z", observations[0].observed_at);
    try std.testing.expectApproxEqAbs(@as(f64, 18.5), observations[0].temperature_c.?, 0.001);
    try std.testing.expect(observations[0].wind_speed_m_s == null);
    try std.testing.expect(observations[0].pressure_hpa == null);
}

test "rejects malformed numeric values" {
    const body =
        \\[{"id_stacji":"1","stacja":"Test","data_pomiaru":"2026-09-16","godzina_pomiaru":"7","temperatura":"not-a-number"}]
    ;
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator, body));
}

test "rejects an hour outside the day" {
    const body =
        \\[{"id_stacji":"1","stacja":"Test","data_pomiaru":"2026-09-16","godzina_pomiaru":"24","temperatura":"1"}]
    ;
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator, body));
}
