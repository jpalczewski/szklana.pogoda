//! Antistorm storm and rain probabilities.
//!
//! One module for the public Antistorm endpoint, composed of the generated city
//! table (`cities`) and the client that turns a city selector into a reading
//! (`client`). Nothing here depends on the weather store or on IMGW: Antistorm
//! publishes one JSON object per city and is the only source this module reads.

const std = @import("std");

pub const cities = @import("cities.zig");
pub const client = @import("client.zig");

pub const Client = client.Client;
pub const Reading = client.Reading;
pub const Error = client.Error;

pub fn deinitReadings(allocator: std.mem.Allocator, readings: []Reading) void {
    client.deinitReadings(allocator, readings);
}
