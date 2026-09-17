const std = @import("std");
const value = @import("value.zig");
const product = @import("product.zig");
const model = @import("../weather/model.zig");

pub const Error = value.Error;

/// The hydro product: river gauges with levels, flows and their alarm
/// thresholds. IMGW documents the endpoint as HTTP, but it redirects to HTTPS;
/// the final URL is used because the Zig HTTP client cannot follow that
/// redirect safely here.
pub const endpoint = "https://danepubliczne.imgw.pl/api/data/hydro/";

/// Field names are IMGW's Polish JSON keys; the comments are English glosses.
const Raw = struct {
    id_stacji: []const u8, // station ID
    stacja: []const u8, // station name
    rzeka: []const u8, // river
    wojewodztwo: ?[]const u8 = null, // voivodeship (province)
    lon: ?[]const u8 = null, // longitude (degrees)
    lat: ?[]const u8 = null, // latitude (degrees)
    rok_zalozenia_stacji: ?[]const u8 = null, // station founding year
    rzedna_zerawodowskazu: ?[]const u8 = null, // gauge zero elevation (m)
    kilometr_biegu_rzeki: ?[]const u8 = null, // river kilometre
    stan_alarmowy: ?[]const u8 = null, // alarm level (cm)
    stan_ostrzegawczy: ?[]const u8 = null, // warning level (cm)
    stan_wody: ?[]const u8 = null, // water level (cm)
    stan_wody_data_pomiaru: ?[]const u8 = null, // water level timestamp
    temperatura_wody: ?[]const u8 = null, // water temperature (deg C)
    temperatura_wody_data_pomiaru: ?[]const u8 = null, // water temperature timestamp
    przeplyw: ?[]const u8 = null, // flow (m3/s)
    przeplyw_data: ?[]const u8 = null, // flow timestamp
    zjawisko_lodowe: ?[]const u8 = null, // ice phenomenon code
    zjawisko_lodowe_data_pomiaru: ?[]const u8 = null, // ice phenomenon timestamp
    zjawisko_zarastania: ?[]const u8 = null, // overgrowth phenomenon code
    zjawisko_zarastania_data_pomiaru: ?[]const u8 = null, // overgrowth phenomenon timestamp
};

/// A station without a water-level timestamp carries no usable measurement, so
/// it is skipped rather than stored half-empty.
const Source = product.Product(model.HydroObservation, Raw, endpoint, parseRaw, model.deinitHydroItems, .{ .label = "hydro" });

pub const parse = Source.parse;
pub const fetch = Source.fetch;

fn parseRaw(allocator: std.mem.Allocator, raw: Raw) Error!model.HydroObservation {
    const station_id = try value.presentText(allocator, raw.id_stacji);
    errdefer allocator.free(station_id);
    const station_name = try value.presentText(allocator, raw.stacja);
    errdefer allocator.free(station_name);
    const river = try value.presentText(allocator, raw.rzeka);
    errdefer allocator.free(river);
    const voivodeship = try allocator.dupe(u8, raw.wojewodztwo orelse "");
    errdefer allocator.free(voivodeship);
    const level_time = try value.optionalTimestamp(allocator, raw.stan_wody_data_pomiaru);
    errdefer {
        if (level_time) |text| allocator.free(text);
    }
    // The gauge carries no usable measurement without a level timestamp.
    if (level_time == null) return error.InvalidData;

    const level = try value.optionalFloat(raw.stan_wody);
    const warning = try value.optionalFloat(raw.stan_ostrzegawczy);
    const alarm = try value.optionalFloat(raw.stan_alarmowy);
    const status = try allocator.dupe(u8, levelStatus(level, warning, alarm));
    errdefer allocator.free(status);

    return .{
        .station_id = station_id,
        .station_name = station_name,
        .river = river,
        .voivodeship = voivodeship,
        .longitude = try value.optionalFloat(raw.lon),
        .latitude = try value.optionalFloat(raw.lat),
        .founded_year = try value.optionalInt32(raw.rok_zalozenia_stacji),
        .gauge_zero_m = try value.optionalFloat(raw.rzedna_zerawodowskazu),
        .river_km = try value.optionalFloat(raw.kilometr_biegu_rzeki),
        .warning_level_cm = warning,
        .alarm_level_cm = alarm,
        .water_level_cm = level,
        .water_level_observed_at = level_time,
        .water_temperature_c = try value.optionalFloat(raw.temperatura_wody),
        .water_temperature_observed_at = try value.optionalTimestamp(allocator, raw.temperatura_wody_data_pomiaru),
        .flow_m3_s = try value.optionalFloat(raw.przeplyw),
        .flow_observed_at = try value.optionalTimestamp(allocator, raw.przeplyw_data),
        .ice_phenomenon = try value.optionalInt32(raw.zjawisko_lodowe),
        .ice_phenomenon_observed_at = try value.optionalTimestamp(allocator, raw.zjawisko_lodowe_data_pomiaru),
        .overgrowth_phenomenon = try value.optionalInt32(raw.zjawisko_zarastania),
        .overgrowth_phenomenon_observed_at = try value.optionalTimestamp(allocator, raw.zjawisko_zarastania_data_pomiaru),
        .water_level_status = status,
    };
}

/// Classifies the current level against the station's own thresholds. Without
/// thresholds the status stays unknown rather than being reported as normal.
fn levelStatus(level: ?f64, warning: ?f64, alarm: ?f64) []const u8 {
    const current = level orelse return "unknown";
    if (alarm) |threshold| if (current >= threshold) return "alarm";
    if (warning) |threshold| if (current >= threshold) return "warning";
    if (warning == null and alarm == null) return "unknown";
    return "normal";
}

test "parses hydro station and computes threshold status" {
    const body =
        \\[{"id_stacji":"151140030","stacja":"Przewoźniki","rzeka":"Skroda","wojewodztwo":"lubuskie","lon":"14.8217","lat":"51.5253","stan_alarmowy":"340","stan_ostrzegawczy":"300","stan_wody":"310","stan_wody_data_pomiaru":"2026-09-16 07:50:00","przeplyw":"0.11","przeplyw_data":"2026-09-16 07:50:00"}]
    ;
    const items = try parse(std.testing.allocator, body);
    defer model.deinitHydro(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("warning", items[0].water_level_status);
    try std.testing.expectEqualStrings("2026-09-16 07:50:00", items[0].water_level_observed_at.?);
    try std.testing.expectEqualStrings("2026-09-16 07:50:00", items[0].flow_observed_at.?);
}

test "hydro status is unknown without thresholds" {
    try std.testing.expectEqualStrings("unknown", levelStatus(120, null, null));
    try std.testing.expectEqualStrings("unknown", levelStatus(null, 100, 200));
    try std.testing.expectEqualStrings("normal", levelStatus(90, 100, 200));
    try std.testing.expectEqualStrings("warning", levelStatus(150, 100, 200));
    try std.testing.expectEqualStrings("alarm", levelStatus(250, 100, 200));
}

test "skips hydro stations without a level timestamp" {
    const body =
        \\[{"id_stacji":"1","stacja":"Bez czasu","rzeka":"Rzeka","stan_wody":"310"}]
    ;
    const items = try parse(std.testing.allocator, body);
    defer model.deinitHydro(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "every hydro timestamp keeps the IMGW wall-clock form" {
    const body =
        \\[{"id_stacji":"151140030","stacja":"Przewoźniki","rzeka":"Skroda","stan_wody":"310","stan_wody_data_pomiaru":"2026-09-16 07:50:00","temperatura_wody":"12.5","temperatura_wody_data_pomiaru":"2026-09-16 07:45:00","przeplyw":"0.11","przeplyw_data":"2026-09-16 07:40:00","zjawisko_lodowe":"0","zjawisko_lodowe_data_pomiaru":"2026-09-16 07:30:00","zjawisko_zarastania":"1","zjawisko_zarastania_data_pomiaru":"2026-09-16 07:20:00"}]
    ;
    const items = try parse(std.testing.allocator, body);
    defer model.deinitHydro(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("2026-09-16 07:45:00", items[0].water_temperature_observed_at.?);
    try std.testing.expectEqualStrings("2026-09-16 07:40:00", items[0].flow_observed_at.?);
    try std.testing.expectEqualStrings("2026-09-16 07:30:00", items[0].ice_phenomenon_observed_at.?);
    try std.testing.expectEqualStrings("2026-09-16 07:20:00", items[0].overgrowth_phenomenon_observed_at.?);
}

test "keeps a dash river name because IMGW uses it for harbour gauges" {
    const body =
        \\[{"id_stacji":"154180140","stacja":"Gdańsk","rzeka":"-","stan_alarmowy":"570","stan_ostrzegawczy":"550","stan_wody":"525","stan_wody_data_pomiaru":"2026-09-16 22:20:00"}]
    ;
    const items = try parse(std.testing.allocator, body);
    defer model.deinitHydro(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("-", items[0].river);
    try std.testing.expectEqualStrings("normal", items[0].water_level_status);
}
