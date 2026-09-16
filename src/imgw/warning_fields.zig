const std = @import("std");
const value = @import("value.zig");

pub const Error = value.Error;

/// The validity window and metadata that every IMGW warning carries, whatever
/// its product calls the fields.
pub const Fields = struct {
    published_at: []const u8,
    effective_from: []const u8,
    effective_to: []const u8,
    severity: ?i16,
    probability_percent: ?i16,
    comment: ?[]const u8,

    pub fn deinit(self: Fields, allocator: std.mem.Allocator) void {
        allocator.free(self.published_at);
        allocator.free(self.effective_from);
        allocator.free(self.effective_to);
        if (self.comment) |text| allocator.free(text);
    }
};

/// The same logical fields under the names a specific product uses.
pub const Source = struct {
    published: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    severity: ?[]const u8 = null,
    probability: ?[]const u8 = null,
    comment: ?[]const u8 = null,
};

/// Every warning must carry a publication timestamp and a validity window.
/// Severity and probability stay optional, and missing markers in the comment
/// become null.
pub fn decode(allocator: std.mem.Allocator, source: Source) Error!Fields {
    const published_at = (try value.optionalTimestamp(allocator, source.published)) orelse return error.InvalidData;
    errdefer allocator.free(published_at);
    const effective_from = (try value.optionalTimestamp(allocator, source.from)) orelse return error.InvalidData;
    errdefer allocator.free(effective_from);
    const effective_to = (try value.optionalTimestamp(allocator, source.to)) orelse return error.InvalidData;
    errdefer allocator.free(effective_to);
    const comment = try value.optionalText(allocator, source.comment);
    errdefer {
        if (comment) |text| allocator.free(text);
    }
    return .{
        .published_at = published_at,
        .effective_from = effective_from,
        .effective_to = effective_to,
        .severity = try value.optionalInt(source.severity),
        .probability_percent = try value.optionalInt(source.probability),
        .comment = comment,
    };
}

test "decodes the shared warning validity window" {
    const decoded = try decode(std.testing.allocator, .{
        .published = "2026-09-16 11:43:00",
        .from = "2026-09-16 23:00:00",
        .to = "2026-09-17 07:00:00",
        .severity = "2",
        .probability = "80",
        .comment = "Brak.",
    });
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("2026-09-16 11:43:00", decoded.published_at);
    try std.testing.expectEqualStrings("2026-09-16 23:00:00", decoded.effective_from);
    try std.testing.expectEqualStrings("2026-09-17 07:00:00", decoded.effective_to);
    try std.testing.expectEqual(@as(?i16, 2), decoded.severity);
    try std.testing.expectEqual(@as(?i16, 80), decoded.probability_percent);
    try std.testing.expect(decoded.comment == null);
}

test "rejects a warning without a full validity window" {
    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, .{
        .published = "2026-09-16 11:43:00",
        .from = "2026-09-16 23:00:00",
    }));
    try std.testing.expectError(error.InvalidData, decode(std.testing.allocator, .{
        .published = "nope",
        .from = "2026-09-16 23:00:00",
        .to = "2026-09-17 07:00:00",
    }));
}
