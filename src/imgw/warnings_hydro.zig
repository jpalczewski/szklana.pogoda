const std = @import("std");
const value = @import("value.zig");
const product = @import("product.zig");
const fields = @import("warning_fields.zig");
const warnings = @import("../warnings.zig");

pub const Error = value.Error;

/// Hydrological warnings use accented field names and describe areas nested
/// under `obszary`.
pub const endpoint = "https://danepubliczne.imgw.pl/api/data/warningshydro";

/// Hydrological warnings carry no identifier at all; `numer` is part of the
/// identity synthesized for them. Field names are IMGW's Polish JSON keys; the
/// comments are English glosses.
const Raw = struct {
    opublikowano: ?[]const u8 = null, // published at
    @"stopień": ?[]const u8 = null, // severity level (accented IMGW key)
    data_od: ?[]const u8 = null, // valid from
    data_do: ?[]const u8 = null, // valid until
    prawdopodobienstwo: ?[]const u8 = null, // probability (percent)
    numer: ?[]const u8 = null, // warning number
    biuro: ?[]const u8 = null, // issuing office
    zdarzenie: ?[]const u8 = null, // event
    przebieg: ?[]const u8 = null, // course of the event
    komentarz: ?[]const u8 = null, // comment
    obszary: ?[]const RawArea = null, // warned areas
};

/// Field names are IMGW's Polish JSON keys; the comments are English glosses.
const RawArea = struct {
    wojewodztwo: ?[]const u8 = null, // voivodeship (province)
    opis: ?[]const u8 = null, // description
    kod_zlewni: ?[]const []const u8 = null, // basin codes
};

/// A malformed hydrological warning is skipped rather than discarding the
/// whole response.
const source = product.Product(warnings.Warning, Raw, endpoint, parseRaw, warnings.deinitWarningItems, .{ .label = "hydro warning" });

pub const parse = source.parse;
pub const fetch = source.fetch;

fn parseRaw(allocator: std.mem.Allocator, raw: Raw) Error!warnings.Warning {
    const common = try fields.decode(allocator, .{
        .published = raw.opublikowano,
        .from = raw.data_od,
        .to = raw.data_do,
        .severity = raw.@"stopień",
        .probability = raw.prawdopodobienstwo,
        .comment = raw.komentarz,
    });
    errdefer common.deinit(allocator);

    const office = try allocator.dupe(u8, raw.biuro orelse "");
    errdefer allocator.free(office);
    const warning_id = try warnings.hydroIdentity(allocator, office, raw.numer orelse "", common.published_at);
    errdefer allocator.free(warning_id);
    const event = try value.presentText(allocator, raw.zdarzenie);
    errdefer allocator.free(event);
    const content = try value.presentText(allocator, raw.przebieg);
    errdefer allocator.free(content);
    const areas = try parseAreas(allocator, raw.obszary orelse &.{});
    errdefer warnings.deinitAreas(allocator, areas);

    return .{
        .source = .hydro,
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

/// Hydrological areas expand into one row per basin code; an area without
/// basin codes still yields a single row describing the voivodeship.
fn parseAreas(allocator: std.mem.Allocator, raw_areas: []const RawArea) Error![]warnings.Area {
    var areas: std.ArrayList(warnings.Area) = .empty;
    errdefer {
        warnings.deinitAreas(allocator, areas.items);
        areas.deinit(allocator);
    }
    for (raw_areas) |raw_area| {
        const basins = raw_area.kod_zlewni orelse &.{};
        if (basins.len == 0) {
            try appendArea(allocator, &areas, raw_area, null);
            continue;
        }
        for (basins) |basin| try appendArea(allocator, &areas, raw_area, basin);
    }
    return areas.toOwnedSlice(allocator);
}

fn appendArea(
    allocator: std.mem.Allocator,
    areas: *std.ArrayList(warnings.Area),
    raw_area: RawArea,
    basin: ?[]const u8,
) Error!void {
    try areas.append(allocator, .{});
    const area = &areas.items[areas.items.len - 1];
    area.voivodeship = try value.optionalText(allocator, raw_area.wojewodztwo);
    area.description = try value.optionalText(allocator, raw_area.opis);
    if (basin) |code| area.basin_code = try value.presentText(allocator, code);
}

const fixture =
    \\[{"opublikowano":"2026-05-17 08:45:07","stopień":"-1","data_od":"2026-05-17 08:45:56","data_do":"9999-12-31 23:59:59","prawdopodobienstwo":"90","numer":"31","biuro":"Biuro Prognoz Hydrologicznych we Wrocławiu","zdarzenie":"Susza hydrologiczna","przebieg":"Niskie przepływy wody.","komentarz":"Brak.","obszary":[{"wojewodztwo":"wielkopolskie","opis":"wielkopolskie, Kanał Mosiński","kod_zlewni":["Z_P_WP_1856","R_P_WP_18"]},{"wojewodztwo":"opolskie","opis":"opolskie, Warta górna"}]}]
;

test "parses hydrological warnings and expands their basins" {
    const items = try parse(std.testing.allocator, fixture);
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

test "rejects hydro bodies that are not warning arrays" {
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator, "not json"));
}
