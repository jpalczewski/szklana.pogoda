//! Regenerates `src/antistorm/cities.json` from Antistorm's published city
//! table. Antistorm publishes no plain city list: the only machine-readable
//! copy is the three parallel JavaScript arrays in `js/miastaV1Compr.js`, and
//! the webservice id of a city is its index in `miastaArr`. Run it through
//
//     zig build cities
//
// whenever Antistorm adds or reorders a city. The JSON file is committed and
// embedded at compile time, so the build never has to reach the network.

const std = @import("std");
const Io = std.Io;

/// The upstream array file is 13 KiB; this leaves room for growth while
/// keeping a broken or hostile response bounded.
const max_source_bytes = 1024 * 1024;

pub const source_url = "https://antistorm.eu/js/miastaV1Compr.js";

/// One city with its position, in the order Antistorm lists it: the index is
/// the id the webservice expects. `name` points into `Parsed.names`.
pub const City = struct {
    name: []const u8,
    latitude: f64,
    longitude: f64,
};

/// The parsed table: the cities and the one buffer their names live in.
pub const Parsed = struct {
    names: []u8,
    cities: []City,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.names);
        allocator.free(self.cities);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;

    const allocator = init.gpa;
    const source = try readSource(allocator, init.io);
    defer allocator.free(source);

    const parsed = try parseCities(allocator, source);
    defer parsed.deinit(allocator);

    const json = try writeCitiesJson(allocator, parsed.cities);
    defer allocator.free(json);

    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = json });
}

fn readSource(allocator: std.mem.Allocator, io: Io) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const result = client.fetch(.{
        .location = .{ .url = source_url },
        .response_writer = &body.writer,
    }) catch return error.SourceUnavailable;
    if (result.status != .ok) return error.SourceUnavailable;

    const source = try allocator.dupe(u8, body.written());
    if (source.len > max_source_bytes) return error.SourceTooLarge;
    return source;
}

/// Reads the three `new Array(...)` literals and pairs them by index. The
/// generator refuses a source whose arrays disagree in length or repeat a city
/// name: either one would silently shift every id. The names are copied once
/// into one owned buffer, so releasing the result is two frees.
pub fn parseCities(allocator: std.mem.Allocator, source: []const u8) !Parsed {
    const names = try arrayLiteral(allocator, source, "miastaArr");
    defer freeStrings(allocator, names);
    const latitudes = try arrayLiteral(allocator, source, "miastaLatArr");
    defer freeStrings(allocator, latitudes);
    const longitudes = try arrayLiteral(allocator, source, "miastaLngArr");
    defer freeStrings(allocator, longitudes);

    if (names.len == 0) return error.InvalidSource;
    if (latitudes.len != names.len or longitudes.len != names.len) return error.InvalidSource;
    try rejectDuplicateNames(allocator, names);

    var names_total: usize = 0;
    for (names) |name| {
        if (name.len == 0) return error.InvalidSource;
        names_total += name.len + 1;
    }

    const buffer = try allocator.alloc(u8, names_total);
    errdefer allocator.free(buffer);
    const cities = try allocator.alloc(City, names.len);
    errdefer allocator.free(cities);

    var offset: usize = 0;
    for (names, 0..) |name, index| {
        @memcpy(buffer[offset .. offset + name.len], name);
        buffer[offset + name.len] = 0;
        cities[index] = .{
            .name = buffer[offset .. offset + name.len :0],
            .latitude = try std.fmt.parseFloat(f64, latitudes[index]),
            .longitude = try std.fmt.parseFloat(f64, longitudes[index]),
        };
        offset += name.len + 1;
    }
    return .{ .names = buffer, .cities = cities };
}

/// Renders the JSON array the module embeds: one city per line, in Antistorm's
/// order, with no id field because the position is the id. The name goes
/// through `std.json.Stringify`, so a quote or a backslash in a name cannot
/// break the file. The layout is deterministic, so regenerating unchanged
/// upstream data produces no diff.
pub fn writeCitiesJson(allocator: std.mem.Allocator, cities: []const City) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("[\n");
    for (cities, 0..) |city, index| {
        try out.writer.writeAll("  {\"name\": ");
        var json: std.json.Stringify = .{ .writer = &out.writer };
        try json.write(city.name);
        try out.writer.print(", \"latitude\": {d}, \"longitude\": {d}}}", .{ city.latitude, city.longitude });
        try out.writer.writeAll(if (index + 1 < cities.len) ",\n" else "\n");
    }
    try out.writer.writeAll("]\n");

    return out.toOwnedSlice();
}

fn rejectDuplicateNames(allocator: std.mem.Allocator, names: []const []const u8) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (names) |name| {
        const result = try seen.getOrPut(allocator, name);
        if (result.found_existing) return error.InvalidSource;
    }
}

fn freeStrings(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

/// Returns the string literals of `var <name> = new Array(...)`. The upstream
/// file has no escapes and no nested parentheses inside the literals, so the
/// body is everything up to the first closing parenthesis after the call.
fn arrayLiteral(allocator: std.mem.Allocator, source: []const u8, name: []const u8) ![][]const u8 {
    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(allocator);
    try header.appendSlice(allocator, "var ");
    try header.appendSlice(allocator, name);
    try header.appendSlice(allocator, " = new Array(");

    const start = std.mem.indexOf(u8, source, header.items) orelse return error.InvalidSource;
    const body_start = start + header.items.len;
    const body_end = std.mem.indexOfScalar(u8, source[body_start..], ')') orelse return error.InvalidSource;
    const body = source[body_start .. body_start + body_end];

    var literals: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeStrings(allocator, literals.items);
        literals.deinit(allocator);
    }

    var rest = body;
    while (true) {
        const open = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const content_start = open + 1;
        const close = std.mem.indexOfScalar(u8, rest[content_start..], '"') orelse return error.InvalidSource;
        const value = rest[content_start .. content_start + close];
        if (std.mem.indexOfScalar(u8, value, '\\') != null) return error.InvalidSource;
        try literals.append(allocator, try allocator.dupe(u8, value));
        rest = rest[content_start + close + 1 ..];
    }
    return literals.toOwnedSlice(allocator);
}

test "parses the three arrays into cities" {
    const source =
        \\var miastaArr = new Array("Zakopane","Warszawa","Żywiec");
        \\var miastaLatArr = new Array("49.289","52.259","49.685");
        \\var miastaLngArr = new Array("19.959","21.02","19.192");
    ;
    const parsed = try parseCities(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.cities.len);
    try std.testing.expectEqualStrings("Zakopane", parsed.cities[0].name);
    // Names are packed with a terminator each, so the parser can slice them
    // out of one buffer.
    try std.testing.expectEqual(@as(u8, 0), parsed.names[parsed.names.len - 1]);
    try std.testing.expectApproxEqAbs(@as(f64, 52.259), parsed.cities[1].latitude, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 19.192), parsed.cities[2].longitude, 0.0001);
}

test "renders the documented JSON layout" {
    const cities = [_]City{
        .{ .name = "Żywiec", .latitude = 49.685, .longitude = 19.192 },
        .{ .name = "Zakopane", .latitude = 49.289, .longitude = 19.959 },
    };
    const json = try writeCitiesJson(std.testing.allocator, &cities);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        "[\n" ++
            "  {\"name\": \"Żywiec\", \"latitude\": 49.685, \"longitude\": 19.192},\n" ++
            "  {\"name\": \"Zakopane\", \"latitude\": 49.289, \"longitude\": 19.959}\n" ++
            "]\n",
        json,
    );
}

test "renders an empty table" {
    const json = try writeCitiesJson(std.testing.allocator, &.{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[\n]\n", json);
}

test "rejects a repeated city name" {
    const source =
        \\var miastaArr = new Array("Zakopane","Zakopane");
        \\var miastaLatArr = new Array("49.289","49.289");
        \\var miastaLngArr = new Array("19.959","19.959");
    ;
    try std.testing.expectError(error.InvalidSource, parseCities(std.testing.allocator, source));
}

test "rejects arrays of different lengths" {
    const source =
        \\var miastaArr = new Array("Zakopane","Warszawa");
        \\var miastaLatArr = new Array("49.289");
        \\var miastaLngArr = new Array("19.959","21.02");
    ;
    try std.testing.expectError(error.InvalidSource, parseCities(std.testing.allocator, source));
}

test "rejects a source without the arrays" {
    try std.testing.expectError(error.InvalidSource, parseCities(std.testing.allocator, "var other = 1;"));
}
