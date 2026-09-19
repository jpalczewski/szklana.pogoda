const std = @import("std");
const value = @import("value.zig");
const product = @import("product.zig");
const fields = @import("warning_fields.zig");
const warnings = @import("../warnings.zig");

pub const Error = value.Error;

/// Meteorological warnings use ASCII field names and TERYT county codes.
pub const endpoint = "https://danepubliczne.imgw.pl/api/data/warningsmeteo";

/// Every field is optional here so that a single malformed record can be
/// skipped instead of discarding the whole response. Field names are IMGW's
/// Polish JSON keys; the comments are English glosses.
const Raw = struct {
    id: ?[]const u8 = null, // warning ID
    nazwa_zdarzenia: ?[]const u8 = null, // event name
    stopien: ?[]const u8 = null, // severity level
    prawdopodobienstwo: ?[]const u8 = null, // probability (percent)
    obowiazuje_do: ?[]const u8 = null, // effective until
    obowiazuje_od: ?[]const u8 = null, // effective from
    opublikowano: ?[]const u8 = null, // published at
    tresc: ?[]const u8 = null, // content
    komentarz: ?[]const u8 = null, // comment
    biuro: ?[]const u8 = null, // issuing office
    teryt: ?[]const []const u8 = null, // TERYT county codes
};

/// Every field is optional in the wire struct, so one malformed warning is
/// skipped instead of discarding the whole response.
const source = product.Product(warnings.Warning, Raw, endpoint, parseRaw, warnings.deinitWarningItems, .{ .label = "meteo warning" });

pub const parse = source.parse;
pub const fetch = source.fetchOrEmpty;

fn parseRaw(allocator: std.mem.Allocator, raw: Raw) Error!warnings.Warning {
    const warning_id = try value.presentText(allocator, raw.id);
    errdefer allocator.free(warning_id);
    const event = try value.presentText(allocator, raw.nazwa_zdarzenia);
    errdefer allocator.free(event);
    const office = try value.presentText(allocator, raw.biuro);
    errdefer allocator.free(office);
    const content = try value.presentText(allocator, raw.tresc);
    errdefer allocator.free(content);
    const common = try fields.decode(allocator, .{
        .published = raw.opublikowano,
        .from = raw.obowiazuje_od,
        .to = raw.obowiazuje_do,
        .severity = raw.stopien,
        .probability = raw.prawdopodobienstwo,
        .comment = raw.komentarz,
    });
    errdefer common.deinit(allocator);
    const areas = try parseAreas(allocator, raw.teryt orelse &.{});
    errdefer warnings.deinitAreas(allocator, areas);

    return .{
        .source = .meteo,
        .warning_id = warning_id,
        .event = event,
        .severity = common.severity,
        .probability_percent = common.probability_percent,
        .office = office,
        .published_at = common.published_at,
        .effective_from = common.effective_from,
        .effective_to = common.effective_to,
        .content = content,
        .comment = common.comment,
        .areas = areas,
    };
}

/// One warned county per TERYT code.
fn parseAreas(allocator: std.mem.Allocator, codes: []const []const u8) Error![]warnings.Area {
    var areas = try allocator.alloc(warnings.Area, codes.len);
    var filled: usize = 0;
    errdefer {
        warnings.deinitAreas(allocator, areas[0..filled]);
        allocator.free(areas);
    }
    for (codes, 0..) |code, index| {
        areas[index] = .{ .teryt = try value.presentText(allocator, code) };
        filled = index + 1;
    }
    return areas;
}

const fixture =
    \\[{"id":"Sk20260916094336328","nazwa_zdarzenia":"Intensywne opady deszczu","stopien":"1","prawdopodobienstwo":"80","obowiazuje_do":"2026-09-17 07:00:00","obowiazuje_od":"2026-09-16 23:00:00","opublikowano":"2026-09-16 11:43:00","tresc":"Prognozowane są opady deszczu.","komentarz":"Brak.","biuro":"Centralne Biuro Prognoz Meteorologicznych w Warszawie","teryt":["2415","2467","1602"]}]
;

test "parses meteorological warnings with their TERYT counties" {
    const items = try parse(std.testing.allocator, fixture);
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

test "skips malformed warnings but keeps valid ones" {
    const body =
        \\[{"id":"broken","nazwa_zdarzenia":"Bez czasu","stopien":"1","biuro":"CBPM","tresc":"x","opublikowano":"nope","obowiazuje_od":"2026-09-16 23:00:00","obowiazuje_do":"2026-09-17 07:00:00"},
        \\ {"id":"Sk1","nazwa_zdarzenia":"Silny wiatr","stopien":"2","prawdopodobienstwo":"70","obowiazuje_do":"2026-09-17 07:00:00","obowiazuje_od":"2026-09-16 23:00:00","opublikowano":"2026-09-16 11:43:00","tresc":"Silny wiatr.","komentarz":"Brak.","biuro":"CBPM","nieznane":"ok"}]
    ;
    const items = try parse(std.testing.allocator, body);
    defer warnings.deinitWarnings(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Sk1", items[0].warning_id);
    try std.testing.expectEqual(@as(?i16, 2), items[0].severity);
}

test "accepts an empty warning list" {
    const items = try parse(std.testing.allocator, "[]");
    defer warnings.deinitWarnings(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "rejects bodies that are not warning arrays" {
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator, "{\"error\":true}"));
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator, "not json"));
}
