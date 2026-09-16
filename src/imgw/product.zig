//! One template for every IMGW product.
//!
//! A product file declares its endpoint, its private wire struct and how to map
//! one raw record into the domain model, then instantiates this template. The
//! plumbing — HTTP transport, JSON-array decoding, per-batch skip reporting and
//! partial-batch cleanup — is written once here.

const std = @import("std");
const Io = std.Io;
const value = @import("value.zig");
const http = @import("http.zig");
const records = @import("records.zig");

pub const Error = value.Error;

/// `parse_record` maps one wire record and `deinit_items` releases the items of
/// a decoded batch without releasing the slice itself, which the decoder owns.
pub fn Product(
    comptime Item: type,
    comptime Raw: type,
    comptime endpoint: []const u8,
    comptime parse_record: fn (std.mem.Allocator, Raw) Error!Item,
    comptime deinit_items: fn (std.mem.Allocator, []Item) void,
    comptime options: records.Options,
) type {
    return struct {
        /// Decodes a response body. The returned slice and every item in it are
        /// owned by `allocator`.
        pub fn parse(allocator: std.mem.Allocator, body: []const u8) Error![]Item {
            return records.decode(Item, Raw, parse_record, deinit_items, allocator, body, options);
        }

        /// Fetches the product endpoint and decodes it. The caller owns the
        /// returned slice.
        pub fn fetch(allocator: std.mem.Allocator, io: Io) Error![]Item {
            return http.fetchParsed([]Item, allocator, io, endpoint, parse);
        }
    };
}
