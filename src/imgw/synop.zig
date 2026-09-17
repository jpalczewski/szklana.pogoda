const std = @import("std");
const value = @import("value.zig");
const product = @import("product.zig");
const fields = @import("observation_fields.zig");
const model = @import("../weather/model.zig");

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

/// A malformed record means a malformed payload here, so decoding is strict.
const source = product.Product(model.Observation, Raw, endpoint, parseRaw, model.deinitObservationItems, .{ .label = "synop", .strict = true });

/// Converts the API's string-valued records into the application's typed model.
/// The returned strings are owned by `allocator` and must be released with
/// `model.deinitObservations`.
pub const parse = source.parse;
pub const fetch = source.fetch;

fn parseRaw(allocator: std.mem.Allocator, raw: Raw) Error!model.Observation {
    const observed_at = try observedAt(allocator, raw.data_pomiaru, raw.godzina_pomiaru);
    return fields.decode(allocator, .{
        .station_id = raw.id_stacji,
        .station_name = raw.stacja,
        .temperature = raw.temperatura,
        .wind_speed = raw.predkosc_wiatru,
        .wind_direction = raw.kierunek_wiatru,
        .humidity = raw.wilgotnosc_wzgledna,
        .precipitation = raw.suma_opadu,
        .pressure = raw.cisnienie,
    }, observed_at);
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
    defer model.deinitObservations(std.testing.allocator, observations);

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
