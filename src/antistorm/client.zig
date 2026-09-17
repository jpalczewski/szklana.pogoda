//! Antistorm's public storm and rain probabilities, one city at a time.
//!
//! Antistorm exposes a single documented endpoint,
//! `https://antistorm.eu/webservice.php?id=<city_id>`, and refuses to be
//! bulk-polled: the site asks that a script does not pull every city every
//! fifteen minutes. This module therefore keeps the city table in `cities.zig`
//! (generated, not downloaded at runtime) and caches the reading of each city
//! for `ttl_seconds`, so a UI that watches a handful of favourites still sends
//! roughly one request per city per recomputation.
//!
//! The module is a pure client: it depends on the city table and the transport,
//! never on the weather store.

const std = @import("std");
const Io = std.Io;

const cities = @import("cities.zig");

pub const Error = std.mem.Allocator.Error || error{
    /// The endpoint answered with something that is not the documented object.
    /// This is also what an id Antistorm does not know returns: the service
    /// answers 200 with an HTML paragraph instead of a 404.
    InvalidData,
    /// The endpoint could not be reached or answered with a non-200 status.
    NetworkUnavailable,
    /// The requested city is not in the published table.
    UnknownCity,
};

pub const endpoint = "https://antistorm.eu/webservice.php";

/// How many city readings stay cached. The table has 439 cities; a site that
/// watches more than this many at once is polling harder than the terms allow.
pub const cache_capacity: usize = 64;

/// One city's reading. Field order is fixed, because API tests compare the
/// serialized object.
pub const Reading = struct {
    city_id: u16,
    city_name: []const u8,
    latitude: f64,
    longitude: f64,
    /// Storm probability, 0-255: meaningful above 10, high above 30.
    storm_probability: u8,
    /// Estimated minutes to the storm; 255 means "unknown".
    storm_minutes: u8,
    storm_alarm: bool,
    /// Rain probability, on the same scale as the storm one.
    rain_probability: u8,
    /// Estimated minutes to the rain; 255 means "unknown".
    rain_minutes: u8,
    rain_alarm: bool,
    /// Nonzero while a storm is over the city.
    active_storm: u8,
    /// Seconds since this reading was downloaded; zero for a fresh fetch.
    fetched_age_seconds: u64,

    /// Releases the reading's text fields. The rest is a value.
    pub fn deinit(self: Reading, allocator: std.mem.Allocator) void {
        allocator.free(self.city_name);
    }
};

pub fn deinitReadings(allocator: std.mem.Allocator, readings: []Reading) void {
    for (readings) |reading| reading.deinit(allocator);
    allocator.free(readings);
}

/// The Antistorm response. Every field is optional apart from the city name so
/// one missing number does not discard an otherwise usable reading.
const Raw = struct {
    m: ?[]const u8 = null, // city name
    p_b: ?i16 = null, // storm probability
    t_b: ?i16 = null, // minutes to the storm
    a_b: ?i16 = null, // storm alarm
    p_o: ?i16 = null, // rain probability
    t_o: ?i16 = null, // minutes to the rain
    a_o: ?i16 = null, // rain alarm
    s: ?i16 = null, // active storm over the city
};

/// Transport for one response body, injectable so tests never reach the
/// network. It owns the returned bytes.
pub const Fetch = *const fn (std.mem.Allocator, Io, []const u8) Error![]u8;

/// One city reading: what `parse` decodes and what the cache keeps. `city_name`
/// is owned by whichever holder created it.
pub const Entry = struct {
    id: u16,
    fetched_at_seconds: i64 = 0,
    city_name: []const u8,
    latitude: f64,
    longitude: f64,
    storm_probability: u8,
    storm_minutes: u8,
    storm_alarm: bool,
    rain_probability: u8,
    rain_minutes: u8,
    rain_alarm: bool,
    active_storm: u8,

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.city_name);
    }

    fn reading(self: Entry, age_seconds: u64) Reading {
        return .{
            .city_id = self.id,
            .city_name = self.city_name,
            .latitude = self.latitude,
            .longitude = self.longitude,
            .storm_probability = self.storm_probability,
            .storm_minutes = self.storm_minutes,
            .storm_alarm = self.storm_alarm,
            .rain_probability = self.rain_probability,
            .rain_minutes = self.rain_minutes,
            .rain_alarm = self.rain_alarm,
            .active_storm = self.active_storm,
            .fetched_age_seconds = age_seconds,
        };
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// How long a downloaded reading is reused, in seconds.
    ttl_seconds: u64,
    fetch: Fetch = &httpFetch,
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: Io, ttl_seconds: u64) Client {
        return .{ .allocator = allocator, .io = io, .ttl_seconds = ttl_seconds };
    }

    pub fn deinit(self: *Client) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Resolves `selector` — a city name as a person types it, or the numeric
    /// id Antistorm uses — and answers its reading, from the cache while it is
    /// younger than `ttl_seconds`. The caller owns the returned reading.
    pub fn get(self: *Client, selector: []const u8) Error!Reading {
        const id = try resolve(selector);

        // The lock is taken once for the cached answer and released before the
        // request, so a slow endpoint never blocks another city's lookup.
        self.mutex.lockUncancelable(self.io);
        if (self.cachedRead(self.allocator, id, nowSeconds(self.io))) |reading| {
            self.mutex.unlock(self.io);
            return reading;
        }
        self.mutex.unlock(self.io);

        const url = try self.urlFor(id);
        defer self.allocator.free(url);
        const body = try self.fetch(self.allocator, self.io, url);
        defer self.allocator.free(body);

        var entry = try parse(self.allocator, id, body);
        defer entry.deinit(self.allocator);
        self.remember(entry, nowSeconds(self.io));

        // The cache owns the decoded name from here on, so the caller gets its
        // own copy and may release the reading whenever it likes.
        var reading = entry.reading(0);
        reading.city_name = try self.allocator.dupe(u8, entry.city_name);
        return reading;
    }

    /// The request URL for one city. The endpoint takes the id as a query
    /// parameter and answers HTML, not a 404, when it is missing.
    pub fn urlFor(self: *Client, id: u16) Error![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}?id={d}", .{ endpoint, id });
    }

    /// A cached reading younger than the TTL, or null. The city name is
    /// duplicated into `allocator`, so the caller owns a reading that a later
    /// eviction cannot invalidate. The caller holds the lock.
    fn cachedRead(self: *Client, allocator: std.mem.Allocator, id: u16, now_seconds: i64) ?Reading {
        for (self.entries.items) |entry| {
            if (entry.id != id) continue;
            const age = if (now_seconds > entry.fetched_at_seconds) now_seconds - entry.fetched_at_seconds else 0;
            if (age > self.ttl_seconds) return null;
            const name = allocator.dupe(u8, entry.city_name) catch return null;
            var reading = entry.reading(@intCast(age));
            reading.city_name = name;
            return reading;
        }
        return null;
    }

    /// Stores a copy of `entry` under the given instant, replacing the city's
    /// previous entry and evicting the oldest one when the cache is full. The
    /// copy owns its own name, so `entry` stays the caller's to release.
    fn remember(self: *Client, entry: Entry, now_seconds: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var stored = entry;
        stored.fetched_at_seconds = now_seconds;
        stored.city_name = self.allocator.dupe(u8, entry.city_name) catch |err| {
            // The reading is still answered; only keeping it for the next
            // request failed.
            std.log.warn("storm cache insert failed: {t}", .{err});
            return;
        };

        for (self.entries.items, 0..) |existing, index| {
            if (existing.id != stored.id) continue;
            existing.deinit(self.allocator);
            self.entries.items[index] = stored;
            return;
        }

        if (self.entries.items.len >= cache_capacity) {
            var oldest_index: usize = 0;
            for (self.entries.items, 0..) |existing, index| {
                if (existing.fetched_at_seconds < self.entries.items[oldest_index].fetched_at_seconds) oldest_index = index;
            }
            self.entries.items[oldest_index].deinit(self.allocator);
            _ = self.entries.swapRemove(oldest_index);
        }
        self.entries.append(self.allocator, stored) catch |err| {
            std.log.warn("storm cache insert failed: {t}", .{err});
            self.allocator.free(stored.city_name);
        };
    }
};

/// Resolves a selector. A selector of digits is an id; anything else is a city
/// name. An unknown city is reported as such, never fetched.
pub fn resolve(selector: []const u8) Error!u16 {
    const wanted = std.mem.trim(u8, selector, " \t");
    if (wanted.len == 0) return error.UnknownCity;

    for (wanted) |byte| {
        if (!std.ascii.isDigit(byte)) {
            const found = cities.find(wanted) orelse return error.UnknownCity;
            return found.id;
        }
    }

    const id = std.fmt.parseInt(u16, wanted, 10) catch return error.UnknownCity;
    if (cities.byId(id) == null) return error.UnknownCity;
    return id;
}

/// Decodes one Antistorm response into an entry that carries the coordinates
/// from the embedded table, so an id and its label can never disagree. The
/// returned entry owns its city name.
pub fn parse(allocator: std.mem.Allocator, id: u16, body: []const u8) Error!Entry {
    const city = cities.byId(id) orelse return error.UnknownCity;

    var decoded = std.json.parseFromSlice(Raw, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidData;
    defer decoded.deinit();

    const name = decoded.value.m orelse return error.InvalidData;
    if (name.len == 0) return error.InvalidData;

    return .{
        .id = id,
        .city_name = try allocator.dupe(u8, name),
        .latitude = city.latitude,
        .longitude = city.longitude,
        .storm_probability = scaled(decoded.value.p_b),
        .storm_minutes = scaled(decoded.value.t_b),
        .storm_alarm = decoded.value.a_b orelse 0 != 0,
        .rain_probability = scaled(decoded.value.p_o),
        .rain_minutes = scaled(decoded.value.t_o),
        .rain_alarm = decoded.value.a_o orelse 0 != 0,
        .active_storm = scaled(decoded.value.s),
    };
}

/// Antistorm publishes probabilities and countdowns as 0-255; anything outside
/// the documented range is clamped rather than rejected, and a missing field
/// reads as zero.
fn scaled(value: ?i16) u8 {
    return @intCast(std.math.clamp(value orelse 0, 0, 255));
}

fn nowSeconds(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

/// The production transport. Only a 200 answer with a body is a response; every
/// other outcome is `NetworkUnavailable`.
fn httpFetch(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]u8 {
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

test "parses the documented payload" {
    const entry = try parse(std.testing.allocator, 416, "{\"m\": \"Zakopane\", \"p_b\": 20, \"t_b\": 30, \"a_b\": 1, \"p_o\": 120, \"t_o\": 32, \"a_o\": 1, \"s\": 0}");
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 416), entry.id);
    try std.testing.expectEqualStrings("Zakopane", entry.city_name);
    try std.testing.expectEqual(@as(u8, 20), entry.storm_probability);
    try std.testing.expectEqual(@as(u8, 30), entry.storm_minutes);
    try std.testing.expect(entry.storm_alarm);
    try std.testing.expectEqual(@as(u8, 120), entry.rain_probability);
    try std.testing.expectEqual(@as(u8, 32), entry.rain_minutes);
    try std.testing.expect(entry.rain_alarm);
    try std.testing.expectEqual(@as(u8, 0), entry.active_storm);
    try std.testing.expectApproxEqAbs(@as(f64, 49.289), entry.latitude, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 19.959), entry.longitude, 0.0001);
}

test "an unknown id is what the HTML error page becomes" {
    // Antistorm answers 200 with this paragraph for an id it does not know.
    try std.testing.expectError(
        error.InvalidData,
        parse(std.testing.allocator, 416, "Wyglada na to, ze Twoja usluga wymaga innego API."),
    );
}

test "a payload without the city name is rejected" {
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator, 416, "{\"p_b\": 20}"));
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator, 416, "{\"m\": \"\"}"));
}

test "a missing number is zero and an out of range one is clamped" {
    const entry = try parse(std.testing.allocator, 390, "{\"m\": \"Warszawa\", \"p_b\": 300, \"a_b\": 2}");
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 255), entry.storm_probability);
    try std.testing.expectEqual(@as(u8, 0), entry.storm_minutes);
    try std.testing.expect(entry.storm_alarm);
    try std.testing.expect(!entry.rain_alarm);
    try std.testing.expectEqualStrings("Warszawa", entry.city_name);
}

test "resolve accepts a name, a folded name and a numeric id" {
    try std.testing.expectEqual(@as(u16, 416), try resolve("Zakopane"));
    try std.testing.expectEqual(@as(u16, 416), try resolve("  zakopane "));
    try std.testing.expectEqual(@as(u16, 416), try resolve("416"));
    try std.testing.expectEqual(@as(u16, 87), try resolve("Gorzow Wielkopolski"));
    try std.testing.expectError(error.UnknownCity, resolve("Nieistniejace"));
    try std.testing.expectError(error.UnknownCity, resolve("439"));
    try std.testing.expectError(error.UnknownCity, resolve(""));
}

/// The fetch the client tests inject: it counts its calls, remembers the URL it
/// was asked for and answers with the documented Zakopane payload. The state is
/// a container variable, so the function pointer the client stores has no
/// context of its own.
const CountingFetch = struct {
    var calls: usize = 0;
    var url_buffer: [128]u8 = undefined;
    var url_len: usize = 0;

    fn reset() void {
        calls = 0;
        url_len = 0;
    }

    fn url() []const u8 {
        return url_buffer[0..url_len];
    }

    fn fetch(allocator: std.mem.Allocator, io: Io, url_text: []const u8) Error![]u8 {
        _ = io;
        calls += 1;
        url_len = @min(url_text.len, url_buffer.len);
        @memcpy(url_buffer[0..url_len], url_text[0..url_len]);
        return allocator.dupe(u8, "{\"m\": \"Zakopane\", \"p_b\": 20, \"t_b\": 30, \"a_b\": 1, \"p_o\": 120, \"t_o\": 32, \"a_o\": 1, \"s\": 0}");
    }
};

fn unavailable(_: std.mem.Allocator, _: Io, _: []const u8) Error![]u8 {
    return error.NetworkUnavailable;
}

test "a reading inside the TTL comes from the cache" {
    CountingFetch.reset();
    var client = Client.init(std.testing.allocator, std.testing.io, 300);
    client.fetch = &CountingFetch.fetch;
    defer client.deinit();

    const first = try client.get("Zakopane");
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), CountingFetch.calls);
    try std.testing.expectEqual(@as(u64, 0), first.fetched_age_seconds);
    // The endpoint needs the id: without it Antistorm answers "no_id" as HTML.
    try std.testing.expectEqualStrings("https://antistorm.eu/webservice.php?id=416", CountingFetch.url());

    const second = try client.get("zakopane");
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), CountingFetch.calls);
    try std.testing.expectEqualStrings(first.city_name, second.city_name);

    // A city that does not exist never reaches the endpoint either.
    try std.testing.expectError(error.UnknownCity, client.get("Nieistniejace"));
    try std.testing.expectEqual(@as(usize, 1), CountingFetch.calls);
}

test "an entry older than the TTL is downloaded again" {
    CountingFetch.reset();
    var client = Client.init(std.testing.allocator, std.testing.io, 300);
    client.fetch = &CountingFetch.fetch;
    defer client.deinit();

    const first = try client.get("Zakopane");
    defer first.deinit(std.testing.allocator);

    // Backdate the cached reading past the window.
    client.entries.items[0].fetched_at_seconds = nowSeconds(std.testing.io) - 301;

    const second = try client.get("Zakopane");
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), CountingFetch.calls);
    try std.testing.expectEqual(@as(u64, 0), second.fetched_age_seconds);
}

test "a second reading of the same city replaces the cached one" {
    CountingFetch.reset();
    var client = Client.init(std.testing.allocator, std.testing.io, 300);
    client.fetch = &CountingFetch.fetch;
    defer client.deinit();

    const first = try client.get("Zakopane");
    first.deinit(std.testing.allocator);
    client.entries.items[0].fetched_at_seconds = 0;

    const second = try client.get("Zakopane");
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), CountingFetch.calls);
    try std.testing.expectEqual(@as(usize, 1), client.entries.items.len);
}

test "the cache evicts the oldest city when it is full" {
    var client = Client.init(std.testing.allocator, std.testing.io, 300);
    client.fetch = &unavailable;
    defer client.deinit();

    var id: u16 = 0;
    while (id < cache_capacity) : (id += 1) {
        const entry = try parse(std.testing.allocator, id, "{\"m\": \"city\"}");
        client.remember(entry, id);
        entry.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(cache_capacity, client.entries.items.len);

    // The entry stamped first is the oldest, so the next insert replaces it.
    const newest = try parse(std.testing.allocator, 100, "{\"m\": \"Hrubieszów\"}");
    defer newest.deinit(std.testing.allocator);
    client.remember(newest, cache_capacity + 1);
    try std.testing.expectEqual(cache_capacity, client.entries.items.len);

    const found = client.cachedRead(std.testing.allocator, 100, cache_capacity + 1);
    try std.testing.expect(found != null);
    found.?.deinit(std.testing.allocator);

    try std.testing.expect(client.cachedRead(std.testing.allocator, 0, cache_capacity + 1) == null);
}

test "readings are released by deinitReadings" {
    const readings = try std.testing.allocator.alloc(Reading, 1);
    readings[0] = .{
        .city_id = 416,
        .city_name = try std.testing.allocator.dupe(u8, "Zakopane"),
        .latitude = 49.289,
        .longitude = 19.959,
        .storm_probability = 0,
        .storm_minutes = 255,
        .storm_alarm = false,
        .rain_probability = 0,
        .rain_minutes = 255,
        .rain_alarm = false,
        .active_storm = 0,
        .fetched_age_seconds = 0,
    };
    deinitReadings(std.testing.allocator, readings);
}
