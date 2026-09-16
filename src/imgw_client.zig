const std = @import("std");
const Io = std.Io;
const json = @import("imgw_json.zig");
const weather_store = @import("weather_store.zig");

const RawObservation = struct {
    id_stacji: []const u8,
    stacja: []const u8,
    data_pomiaru: []const u8,
    godzina_pomiaru: []const u8,
    temperatura: ?[]const u8 = null,
    predkosc_wiatru: ?[]const u8 = null,
    kierunek_wiatru: ?[]const u8 = null,
    wilgotnosc_wzgledna: ?[]const u8 = null,
    suma_opadu: ?[]const u8 = null,
    cisnienie: ?[]const u8 = null,
};

const RawMeteo = struct {
    kod_stacji: []const u8,
    nazwa_stacji: []const u8,
    temperatura_powietrza: ?[]const u8 = null,
    temperatura_powietrza_data: ?[]const u8 = null,
    wiatr_kierunek: ?[]const u8 = null,
    wiatr_kierunek_data: ?[]const u8 = null,
    wiatr_srednia_predkosc: ?[]const u8 = null,
    wilgotnosc_wzgledna: ?[]const u8 = null,
    wilgotnosc_wzgledna_data: ?[]const u8 = null,
    opad_10min: ?[]const u8 = null,
    opad_10min_data: ?[]const u8 = null,
};

const RawHydro = struct {
    id_stacji: []const u8,
    stacja: []const u8,
    rzeka: []const u8,
    wojewodztwo: ?[]const u8 = null,
    lon: ?[]const u8 = null,
    lat: ?[]const u8 = null,
    rok_zalozenia_stacji: ?[]const u8 = null,
    rzedna_zerawodowskazu: ?[]const u8 = null,
    kilometr_biegu_rzeki: ?[]const u8 = null,
    stan_alarmowy: ?[]const u8 = null,
    stan_ostrzegawczy: ?[]const u8 = null,
    stan_wody: ?[]const u8 = null,
    stan_wody_data_pomiaru: ?[]const u8 = null,
    temperatura_wody: ?[]const u8 = null,
    temperatura_wody_data_pomiaru: ?[]const u8 = null,
    przeplyw: ?[]const u8 = null,
    przeplyw_data: ?[]const u8 = null,
    zjawisko_lodowe: ?[]const u8 = null,
    zjawisko_lodowe_data_pomiaru: ?[]const u8 = null,
    zjawisko_zarastania: ?[]const u8 = null,
    zjawisko_zarastania_data_pomiaru: ?[]const u8 = null,
};

pub const Error = json.Error;

pub fn fetch(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]weather_store.Observation {
    const body = try json.get(allocator, io, url);
    defer allocator.free(body);
    if (std.mem.indexOf(u8, url, "/meteo") != null) return parseMeteo(allocator, body);
    return parse(allocator, body);
}

pub fn fetchHydro(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]weather_store.HydroObservation {
    const body = try json.get(allocator, io, url);
    defer allocator.free(body);
    return parseHydro(allocator, body);
}

pub fn parseHydro(allocator: std.mem.Allocator, body: []const u8) Error![]weather_store.HydroObservation {
    var parsed = std.json.parseFromSlice([]RawHydro, allocator, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidData;
    defer parsed.deinit();
    var items: std.ArrayList(weather_store.HydroObservation) = .empty;
    errdefer {
        weather_store.Store.deinitHydro(allocator, items.items);
        items.deinit(allocator);
    }
    for (parsed.value) |raw| {
        const item = parseHydroRaw(allocator, raw) catch |err| {
            std.log.warn("skipping invalid IMGW hydro station {s}: {t}", .{ raw.id_stacji, err });
            continue;
        };
        try items.append(allocator, item);
    }
    return items.toOwnedSlice(allocator);
}

fn parseHydroRaw(allocator: std.mem.Allocator, raw: RawHydro) Error!weather_store.HydroObservation {
    const station_id = try allocator.dupe(u8, raw.id_stacji);
    errdefer allocator.free(station_id);
    const station_name = try allocator.dupe(u8, raw.stacja);
    errdefer allocator.free(station_name);
    const river = try allocator.dupe(u8, raw.rzeka);
    errdefer allocator.free(river);
    const voivodeship = try allocator.dupe(u8, raw.wojewodztwo orelse "");
    errdefer allocator.free(voivodeship);
    const level_time = try json.optionalText(allocator, raw.stan_wody_data_pomiaru);
    errdefer {
        if (level_time) |value| allocator.free(value);
    }
    if (level_time == null) return error.InvalidData;
    const status = try allocator.dupe(u8, levelStatus(try json.optionalFloat(raw.stan_wody), try json.optionalFloat(raw.stan_ostrzegawczy), try json.optionalFloat(raw.stan_alarmowy)));
    errdefer allocator.free(status);
    return .{
        .station_id = station_id,
        .station_name = station_name,
        .river = river,
        .voivodeship = voivodeship,
        .longitude = try json.optionalFloat(raw.lon),
        .latitude = try json.optionalFloat(raw.lat),
        .founded_year = try json.optionalInt32(raw.rok_zalozenia_stacji),
        .gauge_zero_m = try json.optionalFloat(raw.rzedna_zerawodowskazu),
        .river_km = try json.optionalFloat(raw.kilometr_biegu_rzeki),
        .warning_level_cm = try json.optionalFloat(raw.stan_ostrzegawczy),
        .alarm_level_cm = try json.optionalFloat(raw.stan_alarmowy),
        .water_level_cm = try json.optionalFloat(raw.stan_wody),
        .water_level_observed_at = level_time,
        .water_temperature_c = try json.optionalFloat(raw.temperatura_wody),
        .water_temperature_observed_at = try json.optionalText(allocator, raw.temperatura_wody_data_pomiaru),
        .flow_m3_s = try json.optionalFloat(raw.przeplyw),
        .flow_observed_at = try json.optionalText(allocator, raw.przeplyw_data),
        .ice_phenomenon = try json.optionalInt32(raw.zjawisko_lodowe),
        .ice_phenomenon_observed_at = try json.optionalText(allocator, raw.zjawisko_lodowe_data_pomiaru),
        .overgrowth_phenomenon = try json.optionalInt32(raw.zjawisko_zarastania),
        .overgrowth_phenomenon_observed_at = try json.optionalText(allocator, raw.zjawisko_zarastania_data_pomiaru),
        .water_level_status = status,
    };
}

fn levelStatus(level: ?f64, warning: ?f64, alarm: ?f64) []const u8 {
    const value = level orelse return "unknown";
    if (alarm) |threshold| if (value >= threshold) return "alarm";
    if (warning) |threshold| if (value >= threshold) return "warning";
    if (warning == null and alarm == null) return "unknown";
    return "normal";
}

pub fn parseMeteo(allocator: std.mem.Allocator, body: []const u8) Error![]weather_store.Observation {
    var parsed = std.json.parseFromSlice([]RawMeteo, allocator, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidData;
    defer parsed.deinit();
    var observations: std.ArrayList(weather_store.Observation) = .empty;
    errdefer {
        weather_store.Store.deinitHistoryItems(allocator, observations.items);
        observations.deinit(allocator);
    }
    for (parsed.value) |raw| {
        const item = parseMeteoRaw(allocator, raw) catch |err| {
            std.log.warn("skipping invalid IMGW meteo station {s}: {t}", .{ raw.kod_stacji, err });
            continue;
        };
        try observations.append(allocator, item);
    }
    return observations.toOwnedSlice(allocator);
}

fn parseMeteoRaw(allocator: std.mem.Allocator, raw: RawMeteo) Error!weather_store.Observation {
    const station_id = try allocator.dupe(u8, raw.kod_stacji);
    errdefer allocator.free(station_id);
    const station_name = try allocator.dupe(u8, raw.nazwa_stacji);
    errdefer allocator.free(station_name);
    const source_time = raw.temperatura_powietrza_data orelse raw.wilgotnosc_wzgledna_data orelse raw.opad_10min_data orelse return error.InvalidData;
    const observed_at = try meteoTime(allocator, source_time);
    errdefer allocator.free(observed_at);
    return .{
        .station_id = station_id,
        .station_name = station_name,
        .observed_at = observed_at,
        .temperature_c = try json.optionalFloat(raw.temperatura_powietrza),
        .wind_speed_m_s = try json.optionalFloat(raw.wiatr_srednia_predkosc),
        .wind_direction_deg = try json.optionalInt(raw.wiatr_kierunek),
        .relative_humidity_percent = try json.optionalFloat(raw.wilgotnosc_wzgledna),
        .precipitation_mm = try json.optionalFloat(raw.opad_10min),
        .pressure_hpa = null,
    };
}

fn meteoTime(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len != 19 or source[10] != ' ') return error.InvalidData;
    return std.fmt.allocPrint(allocator, "{s}T{s}Z", .{ source[0..10], source[11..] });
}

/// Converts the API's string-valued records into the application's typed model.
/// The returned strings are owned by `allocator` and must be released with
/// `weather_store.Store.deinitHistory`.
pub fn parse(allocator: std.mem.Allocator, body: []const u8) Error![]weather_store.Observation {
    var parsed = std.json.parseFromSlice([]RawObservation, allocator, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidData;
    defer parsed.deinit();

    var observations: std.ArrayList(weather_store.Observation) = .empty;
    errdefer {
        weather_store.Store.deinitHistoryItems(allocator, observations.items);
        observations.deinit(allocator);
    }

    for (parsed.value) |raw| {
        const item = try parseRaw(allocator, raw);
        try observations.append(allocator, item);
    }

    return observations.toOwnedSlice(allocator);
}

fn parseRaw(allocator: std.mem.Allocator, raw: RawObservation) Error!weather_store.Observation {
    const temperature = try json.optionalFloat(raw.temperatura);
    const wind_speed = try json.optionalFloat(raw.predkosc_wiatru);
    const wind_direction = try json.optionalInt(raw.kierunek_wiatru);
    const humidity = try json.optionalFloat(raw.wilgotnosc_wzgledna);
    const precipitation = try json.optionalFloat(raw.suma_opadu);
    const pressure = try json.optionalFloat(raw.cisnienie);

    const station_id = try allocator.dupe(u8, raw.id_stacji);
    errdefer allocator.free(station_id);
    const station_name = try allocator.dupe(u8, raw.stacja);
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

fn observedAt(allocator: std.mem.Allocator, date: []const u8, hour: []const u8) ![]u8 {
    if (date.len != 10 or hour.len == 0) return error.InvalidData;
    const hour_number = std.fmt.parseInt(u8, hour, 10) catch return error.InvalidData;
    if (hour_number > 23) return error.InvalidData;
    return std.fmt.allocPrint(allocator, "{s}T{d:0>2}:00:00Z", .{ date, hour_number });
}

test "parses hydro station and computes threshold status" {
    const body =
        \\[{"id_stacji":"151140030","stacja":"Przewoźniki","rzeka":"Skroda","wojewodztwo":"lubuskie","lon":"14.8217","lat":"51.5253","stan_alarmowy":"340","stan_ostrzegawczy":"300","stan_wody":"310","stan_wody_data_pomiaru":"2026-09-16 07:50:00","przeplyw":"0.11"}]
    ;
    const items = try parseHydro(std.testing.allocator, body);
    defer weather_store.Store.deinitHydro(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("warning", items[0].water_level_status);
    try std.testing.expectEqualStrings("2026-09-16 07:50:00", items[0].water_level_observed_at.?);
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
