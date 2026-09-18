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

/// Fetches `url`. The caller owns the returned bytes.
pub fn get(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    }) catch return error.NetworkUnavailable;
    if (result.status != .ok) return error.NetworkUnavailable;

    return body.toOwnedSlice() catch return error.OutOfMemory;
}
