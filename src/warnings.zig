const std = @import("std");

/// IMGW publishes meteorological and hydrological warnings through two
/// separate endpoints that share almost no field names. Both are normalized
/// into this one model so storage, queries and the HTTP API stay source
/// agnostic.
pub const Source = enum {
    meteo,
    hydro,

    pub fn fromQuery(value: []const u8) ?Source {
        inline for (@typeInfo(Source).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, value)) return @field(Source, field.name);
        }
        return null;
    }
};

/// A single warned area. Meteorological warnings use TERYT county codes,
/// hydrological ones use voivodeship plus basin codes.
pub const Area = struct {
    teryt: ?[]const u8 = null,
    voivodeship: ?[]const u8 = null,
    description: ?[]const u8 = null,
    basin_code: ?[]const u8 = null,
};

/// Timestamps mirror IMGW verbatim: `"YYYY-MM-DD HH:MM:SS"` in Europe/Warsaw
/// local time without an offset. `first_seen_at` and `last_seen_at` are filled
/// in by the store and are expressed in the same local-time format.
pub const Warning = struct {
    source: Source,
    warning_id: []const u8,
    revision: u32 = 1,
    event: []const u8,
    severity: ?i16 = null,
    probability_percent: ?i16 = null,
    office: []const u8,
    published_at: []const u8,
    effective_from: []const u8,
    effective_to: []const u8,
    content: []const u8,
    comment: ?[]const u8 = null,
    first_seen_at: []const u8 = "",
    last_seen_at: []const u8 = "",
    areas: []const Area = &.{},
};

/// Hydrological warnings carry no identifier, so identity is derived from the
/// fields IMGW keeps stable for a single warning: issuing office, warning
/// number and publication timestamp.
pub fn hydroIdentity(allocator: std.mem.Allocator, office: []const u8, number: []const u8, published_at: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}#{s}#{s}", .{ office, number, published_at });
}

/// Fingerprints the fields that define a revision of a warning. Any change to
/// the event, its validity window, its text or its areas yields a new hash and
/// therefore a new stored revision.
pub fn contentHash(warning: Warning) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashField(&hasher, @tagName(warning.source));
    hashField(&hasher, warning.event);
    hashField(&hasher, warning.office);
    hashField(&hasher, warning.published_at);
    hashField(&hasher, warning.effective_from);
    hashField(&hasher, warning.effective_to);
    hashField(&hasher, warning.content);
    hashField(&hasher, warning.comment);
    hashOptionalInt(&hasher, warning.severity);
    hashOptionalInt(&hasher, warning.probability_percent);
    for (warning.areas) |area| {
        hasher.update(&[_]u8{0x1e});
        hashField(&hasher, area.teryt);
        hashField(&hasher, area.voivodeship);
        hashField(&hasher, area.description);
        hashField(&hasher, area.basin_code);
    }
    return hasher.final();
}

/// Fields are separated so that concatenated values cannot collide, and the
/// optional integer carries a presence byte so `null` differs from any value.
fn hashField(hasher: *std.hash.Wyhash, field: ?[]const u8) void {
    const text = field orelse {
        hasher.update(&[_]u8{ 0x00, 0xff });
        return;
    };
    hasher.update(text);
    hasher.update(&[_]u8{0x00});
}

fn hashOptionalInt(hasher: *std.hash.Wyhash, value: ?i16) void {
    const number = value orelse {
        hasher.update(&[_]u8{0x00});
        return;
    };
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(i16, &bytes, number, .little);
    hasher.update(&[_]u8{0x01});
    hasher.update(&bytes);
}

/// True while IMGW still lists the warning as valid, that is until
/// `effective_to` passes. `local_now` must come from `timestamps.Clock`, so
/// both sides are in the same Europe/Warsaw wall-clock format.
pub fn isActive(warning: Warning, local_now: []const u8) bool {
    return std.mem.order(u8, warning.effective_to, local_now) != .lt;
}

pub fn deinitWarnings(allocator: std.mem.Allocator, items: []Warning) void {
    deinitWarningItems(allocator, items);
    allocator.free(items);
}

pub fn deinitArea(allocator: std.mem.Allocator, area: Area) void {
    if (area.teryt) |value| allocator.free(value);
    if (area.voivodeship) |value| allocator.free(value);
    if (area.description) |value| allocator.free(value);
    if (area.basin_code) |value| allocator.free(value);
}

pub fn deinitAreas(allocator: std.mem.Allocator, areas: []const Area) void {
    for (areas) |area| deinitArea(allocator, area);
    allocator.free(areas);
}

pub fn deinitWarningItems(allocator: std.mem.Allocator, items: []Warning) void {
    for (items) |item| {
        allocator.free(item.warning_id);
        allocator.free(item.event);
        allocator.free(item.office);
        allocator.free(item.published_at);
        allocator.free(item.effective_from);
        allocator.free(item.effective_to);
        allocator.free(item.content);
        if (item.comment) |comment| allocator.free(comment);
        allocator.free(item.first_seen_at);
        allocator.free(item.last_seen_at);
        deinitAreas(allocator, item.areas);
    }
}

test "active warnings are the ones not yet expired" {
    const warning: Warning = .{
        .source = .meteo,
        .warning_id = "Sk1",
        .event = "Silny wiatr",
        .office = "CBPM",
        .published_at = "2026-09-16 11:43:00",
        .effective_from = "2026-09-16 23:00:00",
        .effective_to = "2026-09-17 07:00:00",
        .content = "tresc",
    };
    try std.testing.expect(isActive(warning, "2026-09-17 07:00:00"));
    try std.testing.expect(!isActive(warning, "2026-09-17 07:00:01"));
}

test "content hash is stable until the warning text changes" {
    const warning: Warning = .{
        .source = .hydro,
        .warning_id = "id",
        .severity = -1,
        .event = "Susza hydrologiczna",
        .office = "BPH Wrocław",
        .published_at = "2026-05-17 08:45:07",
        .effective_from = "2026-05-17 08:45:56",
        .effective_to = "9999-12-31 23:59:59",
        .content = "Niskie przeplywy",
        .areas = &.{.{ .voivodeship = "wielkopolskie", .basin_code = "Z_P_WP_1856" }},
    };
    try std.testing.expectEqual(contentHash(warning), contentHash(warning));

    var changed = warning;
    changed.content = "Niskie przeplywy wody";
    try std.testing.expectEqual(@as(u64, 1), @intFromBool(contentHash(warning) != contentHash(changed)));

    var reseeded = warning;
    reseeded.areas = &.{.{ .voivodeship = "wielkopolskie", .basin_code = "Z_P_WP_1857" }};
    try std.testing.expectEqual(@as(u64, 1), @intFromBool(contentHash(warning) != contentHash(reseeded)));
}

test "hydrological warnings derive an identifier from office, number and timestamp" {
    const identity = try hydroIdentity(std.testing.allocator, "BPH Wrocław", "31", "2026-05-17 08:45:07");
    defer std.testing.allocator.free(identity);
    try std.testing.expectEqualStrings("BPH Wrocław#31#2026-05-17 08:45:07", identity);
}

test "warning sources are parsed from query values" {
    try std.testing.expectEqual(Source.meteo, Source.fromQuery("meteo").?);
    try std.testing.expectEqual(Source.hydro, Source.fromQuery("hydro").?);
    try std.testing.expect(Source.fromQuery("Meteo") == null);
    try std.testing.expect(Source.fromQuery("") == null);
}
