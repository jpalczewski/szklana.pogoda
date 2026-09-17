const std = @import("std");
const value = @import("value.zig");

pub const Error = value.Error;

pub const Options = struct {
    /// Names the product in skip warnings, for example "meteo".
    label: []const u8,
    /// Reject the whole response on the first malformed record instead of
    /// dropping it. Used where a broken payload means a broken endpoint
    /// rather than one bad station.
    strict: bool = false,
};

/// Decodes a JSON array of IMGW records into owned domain items.
///
/// `parseRecord` maps one raw record and `deinitItems` releases the items of a
/// batch without releasing the slice itself, which this decoder owns. Records
/// that fail to decode are skipped unless `options.strict` is set, in which
/// case their error aborts the whole response. A batch that dropped records is
/// reported once, with the number of skipped records out of the total. The
/// returned slice and every item in it are owned by `allocator`.
pub fn decode(
    comptime Item: type,
    comptime Raw: type,
    comptime parseRecord: fn (std.mem.Allocator, Raw) Error!Item,
    comptime deinitItems: fn (std.mem.Allocator, []Item) void,
    allocator: std.mem.Allocator,
    body: []const u8,
    options: Options,
) Error![]Item {
    var parsed = std.json.parseFromSlice([]Raw, allocator, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidData;
    defer parsed.deinit();

    var items: std.ArrayList(Item) = .empty;
    errdefer {
        deinitItems(allocator, items.items);
        items.deinit(allocator);
    }
    var skipped: usize = 0;
    for (parsed.value) |raw| {
        const item = parseRecord(allocator, raw) catch |err| {
            if (options.strict) return err;
            skipped += 1;
            continue;
        };
        try items.append(allocator, item);
    }
    if (skipped > 0) {
        std.log.warn("skipped {d} of {d} invalid IMGW {s} records", .{ skipped, parsed.value.len, options.label });
    }
    return items.toOwnedSlice(allocator);
}

test "decode keeps valid records and skips malformed ones" {
    const Item = struct { id: []u8 };
    const Raw = struct { id: ?[]const u8 = null };
    const fixture = struct {
        fn parseRecord(allocator: std.mem.Allocator, raw: Raw) Error!Item {
            return .{ .id = try value.presentText(allocator, raw.id) };
        }

        fn deinitItems(allocator: std.mem.Allocator, items: []Item) void {
            for (items) |item| allocator.free(item.id);
        }
    };

    const body =
        \\[{"id":"a"},{"id":null},{"id":"b"}]
    ;
    const items = try decode(Item, Raw, fixture.parseRecord, fixture.deinitItems, std.testing.allocator, body, .{ .label = "test" });
    defer {
        fixture.deinitItems(std.testing.allocator, items);
        std.testing.allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("a", items[0].id);
    try std.testing.expectEqualStrings("b", items[1].id);
}

test "decode in strict mode rejects the first malformed record" {
    const Item = struct { id: []u8 };
    const Raw = struct { id: ?[]const u8 = null };
    const fixture = struct {
        fn parseRecord(allocator: std.mem.Allocator, raw: Raw) Error!Item {
            return .{ .id = try value.presentText(allocator, raw.id) };
        }

        fn deinitItems(allocator: std.mem.Allocator, items: []Item) void {
            for (items) |item| allocator.free(item.id);
        }
    };

    const body =
        \\[{"id":"a"},{"id":null}]
    ;
    try std.testing.expectError(
        error.InvalidData,
        decode(Item, Raw, fixture.parseRecord, fixture.deinitItems, std.testing.allocator, body, .{ .label = "test", .strict = true }),
    );
}

test "decode rejects bodies that are not record arrays" {
    const Item = struct { id: []u8 };
    const Raw = struct { id: ?[]const u8 = null };
    const fixture = struct {
        fn parseRecord(allocator: std.mem.Allocator, raw: Raw) Error!Item {
            return .{ .id = try value.presentText(allocator, raw.id) };
        }

        fn deinitItems(allocator: std.mem.Allocator, items: []Item) void {
            for (items) |item| allocator.free(item.id);
        }
    };

    try std.testing.expectError(
        error.InvalidData,
        decode(Item, Raw, fixture.parseRecord, fixture.deinitItems, std.testing.allocator, "{\"error\":true}", .{ .label = "test" }),
    );
}
