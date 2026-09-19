//! The one HTTP GET every source module downloads a document with.
//!
//! `imgw/http.zig` and `antistorm/client.zig` used to each carry their own
//! copy of this body; it now lives here so a third source does not have to
//! copy it again. Only a 200 answer with a body is a response: every other
//! outcome is `NetworkUnavailable`. Callers with a wider error set can return
//! this directly, since Zig coerces an error union into any superset of it.

const std = @import("std");
const Io = std.Io;

pub const Error = std.mem.Allocator.Error || error{NetworkUnavailable};

/// What a server answered, whatever the status.
pub const Answer = struct {
    status: std.http.Status,
    /// Owned by the caller.
    body: []u8,
};

/// Fetches `url` and reports the status with the body, for a caller that treats
/// some non-200 answers as data. A request that could not be made at all is
/// `NetworkUnavailable`.
pub fn getAnswer(allocator: std.mem.Allocator, io: Io, url: []const u8) Error!Answer {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    }) catch return error.NetworkUnavailable;

    return .{ .status = result.status, .body = body.toOwnedSlice() catch return error.OutOfMemory };
}

/// Fetches `url`. The caller owns the returned bytes.
pub fn get(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]u8 {
    const answer = try getAnswer(allocator, io, url);
    if (answer.status != .ok) {
        allocator.free(answer.body);
        return error.NetworkUnavailable;
    }
    return answer.body;
}
