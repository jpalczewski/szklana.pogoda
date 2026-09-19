//! Fetching, caching and decoding Open-Meteo's forecast.
//!
//! Unlike Antistorm, Open-Meteo needs no city table — any latitude/longitude
//! is a valid request — so this module resolves nothing, it only fetches and
//! caches. A `Forecast` (`model.zig`) owns several strings (the current
//! reading's time, each day's date, sunrise and sunset, and each hour's
//! time), so the cache keeps the downloaded JSON body rather than a decoded
//! `Forecast`: a cache hit re-runs `parse` on a duplicated copy of the body,
//! which is one `allocator.dupe` instead of a deep copy of the whole string
//! tree. Readings are cached per grid cell for `ttl_seconds`, because the
//! underlying forecast model does not change every request.
//!
//! The module is a pure client: it depends on the domain model and the
//! shared transport (`http_fetch.zig`) and nothing else.

const std = @import("std");
const Io = std.Io;

const http_fetch = @import("../http_fetch.zig");
const metrics = @import("../metrics/mod.zig");
const model = @import("model.zig");

pub const Forecast = model.Forecast;
pub const Current = model.Current;
pub const Day = model.Day;
pub const Hour = model.Hour;

pub const Error = std.mem.Allocator.Error || error{
    /// The endpoint answered with something that is not the documented shape.
    InvalidData,
    /// The endpoint could not be reached or answered with a non-200 status.
    NetworkUnavailable,
    /// The requested latitude or longitude is not a valid coordinate.
    InvalidCoordinates,
};

pub const endpoint = "https://api.open-meteo.com/v1/forecast";

/// Fixed for this first slice; not yet exposed as a client option.
pub const forecast_days: u8 = 7;

/// How many hourly readings follow, counted from the current hour. With
/// `forecast_hours` Open-Meteo starts `hourly` at the current hour instead of
/// at midnight, and it leaves `daily` at `forecast_days`.
pub const forecast_hours: u8 = 24;

/// How many grid cell readings stay cached.
pub const cache_capacity: usize = 64;

const RawCurrent = struct {
    time: []const u8,
    temperature_2m: f64,
    apparent_temperature: f64,
    relative_humidity_2m: f64,
    precipitation: f64,
    weather_code: f64,
    wind_speed_10m: f64,
    wind_direction_10m: f64,
};

const RawDaily = struct {
    time: []const []const u8,
    weather_code: []const f64,
    temperature_2m_max: []const f64,
    temperature_2m_min: []const f64,
    precipitation_sum: []const f64,
    precipitation_probability_max: []const f64,
    sunrise: []const []const u8,
    sunset: []const []const u8,
};

const RawHourly = struct {
    time: []const []const u8,
    temperature_2m: []const f64,
    /// Open-Meteo prints `null` for an hour it has no probability for.
    precipitation_probability: []const ?f64,
    precipitation: []const f64,
    weather_code: []const f64,
    wind_speed_10m: []const f64,
    wind_direction_10m: []const f64,
};

/// The field names mirror Open-Meteo's JSON keys exactly, because `std.json`
/// derives them from the struct fields. They must stay in sync with the
/// `current=`/`daily=`/`hourly=` variable lists `Client.urlFor` sends, since the API
/// echoes back exactly the variables that were requested. Every number is
/// decoded as `f64` regardless of how Open-Meteo happens to print it (some
/// fields are documented as integers), and rounded down to its domain type
/// in `parse`.
const Raw = struct {
    latitude: f64,
    longitude: f64,
    current: ?RawCurrent = null,
    daily: ?RawDaily = null,
    hourly: ?RawHourly = null,
};

/// Transport for one response body, injectable so tests never reach the
/// network. It owns the returned bytes.
pub const Fetch = *const fn (std.mem.Allocator, Io, []const u8) Error![]u8;

/// The cache key: coordinates rounded to two decimal places (roughly 1.1 km),
/// in the ballpark of Open-Meteo's own model resolution. Two nearby requests
/// sharing a cached body is the intended behaviour, not a bug.
const GridKey = struct {
    lat_hundredths: i32,
    lon_hundredths: i32,
};

fn gridKey(latitude: f64, longitude: f64) GridKey {
    return .{
        .lat_hundredths = @intFromFloat(@round(latitude * 100)),
        .lon_hundredths = @intFromFloat(@round(longitude * 100)),
    };
}

/// One cached grid cell: the raw response body, not a decoded forecast (see
/// the module comment for why).
const Entry = struct {
    key: GridKey,
    fetched_at_seconds: i64 = 0,
    body: []u8,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// How long one grid cell's body is reused, in seconds.
    ttl_seconds: u64,
    fetch: Fetch = &httpFetch,
    /// Where lookups and downloads are reported; null reports nothing.
    metrics: ?*metrics.Registry = null,
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: Io, ttl_seconds: u64) Client {
        return .{ .allocator = allocator, .io = io, .ttl_seconds = ttl_seconds };
    }

    pub fn deinit(self: *Client) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Resolves the forecast for `latitude`/`longitude`, from the cache while
    /// the grid cell's body is younger than `ttl_seconds`. The forecast is
    /// built with `allocator` (not `self.allocator`, which only backs the
    /// cache), so the caller can release it with an allocator of its own —
    /// a per-request arena, say — and releases it with `Forecast.deinit`.
    pub fn get(self: *Client, allocator: std.mem.Allocator, latitude: f64, longitude: f64) Error!Forecast {
        try validateCoordinates(latitude, longitude);
        const key = gridKey(latitude, longitude);

        // The lock is taken once for the cached body and released before the
        // request, so a slow endpoint never blocks another cell's lookup.
        self.mutex.lockUncancelable(self.io);
        if (self.cachedBody(key, nowSeconds(self.io))) |cached| {
            self.mutex.unlock(self.io);
            self.reportCache(.hit);
            defer self.allocator.free(cached.body);
            var forecast = try parse(allocator, cached.body);
            forecast.fetched_age_seconds = cached.age_seconds;
            return forecast;
        }
        self.mutex.unlock(self.io);
        self.reportCache(.miss);

        const url = try self.urlFor(latitude, longitude);
        defer self.allocator.free(url);
        const timer: metrics.Timer = .start(self.io);
        const body = self.fetch(self.allocator, self.io, url) catch |err| {
            self.reportFailure(timer, err);
            return err;
        };
        defer self.allocator.free(body);

        self.remember(key, body, nowSeconds(self.io));
        const forecast = parse(allocator, body) catch |err| {
            self.reportFailure(timer, err);
            return err;
        };
        self.reportUpstream(timer, .succeeded);
        return forecast;
    }

    fn reportCache(self: *Client, result: metrics.CacheResult) void {
        if (self.metrics) |registry| registry.cacheLookup(.forecast, result);
    }

    fn reportUpstream(self: *Client, timer: metrics.Timer, result: metrics.UpstreamResult) void {
        if (self.metrics) |registry| registry.upstreamRequest(.openmeteo, result, timer.elapsedNs(self.io));
    }

    /// Only an unreachable endpoint or unusable data is the upstream's
    /// failure; running out of memory is ours and is not reported as one.
    fn reportFailure(self: *Client, timer: metrics.Timer, err: Error) void {
        switch (err) {
            error.NetworkUnavailable => self.reportUpstream(timer, .network_error),
            error.InvalidData => self.reportUpstream(timer, .invalid_data),
            else => {},
        }
    }

    /// The request URL for one location. Every variable list here has to
    /// match `RawCurrent`/`RawDaily`/`RawHourly`.
    pub fn urlFor(self: *Client, latitude: f64, longitude: f64) Error![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}?latitude={d:.4}&longitude={d:.4}&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,sunrise,sunset&hourly=temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m,wind_direction_10m&timezone=Europe%2FWarsaw&forecast_days={d}&forecast_hours={d}",
            .{ endpoint, latitude, longitude, forecast_days, forecast_hours },
        );
    }

    /// A cached body younger than the TTL, or null. The body is duplicated so
    /// the caller owns a copy a later eviction cannot invalidate. The caller
    /// holds the lock.
    fn cachedBody(self: *Client, key: GridKey, now_seconds: i64) ?struct { body: []u8, age_seconds: u64 } {
        for (self.entries.items) |entry| {
            if (!std.meta.eql(entry.key, key)) continue;
            const age = if (now_seconds > entry.fetched_at_seconds) now_seconds - entry.fetched_at_seconds else 0;
            if (age > self.ttl_seconds) return null;
            const body = self.allocator.dupe(u8, entry.body) catch return null;
            return .{ .body = body, .age_seconds = @intCast(age) };
        }
        return null;
    }

    /// Stores a copy of `body` under `key`, replacing that grid cell's
    /// previous entry and evicting the oldest one when the cache is full.
    fn remember(self: *Client, key: GridKey, body: []const u8, now_seconds: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const stored_body = self.allocator.dupe(u8, body) catch |err| {
            // The reading is still answered; only keeping it for the next
            // request failed.
            std.log.warn("forecast cache insert failed: {t}", .{err});
            return;
        };
        const stored: Entry = .{ .key = key, .fetched_at_seconds = now_seconds, .body = stored_body };

        for (self.entries.items, 0..) |existing, index| {
            if (!std.meta.eql(existing.key, key)) continue;
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
            std.log.warn("forecast cache insert failed: {t}", .{err});
            self.allocator.free(stored.body);
        };
    }
};

fn validateCoordinates(latitude: f64, longitude: f64) Error!void {
    if (!std.math.isFinite(latitude) or !std.math.isFinite(longitude)) return error.InvalidCoordinates;
    if (latitude < -90 or latitude > 90) return error.InvalidCoordinates;
    if (longitude < -180 or longitude > 180) return error.InvalidCoordinates;
}

/// Decodes one Open-Meteo response. `current`, `daily` and `hourly` are all
/// required — this client always requests them — and every daily and hourly
/// array has to agree with its `time` array in length, so one truncated field
/// cannot silently misalign a day's or an hour's numbers with another one's
/// time.
pub fn parse(allocator: std.mem.Allocator, body: []const u8) Error!Forecast {
    var decoded = std.json.parseFromSlice(Raw, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidData;
    defer decoded.deinit();

    const raw_current = decoded.value.current orelse return error.InvalidData;
    const raw_daily = decoded.value.daily orelse return error.InvalidData;
    const raw_hourly = decoded.value.hourly orelse return error.InvalidData;

    const day_count = raw_daily.time.len;
    if (raw_daily.weather_code.len != day_count or
        raw_daily.temperature_2m_max.len != day_count or
        raw_daily.temperature_2m_min.len != day_count or
        raw_daily.precipitation_sum.len != day_count or
        raw_daily.precipitation_probability_max.len != day_count or
        raw_daily.sunrise.len != day_count or
        raw_daily.sunset.len != day_count) return error.InvalidData;

    const current_time = try allocator.dupe(u8, raw_current.time);
    errdefer allocator.free(current_time);

    const days = try allocator.alloc(Day, day_count);
    errdefer allocator.free(days);
    var built: usize = 0;
    errdefer model.deinitDays(allocator, days[0..built]);

    while (built < day_count) : (built += 1) {
        const date = try allocator.dupe(u8, raw_daily.time[built]);
        errdefer allocator.free(date);
        const sunrise = try allocator.dupe(u8, raw_daily.sunrise[built]);
        errdefer allocator.free(sunrise);
        const sunset = try allocator.dupe(u8, raw_daily.sunset[built]);
        errdefer allocator.free(sunset);

        days[built] = .{
            .date = date,
            .weather_code = clampCode(raw_daily.weather_code[built]),
            .temperature_min_c = raw_daily.temperature_2m_min[built],
            .temperature_max_c = raw_daily.temperature_2m_max[built],
            .precipitation_sum_mm = raw_daily.precipitation_sum[built],
            .precipitation_chance_percent = clampPercent(raw_daily.precipitation_probability_max[built]),
            .sunrise = sunrise,
            .sunset = sunset,
        };
    }

    const hours = try parseHours(allocator, raw_hourly);
    errdefer {
        model.deinitHours(allocator, hours);
        allocator.free(hours);
    }

    return .{
        .latitude = decoded.value.latitude,
        .longitude = decoded.value.longitude,
        .current = .{
            .time = current_time,
            .temperature_c = raw_current.temperature_2m,
            .apparent_temperature_c = raw_current.apparent_temperature,
            .relative_humidity_percent = clampPercent(raw_current.relative_humidity_2m),
            .precipitation_mm = raw_current.precipitation,
            .weather_code = clampCode(raw_current.weather_code),
            .wind_speed_kmh = raw_current.wind_speed_10m,
            .wind_direction_deg = clampDirection(raw_current.wind_direction_10m),
        },
        .daily = days,
        .hourly = hours,
    };
}

fn parseHours(allocator: std.mem.Allocator, raw: RawHourly) Error![]Hour {
    const hour_count = raw.time.len;
    if (raw.temperature_2m.len != hour_count or
        raw.precipitation_probability.len != hour_count or
        raw.precipitation.len != hour_count or
        raw.weather_code.len != hour_count or
        raw.wind_speed_10m.len != hour_count or
        raw.wind_direction_10m.len != hour_count) return error.InvalidData;

    const hours = try allocator.alloc(Hour, hour_count);
    errdefer allocator.free(hours);
    var built: usize = 0;
    errdefer model.deinitHours(allocator, hours[0..built]);

    while (built < hour_count) : (built += 1) {
        hours[built] = .{
            .time = try allocator.dupe(u8, raw.time[built]),
            .temperature_c = raw.temperature_2m[built],
            .precipitation_chance_percent = if (raw.precipitation_probability[built]) |chance| clampPercent(chance) else null,
            .precipitation_mm = raw.precipitation[built],
            .weather_code = clampCode(raw.weather_code[built]),
            .wind_speed_kmh = raw.wind_speed_10m[built],
            .wind_direction_deg = clampDirection(raw.wind_direction_10m[built]),
        };
    }
    return hours;
}

/// Open-Meteo publishes a WMO weather code, documented as 0-99; anything
/// outside a `u8`'s range is clamped rather than rejected.
fn clampCode(value: f64) u8 {
    return clampedInt(u8, value, 0, 255);
}

/// A percentage; clamped to 0-100 so a malformed reading cannot claim more
/// than certain rain or less than none.
fn clampPercent(value: f64) u8 {
    return clampedInt(u8, value, 0, 100);
}

/// A compass bearing in degrees, 0-359.
fn clampDirection(value: f64) u16 {
    return clampedInt(u16, value, 0, 359);
}

fn clampedInt(comptime T: type, value: f64, min: T, max: T) T {
    if (!std.math.isFinite(value)) return min;
    const bounded = std.math.clamp(@round(value), @as(f64, @floatFromInt(min)), @as(f64, @floatFromInt(max)));
    return @intFromFloat(bounded);
}

fn nowSeconds(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

/// The production transport, shared with every other source module.
fn httpFetch(allocator: std.mem.Allocator, io: Io, url: []const u8) Error![]u8 {
    return http_fetch.get(allocator, io, url);
}

/// The `hourly` member of a response, with the leading comma so it can follow
/// a `daily` member. The middle hour has no probability.
const hourly_json =
    \\,"hourly":{"time":["2026-09-18T14:00","2026-09-18T15:00","2026-09-18T16:00"],"temperature_2m":[18.4,19.1,18.7],"precipitation_probability":[10,null,40],"precipitation":[0.0,0.0,0.3],"weather_code":[3,2,61],"wind_speed_10m":[11.2,12.0,9.5],"wind_direction_10m":[240,250,260]}
;

const fixture_body =
    \\{"latitude":52.25,"longitude":21.0,"current":{"time":"2026-09-18T14:00","temperature_2m":18.4,"apparent_temperature":17.9,"relative_humidity_2m":63,"precipitation":0.0,"weather_code":3,"wind_speed_10m":11.2,"wind_direction_10m":240},"daily":{"time":["2026-09-18","2026-09-19","2026-09-20"],"weather_code":[3,61,2],"temperature_2m_max":[19.5,17.0,20.1],"temperature_2m_min":[10.1,9.4,11.0],"precipitation_sum":[0.0,4.2,0.1],"precipitation_probability_max":[10,80,20],"sunrise":["2026-09-18T06:15","2026-09-19T06:17","2026-09-20T06:18"],"sunset":["2026-09-18T19:02","2026-09-19T19:00","2026-09-20T18:57"]}
++ hourly_json ++
    "}";

test "parses the documented payload" {
    const forecast = try parse(std.testing.allocator, fixture_body);
    defer forecast.deinit(std.testing.allocator);

    try std.testing.expectApproxEqAbs(@as(f64, 52.25), forecast.latitude, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 21.0), forecast.longitude, 0.0001);
    try std.testing.expectEqualStrings("2026-09-18T14:00", forecast.current.time);
    try std.testing.expectApproxEqAbs(@as(f64, 18.4), forecast.current.temperature_c, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 17.9), forecast.current.apparent_temperature_c, 0.0001);
    try std.testing.expectEqual(@as(u8, 63), forecast.current.relative_humidity_percent);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), forecast.current.precipitation_mm, 0.0001);
    try std.testing.expectEqual(@as(u8, 3), forecast.current.weather_code);
    try std.testing.expectApproxEqAbs(@as(f64, 11.2), forecast.current.wind_speed_kmh, 0.0001);
    try std.testing.expectEqual(@as(u16, 240), forecast.current.wind_direction_deg);

    try std.testing.expectEqual(@as(usize, 3), forecast.daily.len);
    try std.testing.expectEqualStrings("2026-09-19", forecast.daily[1].date);
    try std.testing.expectEqual(@as(u8, 61), forecast.daily[1].weather_code);
    try std.testing.expectApproxEqAbs(@as(f64, 17.0), forecast.daily[1].temperature_max_c, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 9.4), forecast.daily[1].temperature_min_c, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 4.2), forecast.daily[1].precipitation_sum_mm, 0.0001);
    try std.testing.expectEqual(@as(u8, 80), forecast.daily[1].precipitation_chance_percent);
    try std.testing.expectEqualStrings("2026-09-19T06:17", forecast.daily[1].sunrise);
    try std.testing.expectEqualStrings("2026-09-19T19:00", forecast.daily[1].sunset);

    try std.testing.expectEqual(@as(usize, 3), forecast.hourly.len);
    try std.testing.expectEqualStrings("2026-09-18T14:00", forecast.hourly[0].time);
    try std.testing.expectApproxEqAbs(@as(f64, 19.1), forecast.hourly[1].temperature_c, 0.0001);
    try std.testing.expectEqual(@as(?u8, 10), forecast.hourly[0].precipitation_chance_percent);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), forecast.hourly[2].precipitation_mm, 0.0001);
    try std.testing.expectEqual(@as(u8, 61), forecast.hourly[2].weather_code);
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), forecast.hourly[2].wind_speed_kmh, 0.0001);
    try std.testing.expectEqual(@as(u16, 260), forecast.hourly[2].wind_direction_deg);
}

test "an hour without a probability decodes to null" {
    const forecast = try parse(std.testing.allocator, fixture_body);
    defer forecast.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u8, null), forecast.hourly[1].precipitation_chance_percent);
}

test "a payload without hourly is rejected" {
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator,
        \\{"latitude":52.25,"longitude":21.0,"current":{"time":"2026-09-18T14:00","temperature_2m":18.4,"apparent_temperature":17.9,"relative_humidity_2m":63,"precipitation":0.0,"weather_code":3,"wind_speed_10m":11.2,"wind_direction_10m":240},"daily":{"time":[],"weather_code":[],"temperature_2m_max":[],"temperature_2m_min":[],"precipitation_sum":[],"precipitation_probability_max":[],"sunrise":[],"sunset":[]}}
    ));
}

test "mismatched hourly array lengths are rejected" {
    const body =
        \\{"latitude":52.25,"longitude":21.0,"current":{"time":"2026-09-18T14:00","temperature_2m":18.4,"apparent_temperature":17.9,"relative_humidity_2m":63,"precipitation":0.0,"weather_code":3,"wind_speed_10m":11.2,"wind_direction_10m":240},"daily":{"time":[],"weather_code":[],"temperature_2m_max":[],"temperature_2m_min":[],"precipitation_sum":[],"precipitation_probability_max":[],"sunrise":[],"sunset":[]},"hourly":{"time":["2026-09-18T14:00","2026-09-18T15:00"],"temperature_2m":[18.4],"precipitation_probability":[10,20],"precipitation":[0.0,0.0],"weather_code":[3,3],"wind_speed_10m":[11.2,12.0],"wind_direction_10m":[240,250]}}
    ;
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator, body));
}

test "an out of range hourly number is clamped instead of rejected" {
    const body =
        \\{"latitude":52.25,"longitude":21.0,"current":{"time":"2026-09-18T14:00","temperature_2m":18.4,"apparent_temperature":17.9,"relative_humidity_2m":63,"precipitation":0.0,"weather_code":3,"wind_speed_10m":11.2,"wind_direction_10m":240},"daily":{"time":[],"weather_code":[],"temperature_2m_max":[],"temperature_2m_min":[],"precipitation_sum":[],"precipitation_probability_max":[],"sunrise":[],"sunset":[]},"hourly":{"time":["2026-09-18T14:00"],"temperature_2m":[18.4],"precipitation_probability":[150],"precipitation":[0.0],"weather_code":[300],"wind_speed_10m":[11.2],"wind_direction_10m":[700]}}
    ;
    const forecast = try parse(std.testing.allocator, body);
    defer forecast.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u8, 100), forecast.hourly[0].precipitation_chance_percent);
    try std.testing.expectEqual(@as(u8, 255), forecast.hourly[0].weather_code);
    try std.testing.expectEqual(@as(u16, 359), forecast.hourly[0].wind_direction_deg);
}

test "a payload missing current or daily is rejected" {
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator,
        \\{"latitude":52.25,"longitude":21.0,"daily":{"time":[],"weather_code":[],"temperature_2m_max":[],"temperature_2m_min":[],"precipitation_sum":[],"precipitation_probability_max":[],"sunrise":[],"sunset":[]}}
    ));
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator,
        \\{"latitude":52.25,"longitude":21.0,"current":{"time":"2026-09-18T14:00","temperature_2m":18.4,"apparent_temperature":17.9,"relative_humidity_2m":63,"precipitation":0.0,"weather_code":3,"wind_speed_10m":11.2,"wind_direction_10m":240}}
    ));
}

test "mismatched daily array lengths are rejected" {
    const body =
        \\{"latitude":52.25,"longitude":21.0,"current":{"time":"2026-09-18T14:00","temperature_2m":18.4,"apparent_temperature":17.9,"relative_humidity_2m":63,"precipitation":0.0,"weather_code":3,"wind_speed_10m":11.2,"wind_direction_10m":240},"daily":{"time":["2026-09-18","2026-09-19"],"weather_code":[3],"temperature_2m_max":[19.5,17.0],"temperature_2m_min":[10.1,9.4],"precipitation_sum":[0.0,4.2],"precipitation_probability_max":[10,80],"sunrise":["2026-09-18T06:15","2026-09-19T06:17"],"sunset":["2026-09-18T19:02","2026-09-19T19:00"]}
    ++ hourly_json ++
        "}";
    try std.testing.expectError(error.InvalidData, parse(std.testing.allocator, body));
}

test "an out of range number is clamped instead of rejected" {
    const body =
        \\{"latitude":52.25,"longitude":21.0,"current":{"time":"2026-09-18T14:00","temperature_2m":18.4,"apparent_temperature":17.9,"relative_humidity_2m":140,"precipitation":0.0,"weather_code":300,"wind_speed_10m":11.2,"wind_direction_10m":700},"daily":{"time":["2026-09-18"],"weather_code":[-5],"temperature_2m_max":[19.5],"temperature_2m_min":[10.1],"precipitation_sum":[0.0],"precipitation_probability_max":[150],"sunrise":["2026-09-18T06:15"],"sunset":["2026-09-18T19:02"]}
    ++ hourly_json ++
        "}";
    const forecast = try parse(std.testing.allocator, body);
    defer forecast.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 100), forecast.current.relative_humidity_percent);
    try std.testing.expectEqual(@as(u8, 255), forecast.current.weather_code);
    try std.testing.expectEqual(@as(u16, 359), forecast.current.wind_direction_deg);
    try std.testing.expectEqual(@as(u8, 0), forecast.daily[0].weather_code);
    try std.testing.expectEqual(@as(u8, 100), forecast.daily[0].precipitation_chance_percent);
}

test "urlFor builds the documented query" {
    var client = Client.init(std.testing.allocator, std.testing.io, 900);
    defer client.deinit();
    const url = try client.urlFor(52.2297, 21.0122);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://api.open-meteo.com/v1/forecast?latitude=52.2297&longitude=21.0122&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,sunrise,sunset&hourly=temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m,wind_direction_10m&timezone=Europe%2FWarsaw&forecast_days=7&forecast_hours=24",
        url,
    );
}

/// The fetch the client tests inject: it counts its calls, remembers the URL
/// it was asked for and answers with the documented fixture. The state is a
/// container variable, so the function pointer the client stores has no
/// context of its own.
const counting_fetch = struct {
    var calls: usize = 0;
    var url_buffer: [512]u8 = undefined;
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
        return allocator.dupe(u8, fixture_body);
    }
};

fn unavailable(_: std.mem.Allocator, _: Io, _: []const u8) Error![]u8 {
    return error.NetworkUnavailable;
}

test "coordinates outside range are rejected before any request" {
    counting_fetch.reset();
    var client = Client.init(std.testing.allocator, std.testing.io, 900);
    client.fetch = &counting_fetch.fetch;
    defer client.deinit();

    try std.testing.expectError(error.InvalidCoordinates, client.get(std.testing.allocator, 95, 21));
    try std.testing.expectError(error.InvalidCoordinates, client.get(std.testing.allocator, 52, 200));
    try std.testing.expectError(error.InvalidCoordinates, client.get(std.testing.allocator, std.math.nan(f64), 21));
    try std.testing.expectEqual(@as(usize, 0), counting_fetch.calls);
}

test "a reading inside the TTL comes from the cache" {
    counting_fetch.reset();
    var client = Client.init(std.testing.allocator, std.testing.io, 900);
    client.fetch = &counting_fetch.fetch;
    defer client.deinit();

    const first = try client.get(std.testing.allocator, 52.2297, 21.0122);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), counting_fetch.calls);
    try std.testing.expectEqual(@as(u64, 0), first.fetched_age_seconds);
    try std.testing.expectEqualStrings(
        "https://api.open-meteo.com/v1/forecast?latitude=52.2297&longitude=21.0122&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,sunrise,sunset&hourly=temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m,wind_direction_10m&timezone=Europe%2FWarsaw&forecast_days=7&forecast_hours=24",
        counting_fetch.url(),
    );

    // A nearby coordinate in the same rounded grid cell hits the cache too.
    const second = try client.get(std.testing.allocator, 52.2299, 21.0124);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), counting_fetch.calls);
    try std.testing.expectEqualStrings(first.current.time, second.current.time);
}

test "an entry older than the TTL is downloaded again" {
    counting_fetch.reset();
    var client = Client.init(std.testing.allocator, std.testing.io, 900);
    client.fetch = &counting_fetch.fetch;
    defer client.deinit();

    const first = try client.get(std.testing.allocator, 52.2297, 21.0122);
    defer first.deinit(std.testing.allocator);

    // Backdate the cached entry past the window.
    client.entries.items[0].fetched_at_seconds = nowSeconds(std.testing.io) - 901;

    const second = try client.get(std.testing.allocator, 52.2297, 21.0122);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), counting_fetch.calls);
    try std.testing.expectEqual(@as(u64, 0), second.fetched_age_seconds);
}

test "a second reading of the same grid cell replaces the cached one" {
    counting_fetch.reset();
    var client = Client.init(std.testing.allocator, std.testing.io, 900);
    client.fetch = &counting_fetch.fetch;
    defer client.deinit();

    const first = try client.get(std.testing.allocator, 52.2297, 21.0122);
    first.deinit(std.testing.allocator);
    client.entries.items[0].fetched_at_seconds = 0;

    const second = try client.get(std.testing.allocator, 52.2297, 21.0122);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), counting_fetch.calls);
    try std.testing.expectEqual(@as(usize, 1), client.entries.items.len);
}

test "the cache evicts the oldest grid cell when it is full" {
    var client = Client.init(std.testing.allocator, std.testing.io, 900);
    client.fetch = &unavailable;
    defer client.deinit();

    var i: usize = 0;
    while (i < cache_capacity) : (i += 1) {
        client.remember(.{ .lat_hundredths = @intCast(i), .lon_hundredths = @intCast(i) }, fixture_body, @intCast(i));
    }
    try std.testing.expectEqual(cache_capacity, client.entries.items.len);

    // The entry stamped first is the oldest, so the next insert replaces it.
    client.remember(.{ .lat_hundredths = 1000, .lon_hundredths = 1000 }, fixture_body, cache_capacity + 1);
    try std.testing.expectEqual(cache_capacity, client.entries.items.len);

    const found = client.cachedBody(.{ .lat_hundredths = 1000, .lon_hundredths = 1000 }, cache_capacity + 1);
    try std.testing.expect(found != null);
    std.testing.allocator.free(found.?.body);

    try std.testing.expect(client.cachedBody(.{ .lat_hundredths = 0, .lon_hundredths = 0 }, cache_capacity + 1) == null);
}

test "lookups and downloads are reported to the registry" {
    counting_fetch.reset();
    var registry = metrics.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var client = Client.init(std.testing.allocator, std.testing.io, 900);
    client.fetch = &counting_fetch.fetch;
    client.metrics = &registry;
    defer client.deinit();

    const first = try client.get(std.testing.allocator, 52.2297, 21.0122);
    defer first.deinit(std.testing.allocator);
    const second = try client.get(std.testing.allocator, 52.2297, 21.0122);
    defer second.deinit(std.testing.allocator);

    client.fetch = &unavailable;
    client.entries.items[0].fetched_at_seconds = 0;
    try std.testing.expectError(error.NetworkUnavailable, client.get(std.testing.allocator, 52.2297, 21.0122));

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    for ([_][]const u8{
        "szklana_pogoda_cache_lookups_total{cache=\"forecast\",result=\"miss\"} 2\n",
        "szklana_pogoda_cache_lookups_total{cache=\"forecast\",result=\"hit\"} 1\n",
        "szklana_pogoda_upstream_requests_total{upstream=\"openmeteo\",result=\"succeeded\"} 1\n",
        "szklana_pogoda_upstream_requests_total{upstream=\"openmeteo\",result=\"network_error\"} 1\n",
    }) |expected| {
        try std.testing.expect(std.mem.find(u8, rendered, expected) != null);
    }
}

test "an unusable body is reported as invalid data" {
    var registry = metrics.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var client = Client.init(std.testing.allocator, std.testing.io, 900);
    client.fetch = &notJson;
    client.metrics = &registry;
    defer client.deinit();

    try std.testing.expectError(error.InvalidData, client.get(std.testing.allocator, 52.2297, 21.0122));

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "szklana_pogoda_upstream_requests_total{upstream=\"openmeteo\",result=\"invalid_data\"} 1\n") != null);
}

fn notJson(allocator: std.mem.Allocator, _: Io, _: []const u8) Error![]u8 {
    return allocator.dupe(u8, "<html>bad gateway</html>");
}
