const std = @import("std");
const Io = std.Io;

const json = @import("imgw_json.zig");
const warnings = @import("warnings.zig");

pub const Error = json.Error;

/// Meteorological warnings use ASCII field names and TERYT county codes.
/// Every field is optional here so that a single malformed record can be
/// skipped instead of discarding the whole response.
const RawMeteoWarning = struct {
    id: ?[]const u8 = null,
    nazwa_zdarzenia: ?[]const u8 = null,
    stopien: ?[]const u8 = null,
    prawdopodobienstwo: ?[]const u8 = null,
    obowiazuje_do: ?[]const u8 = null,
    obowiazuje_od: ?[]const u8 = null,
    opublikowano: ?[]const u8 = null,
    tresc: ?[]const u8 = null,
    komentarz: ?[]const u8 = null,
    biuro: ?[]const u8 = null,
    teryt: ?[]const []const u8 = null,
};

/// Hydrological warnings describe areas nested under `obszary` and carry no
/// identifier at all; `numer` is part of the identity synthesized for them.
const RawHydroWarning = struct {
    opublikowano: ?[]const u8 = null,
    @"stopień": ?[]const u8 = null,
    data_od: ?[]const u8 = null,
    data_do: ?[]const u8 = null,
    prawdopodobienstwo: ?[]const u8 = null,
    numer: ?[]const u8 = null,
    biuro: ?[]const u8 = null,
    zdarzenie: ?[]const u8 = null,
    przebieg: ?[]const u8 = null,
    komentarz: ?[]const u8 = null,
    obszary: ?[]const RawHydroArea = null,
};

const RawHydroArea = struct {
    wojewodztwo: ?[]const u8 = null,
    opis: ?[]const u8 = null,
    kod_zlewni: ?[]const []const u8 = null,
};

pub fn fetchMeteo(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]warnings.Warning {
    const body = try json.get(allocator, io, url);
    defer allocator.free(body);
    return parseMeteo(allocator, body);
}

pub fn fetchHydro(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]warnings.Warning {
    const body = try json.get(allocator, io, url);
    defer allocator.free(body);
    return parseHydro(allocator, body);
}

pub fn parseMeteo(allocator: std.mem.Allocator, body: []const u8) Error![]warnings.Warning {
    var parsed = std.json.parseFromSlice([]RawMeteoWarning, allocator, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidData;
    defer parsed.deinit();

    var items: std.ArrayList(warnings.Warning) = .empty;
    errdefer {
        warnings.deinitWarningItems(allocator, items.items);
        items.deinit(allocator);
    }
    for (parsed.value) |raw| {
        const item = parseMeteoRaw(allocator, raw) catch |err| {
            std.log.warn("skipping invalid IMGW meteo warning {s}: {t}", .{ raw.id orelse "?", err });
            continue;
        };
        try items.append(allocator, item);
    }
    return items.toOwnedSlice(allocator);
}

fn parseMeteoRaw(allocator: std.mem.Allocator, raw: RawMeteoWarning) Error!warnings.Warning {
    const warning_id = try allocator.dupe(u8, raw.id orelse return error.InvalidData);
    errdefer allocator.free(warning_id);
    const event = try allocator.dupe(u8, raw.nazwa_zdarzenia orelse return error.InvalidData);
    errdefer allocator.free(event);
    const office = try allocator.dupe(u8, raw.biuro orelse return error.InvalidData);
    errdefer allocator.free(office);
    const content = try allocator.dupe(u8, raw.tresc orelse return error.InvalidData);
    errdefer allocator.free(content);
    const published_at = (try json.optionalTimestamp(allocator, raw.opublikowano)) orelse return error.InvalidData;
    errdefer allocator.free(published_at);
    const effective_from = (try json.optionalTimestamp(allocator, raw.obowiazuje_od)) orelse return error.InvalidData;
    errdefer allocator.free(effective_from);
    const effective_to = (try json.optionalTimestamp(allocator, raw.obowiazuje_do)) orelse return error.InvalidData;
    errdefer allocator.free(effective_to);
    const comment = try json.optionalText(allocator, raw.komentarz);
    errdefer {
        if (comment) |value| allocator.free(value);
    }
    const areas = try parseMeteoAreas(allocator, raw.teryt orelse &.{});
    errdefer warnings.deinitAreas(allocator, areas);

    return .{
        .source = .meteo,
        .warning_id = warning_id,
        .event = event,
        .severity = try json.optionalInt(raw.stopien),
        .probability_percent = try json.optionalInt(raw.prawdopodobienstwo),
        .office = office,
        .published_at = published_at,
        .effective_from = effective_from,
        .effective_to = effective_to,
        .content = content,
        .comment = comment,
        .areas = areas,
    };
}

/// One warned county per TERYT code.
fn parseMeteoAreas(allocator: std.mem.Allocator, codes: []const []const u8) Error![]warnings.Area {
    var areas = try allocator.alloc(warnings.Area, codes.len);
    var filled: usize = 0;
    errdefer {
        warnings.deinitAreas(allocator, areas[0..filled]);
        allocator.free(areas);
    }
    for (codes, 0..) |code, i| {
        areas[i] = .{ .teryt = try allocator.dupe(u8, code) };
        filled = i + 1;
    }
    return areas;
}

pub fn parseHydro(allocator: std.mem.Allocator, body: []const u8) Error![]warnings.Warning {
    var parsed = std.json.parseFromSlice([]RawHydroWarning, allocator, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidData;
    defer parsed.deinit();

    var items: std.ArrayList(warnings.Warning) = .empty;
    errdefer {
        warnings.deinitWarningItems(allocator, items.items);
        items.deinit(allocator);
    }
    for (parsed.value) |raw| {
        const item = parseHydroRaw(allocator, raw) catch |err| {
            std.log.warn("skipping invalid IMGW hydro warning {s}: {t}", .{ raw.numer orelse "?", err });
            continue;
        };
        try items.append(allocator, item);
    }
    return items.toOwnedSlice(allocator);
}

fn parseHydroRaw(allocator: std.mem.Allocator, raw: RawHydroWarning) Error!warnings.Warning {
    const published_at = (try json.optionalTimestamp(allocator, raw.opublikowano)) orelse return error.InvalidData;
    errdefer allocator.free(published_at);
    const effective_from = (try json.optionalTimestamp(allocator, raw.data_od)) orelse return error.InvalidData;
    errdefer allocator.free(effective_from);
    const effective_to = (try json.optionalTimestamp(allocator, raw.data_do)) orelse return error.InvalidData;
    errdefer allocator.free(effective_to);
    const warning_id = try warnings.hydroIdentity(allocator, raw.biuro orelse "", raw.numer orelse "", published_at);
    errdefer allocator.free(warning_id);
    const event = try allocator.dupe(u8, raw.zdarzenie orelse return error.InvalidData);
    errdefer allocator.free(event);
    const office = try allocator.dupe(u8, raw.biuro orelse "");
    errdefer allocator.free(office);
    const content = try allocator.dupe(u8, raw.przebieg orelse return error.InvalidData);
    errdefer allocator.free(content);
    const comment = try json.optionalText(allocator, raw.komentarz);
    errdefer {
        if (comment) |value| allocator.free(value);
    }
    const areas = try parseHydroAreas(allocator, raw.obszary orelse &.{});
    errdefer warnings.deinitAreas(allocator, areas);

    return .{
        .source = .hydro,
        .warning_id = warning_id,
        .event = event,
        .severity = try json.optionalInt(raw.@"stopień"),
        .probability_percent = try json.optionalInt(raw.prawdopodobienstwo),
        .office = office,
        .published_at = published_at,
        .effective_from = effective_from,
        .effective_to = effective_to,
        .content = content,
        .comment = comment,
        .areas = areas,
    };
}

/// Hydrological areas expand into one row per basin code; an area without
/// basin codes still yields a single row describing the voivodeship.
fn parseHydroAreas(allocator: std.mem.Allocator, obszary: []const RawHydroArea) Error![]warnings.Area {
    var areas: std.ArrayList(warnings.Area) = .empty;
    errdefer {
        warnings.deinitAreas(allocator, areas.items);
        areas.deinit(allocator);
    }
    for (obszary) |obszar| {
        const basins = obszar.kod_zlewni orelse &.{};
        if (basins.len == 0) {
            try areas.append(allocator, .{});
            const area = &areas.items[areas.items.len - 1];
            area.voivodeship = try json.optionalText(allocator, obszar.wojewodztwo);
            area.description = try json.optionalText(allocator, obszar.opis);
            continue;
        }
        for (basins) |basin| {
            try areas.append(allocator, .{});
            const area = &areas.items[areas.items.len - 1];
            area.voivodeship = try json.optionalText(allocator, obszar.wojewodztwo);
            area.description = try json.optionalText(allocator, obszar.opis);
            area.basin_code = try allocator.dupe(u8, basin);
        }
    }
    return areas.toOwnedSlice(allocator);
}

const meteo_fixture =
    \\[{"id":"Sk20260916094336328","nazwa_zdarzenia":"Intensywne opady deszczu","stopien":"1","prawdopodobienstwo":"80","obowiazuje_do":"2026-09-17 07:00:00","obowiazuje_od":"2026-09-16 23:00:00","opublikowano":"2026-09-16 11:43:00","tresc":"Prognozowane są opady deszczu.","komentarz":"Brak.","biuro":"Centralne Biuro Prognoz Meteorologicznych w Warszawie","teryt":["2415","2467","1602"]}]
;

const hydro_fixture =
    \\[{"opublikowano":"2026-05-17 08:45:07","stopień":"-1","data_od":"2026-05-17 08:45:56","data_do":"9999-12-31 23:59:59","prawdopodobienstwo":"90","numer":"31","biuro":"Biuro Prognoz Hydrologicznych we Wrocławiu","zdarzenie":"Susza hydrologiczna","przebieg":"Niskie przepływy wody.","komentarz":"Brak.","obszary":[{"wojewodztwo":"wielkopolskie","opis":"wielkopolskie, Kanał Mosiński","kod_zlewni":["Z_P_WP_1856","R_P_WP_18"]},{"wojewodztwo":"opolskie","opis":"opolskie, Warta górna"}]}]
;

test "parses meteorological warnings with their TERYT counties" {
    const items = try parseMeteo(std.testing.allocator, meteo_fixture);
    defer warnings.deinitWarnings(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    const warning = items[0];
    try std.testing.expectEqual(warnings.Source.meteo, warning.source);
    try std.testing.expectEqualStrings("Sk20260916094336328", warning.warning_id);
    try std.testing.expectEqualStrings("Intensywne opady deszczu", warning.event);
    try std.testing.expectEqual(@as(?i16, 1), warning.severity);
    try std.testing.expectEqual(@as(?i16, 80), warning.probability_percent);
    try std.testing.expectEqualStrings("2026-09-16 23:00:00", warning.effective_from);
    try std.testing.expectEqualStrings("2026-09-17 07:00:00", warning.effective_to);
    try std.testing.expect(warning.comment == null);
    try std.testing.expectEqual(@as(usize, 3), warning.areas.len);
    try std.testing.expectEqualStrings("2415", warning.areas[0].teryt.?);
    try std.testing.expectEqualStrings("1602", warning.areas[2].teryt.?);
    try std.testing.expect(warning.areas[0].basin_code == null);
}

test "parses hydrological warnings and expands their basins" {
    const items = try parseHydro(std.testing.allocator, hydro_fixture);
    defer warnings.deinitWarnings(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    const warning = items[0];
    try std.testing.expectEqual(warnings.Source.hydro, warning.source);
    try std.testing.expectEqualStrings("Biuro Prognoz Hydrologicznych we Wrocławiu#31#2026-05-17 08:45:07", warning.warning_id);
    try std.testing.expectEqual(@as(?i16, -1), warning.severity);
    try std.testing.expectEqualStrings("9999-12-31 23:59:59", warning.effective_to);
    try std.testing.expectEqual(@as(usize, 3), warning.areas.len);
    try std.testing.expectEqualStrings("wielkopolskie", warning.areas[0].voivodeship.?);
    try std.testing.expectEqualStrings("Z_P_WP_1856", warning.areas[0].basin_code.?);
    try std.testing.expectEqualStrings("R_P_WP_18", warning.areas[1].basin_code.?);
    try std.testing.expect(warning.areas[2].basin_code == null);
    try std.testing.expectEqualStrings("opolskie", warning.areas[2].voivodeship.?);
}

test "accepts an empty warning list" {
    const items = try parseMeteo(std.testing.allocator, "[]");
    defer warnings.deinitWarnings(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "skips malformed warnings but keeps valid ones" {
    const body =
        \\[{"id":"broken","nazwa_zdarzenia":"Bez czasu","stopien":"1","biuro":"CBPM","tresc":"x","opublikowano":"nope","obowiazuje_od":"2026-09-16 23:00:00","obowiazuje_do":"2026-09-17 07:00:00"},
        \\ {"id":"Sk1","nazwa_zdarzenia":"Silny wiatr","stopien":"2","prawdopodobienstwo":"70","obowiazuje_do":"2026-09-17 07:00:00","obowiazuje_od":"2026-09-16 23:00:00","opublikowano":"2026-09-16 11:43:00","tresc":"Silny wiatr.","komentarz":"Brak.","biuro":"CBPM","nieznane":"ok"}]
    ;
    const items = try parseMeteo(std.testing.allocator, body);
    defer warnings.deinitWarnings(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Sk1", items[0].warning_id);
    try std.testing.expectEqual(@as(?i16, 2), items[0].severity);
}

test "rejects bodies that are not warning arrays" {
    try std.testing.expectError(error.InvalidData, parseMeteo(std.testing.allocator, "{\"error\":true}"));
    try std.testing.expectError(error.InvalidData, parseHydro(std.testing.allocator, "not json"));
}
