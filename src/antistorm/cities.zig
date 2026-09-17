//! Antistorm's published city list, embedded at compile time.
//!
//! The only machine-readable copy Antistorm publishes is the three parallel
//! JavaScript arrays in `js/miastaV1Compr.js`, and the webservice addresses a
//! city by its index there. `cities.json` is that table in one file — name and
//! coordinates per entry, in Antistorm's order, which makes the position of an
//! entry the `city_id` the client sends. Regenerate it with `zig build cities`
//! (which fetches the upstream file) when Antistorm adds or reorders a city;
//! because the index is the id, a reorder shifts every id after it and deserves
//! a look at the diff.
//!
//! The file is embedded and decoded while compiling, so the table is ordinary
//! static data at run time: no file to open, no allocation, no init that can
//! fail. A malformed `cities.json` is a compile error here rather than a broken
//! lookup in production.

const std = @import("std");

pub const City = struct {
    name: []const u8,
    latitude: f64,
    longitude: f64,
};

const source = @embedFile("cities.json");

/// Every city Antistorm publishes, in its own order: the index is the id.
/// Decoding the 28 KiB file costs a few hundred thousand comptime branches,
/// well past the evaluator's default budget, hence the raised quota.
pub const all = blk: {
    @setEvalBranchQuota(1_000_000);
    const cities = parseCityTable(source);
    checkNames(cities);
    break :blk cities;
};

/// The longest published city name, which sizes the fold buffer of one lookup.
pub const max_name_bytes = blk: {
    var longest: usize = 0;
    for (all) |city| longest = @max(longest, city.name.len);
    break :blk longest;
};

/// One entry of the embedded array. Element boundaries come from the braces,
/// which is enough for a file this generator writes itself; a field that cannot
/// be found stops the build with the key named.
fn parseCityTable(comptime text: []const u8) []const City {
    comptime {
        var cities: []const City = &.{};
        var rest = text;
        while (true) {
            const open = std.mem.findScalar(u8, rest, '{') orelse break;
            const close = std.mem.findScalar(u8, rest[open..], '}') orelse
                @compileError("cities.json: unterminated city object");
            const object = rest[open + 1 .. open + close];
            const city: City = .{
                .name = stringField(object, "name"),
                .latitude = numberField(object, "latitude"),
                .longitude = numberField(object, "longitude"),
            };
            if (city.name.len == 0) @compileError("cities.json: a city has no name");
            cities = cities ++ &[_]City{city};
            rest = rest[open + close + 1 ..];
        }
        return cities;
    }
}

/// A name repeats exactly when a lookup is ambiguous, so the file is rejected
/// instead of quietly resolving to the first match.
fn checkNames(comptime cities: []const City) void {
    comptime {
        for (cities, 0..) |city, index| {
            for (cities[index + 1 ..]) |other| {
                if (std.mem.eql(u8, city.name, other.name))
                    @compileError("cities.json: repeated city name \"" ++ city.name ++ "\"");
            }
        }
    }
}

/// The value of `"key"` in one object, verbatim and without the quotes.
fn stringField(comptime object: []const u8, comptime key: []const u8) []const u8 {
    comptime {
        const quoted = "\"" ++ key ++ "\"";
        const at = std.mem.find(u8, object, quoted) orelse
            @compileError("cities.json: a city has no " ++ quoted);
        const after = object[at + quoted.len ..];
        const colon = std.mem.findScalar(u8, after, ':') orelse
            @compileError("cities.json: " ++ quoted ++ " has no value");
        const value = after[colon + 1 ..];
        const first = std.mem.findScalar(u8, value, '"') orelse
            @compileError("cities.json: " ++ quoted ++ " is not a string");
        const second = std.mem.findScalar(u8, value[first + 1 ..], '"') orelse
            @compileError("cities.json: the " ++ quoted ++ " string is not terminated");
        return value[first + 1 .. first + 1 + second];
    }
}

/// The number of `"key"` in one object. The generator writes plain decimals and
/// no exponent, so the number ends at the first byte that is not one.
fn numberField(comptime object: []const u8, comptime key: []const u8) f64 {
    comptime {
        const quoted = "\"" ++ key ++ "\"";
        const at = std.mem.find(u8, object, quoted) orelse
            @compileError("cities.json: a city has no " ++ quoted);
        const after = object[at + quoted.len ..];
        const colon = std.mem.findScalar(u8, after, ':') orelse
            @compileError("cities.json: " ++ quoted ++ " has no value");
        const value = std.mem.trim(u8, after[colon + 1 ..], " \t\r\n");
        var end: usize = 0;
        while (end < value.len and (std.ascii.isDigit(value[end]) or
            value[end] == '-' or value[end] == '.' or value[end] == 'e' or value[end] == 'E' or value[end] == '+')) : (end += 1)
        {}
        if (end == 0) @compileError("cities.json: " ++ quoted ++ " is not a number");
        return std.fmt.parseFloat(f64, value[0..end]) catch
            @compileError("cities.json: " ++ quoted ++ " is not a number: " ++ value[0..end]);
    }
}

pub const count: u16 = all.len;

/// The city at `id`, or null when Antistorm has no city with that id.
pub fn byId(id: u16) ?*const City {
    if (id >= all.len) return null;
    return &all[id];
}

/// A resolved lookup: the position Antistorm addresses the city by and
/// the entry itself.
pub const CityRef = struct {
    id: u16,
    city: *const City,
};

/// Resolves a city name the way a person types it: surrounding
/// whitespace is ignored, case does not matter and Polish diacritics are
/// folded, so "gorzow" finds "Gorzów Wielkopolski".
pub fn find(text: []const u8) ?CityRef {
    const wanted = std.mem.trim(u8, text, " \t");
    if (wanted.len == 0) return null;

    // zlinter-disable-next-line no_undefined - fold() writes exactly wanted.len bytes below before folded[0..wanted.len] is read
    var folded: [max_name_bytes]u8 = undefined;
    if (wanted.len > folded.len) return null;
    const needle = fold(wanted, folded[0..wanted.len]);

    for (all, 0..) |city, index| {
        // zlinter-disable-next-line no_undefined - fold() overwrites candidate before it is read
        var candidate: [max_name_bytes]u8 = undefined;
        if (std.mem.eql(u8, needle, fold(city.name, &candidate))) {
            return .{ .id = @intCast(index), .city = &city };
        }
    }
    return null;
}

/// Folds `input` into `out`, whose capacity is `input.len`; the result is
/// never longer than that. ASCII is lowercased and the Polish diacritics
/// become their unaccented letters, so "Gorzow" and "Gorzów" fold to the
/// same bytes and a lazier spelling still finds the city.
pub fn fold(input: []const u8, out: []u8) []const u8 {
    if (out.len < input.len) return out[0..0];
    var read: usize = 0;
    var write: usize = 0;
    while (read < input.len) {
        const byte = input[read];
        if (byte < 0x80) {
            out[write] = if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
            read += 1;
            write += 1;
            continue;
        }
        // A truncated sequence is copied verbatim, which only means it will
        // not match a city name.
        if (read + 1 >= input.len) break;
        const second = input[read + 1];
        const folded: ?u8 = switch (byte) {
            // 0xc3: ó Ó, ą Ą, ę Ę
            0xc3 => switch (second) {
                0xb3, 0x93 => 'o',
                0x85, 0x84 => 'a',
                0xa9, 0x98 => 'e',
                else => null,
            },
            // 0xc4: ć Ć
            0xc4 => switch (second) {
                0x87, 0x86 => 'c',
                else => null,
            },
            // 0xc5: ł Ł, ń Ń, ś Ś, ź Ź, ż Ż
            0xc5 => switch (second) {
                0x82, 0x81 => 'l',
                0x84, 0x83 => 'n',
                0x9b, 0x9a => 's',
                0xba, 0xb9 => 'z',
                0xbc, 0xbb => 'z',
                else => null,
            },
            else => null,
        };
        if (folded) |ascii| {
            out[write] = ascii;
            read += 2;
            write += 1;
        } else {
            out[write] = byte;
            out[write + 1] = second;
            read += 2;
            write += 2;
        }
    }
    return out[0..write];
}

test "the table matches Antistorm's published ids" {
    try std.testing.expectEqual(@as(usize, count), all.len);
    try std.testing.expectEqualStrings("Aleksandrów Kujawski", byId(0).?.name);
    try std.testing.expectEqualStrings("Zakopane", byId(416).?.name);
    try std.testing.expectEqualStrings("Żywiec", byId(count - 1).?.name);
    try std.testing.expect(byId(count) == null);
    try std.testing.expectApproxEqAbs(@as(f64, 52.88), byId(0).?.latitude, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 19.959), byId(416).?.longitude, 0.0001);
}

test "every embedded city has a name and a position for it" {
    for (all) |city| {
        try std.testing.expect(city.name.len > 0);
        // Poland's bounding box, which catches a swapped or missing coordinate.
        try std.testing.expect(city.latitude > 49 and city.latitude < 55);
        try std.testing.expect(city.longitude > 14 and city.longitude < 25);
    }
}

test "no city name repeats" {
    for (all, 0..) |city, index| {
        for (all[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, city.name, other.name));
        }
    }
}

test "find folds case, whitespace and Polish diacritics" {
    try std.testing.expectEqual(@as(u16, 416), find("Zakopane").?.id);
    try std.testing.expectEqual(@as(u16, 416), find("  zakopane  ").?.id);
    try std.testing.expectEqual(@as(u16, 438), find("ŻYWIEC").?.id);
    try std.testing.expectEqual(@as(u16, 87), find("Gorzow Wielkopolski").?.id);
    try std.testing.expectEqual(@as(u16, 390), find("warszawa").?.id);
    try std.testing.expectEqual(@as(u16, 188), find("ŁÓDŹ").?.id);
    try std.testing.expectEqual(@as(u16, 366), find("świnoujscie").?.id);
}

test "find rejects an unknown or empty name" {
    try std.testing.expect(find("Nieistniejace") == null);
    try std.testing.expect(find("") == null);
    try std.testing.expect(find("   ") == null);
}

test "the embedded table decodes into the documented layout" {
    const sample =
        \\[
        \\  {"name": "Żywiec", "latitude": 49.87, "longitude": 19.18},
        \\  {"name": "Zakopane", "latitude": 49.289, "longitude": 19.959}
        \\]
    ;
    const parsed = comptime blk: {
        @setEvalBranchQuota(10_000);
        break :blk parseCityTable(sample);
    };
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("Żywiec", parsed[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 49.289), parsed[1].latitude, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 19.959), parsed[1].longitude, 0.0001);
}
