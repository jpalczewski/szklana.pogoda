//! The clock both time-keeping domains share.
//!
//! IMGW publishes every timestamp as Europe/Warsaw wall-clock time without an
//! offset, while the store keeps observations in a UTC-suffixed form. This
//! module turns one representation into the other. The Warsaw offset comes from
//! `zeit`, which reads the system timezone database, so daylight saving follows
//! the tzdata rules rather than a copy of them.
//!
//! The database is a runtime file, so a deployment without `zoneinfo` cannot
//! run this: `init` reports the failure, `Clock.offsetAt` falls back to the
//! fixed Polish rule in `warsawOffsetSeconds`, and the README documents the
//! tzdata requirement.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const epoch = std.time.epoch;
const zeit = @import("zeit");

/// The zone every IMGW product is published in.
const warsaw_location: zeit.Location = .@"Europe/Warsaw";

/// The fallback reading of the DST rules. Central European Time is UTC+1,
/// Central European Summer Time is UTC+2, and since 1996 the switch happens at
/// 01:00 UTC on the last Sunday of March and the last Sunday of October. This
/// needs no timezone database, which is what makes it usable when tzdata is
/// missing; `Clock.offsetAt` prefers the database whenever it has one.
pub fn warsawOffsetSeconds(unix_seconds: i64) i64 {
    if (unix_seconds < 0) return std.time.s_per_hour;
    const stamp: epoch.EpochSeconds = .{ .secs = @intCast(unix_seconds) };
    const year_day = stamp.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const month = month_day.month.numeric();
    if (month < 3 or month > 10) return std.time.s_per_hour;
    if (month > 3 and month < 10) return 2 * std.time.s_per_hour;

    const switch_day = lastSundayOfMonth(year_day.year, month);
    const day = @as(i64, month_day.day_index) + 1;
    const hour: i64 = stamp.getDaySeconds().getHoursIntoDay();
    const after_switch = day > switch_day or (day == switch_day and hour >= 1);
    if (month == 3) return if (after_switch) 2 * std.time.s_per_hour else std.time.s_per_hour;
    return if (after_switch) std.time.s_per_hour else 2 * std.time.s_per_hour;
}

/// The wall clock both the updater and the warning queries read.
///
/// A clock without a `zone` answers every question from the fallback rule in
/// `warsawOffsetSeconds`. That is the shape the tests use, so their expectations
/// are the same whatever timezone database the machine happens to carry.
pub const Clock = struct {
    zone: ?zeit.TimeZone = null,

    /// Reads `zoneinfo` for the Warsaw rules. A failure is returned, not
    /// hidden, so the caller can report that the process will fall back.
    pub fn init(allocator: std.mem.Allocator, io: Io) !Clock {
        return .{ .zone = try zeit.loadTimeZone(allocator, io, warsaw_location, .{}) };
    }

    /// The clock that needs no timezone database.
    pub fn fixed() Clock {
        return .{};
    }

    pub fn deinit(self: *Clock) void {
        if (self.zone) |*zone| zone.deinit();
        self.* = undefined;
    }

    /// The offset in force at `unix_seconds`, from the database when there is
    /// one and from the fallback rule otherwise.
    pub fn offsetAt(self: *const Clock, unix_seconds: i64) i64 {
        const zone = self.zone orelse return warsawOffsetSeconds(unix_seconds);
        return @intCast(zone.adjust(unix_seconds).timestamp - unix_seconds);
    }

    /// The instant an IMGW wall-clock reading denotes, in Unix seconds.
    ///
    /// The reading itself is not enough to know which instant it means: on the
    /// night the clock moves back an hour repeats, and the night it moves
    /// forward an hour never happens. Both offsets the reading could carry are
    /// tried, and the one whose adjustment reproduces the printed digits wins.
    /// When the hour is repeated the later occurrence is chosen, and a reading
    /// inside the skipped hour cannot exist at all, so the fallback decides.
    pub fn resolveInstant(self: *const Clock, local: []const u8) error{InvalidData}!i64 {
        const fields = try parseLocalDigits(local);
        const printed: i64 = @intCast(fields.utc);
        if (self.zone == null) return utcInstant(&fields, warsawOffsetSeconds(printed - 2 * std.time.s_per_hour));

        // The two offsets a Warsaw reading can carry, winter first so that a
        // repeated hour keeps its later occurrence.
        const offsets = [_]i64{ std.time.s_per_hour, 2 * std.time.s_per_hour };
        var summer_instant: ?i64 = null;
        for (offsets) |candidate| {
            const instant = utcInstant(&fields, candidate);
            if (self.offsetAt(instant) != candidate) continue;
            // A summer reading is the earlier occurrence of a repeated hour,
            // so it only stands in when no reading carries the winter offset.
            if (candidate == offsets[0]) return instant;
            summer_instant = instant;
        }
        if (summer_instant) |instant| return instant;
        std.log.warn("IMGW reading {s} does not exist in the Warsaw wall clock", .{local});
        return utcInstant(&fields, warsawOffsetSeconds(printed - 2 * std.time.s_per_hour));
    }

    /// Reads the UTC-suffixed form the store keeps, for example
    /// `"2026-09-17T07:00:00Z"`, which denotes an instant wherever it is read.
    pub fn utcEpoch(text: []const u8) error{InvalidData}!i64 {
        if (text.len != 20 or text[10] != 'T' or text[19] != 'Z') return error.InvalidData;
        // The digits are the same as in the IMGW spelling; only the separator
        // and the suffix differ, so the reader is shared.
        // zlinter-disable-next-line no_undefined - every byte is written by the memcpy/assignment below before local is read
        var local: [19]u8 = undefined;
        @memcpy(local[0..10], text[0..10]);
        local[10] = ' ';
        @memcpy(local[11..], text[11..19]);
        return (try parseLocalDigits(&local)).utc;
    }

    /// Renders `unix_seconds` as the Europe/Warsaw wall-clock form IMGW uses,
    /// for example `"2026-09-17 07:00:00"`. The offset moves the instant onto
    /// the wall clock, which is then printed as plain UTC digits.
    pub fn localTime(self: *const Clock, allocator: std.mem.Allocator, unix_seconds: i64) ![]u8 {
        return self.render(allocator, unix_seconds + self.offsetAt(unix_seconds), "%Y-%m-%d %H:%M:%S");
    }

    /// The same rendering for the current instant.
    pub fn localNow(self: *const Clock, allocator: std.mem.Allocator, io: Io) ![]u8 {
        return self.localTime(allocator, Io.Clock.real.now(io).toSeconds());
    }

    /// Renders `unix_seconds` as the ISO-like, UTC-suffixed form the store
    /// keeps, for example `"2026-09-17T07:00:00Z"`.
    pub fn utcText(self: *const Clock, allocator: std.mem.Allocator, unix_seconds: i64) ![]u8 {
        return self.render(allocator, unix_seconds, "%Y-%m-%dT%H:%M:%SZ");
    }

    /// Prints an already shifted instant, so the digits are exactly the ones
    /// the format string names.
    fn render(self: *const Clock, allocator: std.mem.Allocator, unix_seconds: i64, comptime format: []const u8) ![]u8 {
        _ = self;
        var buffer: [32]u8 = undefined;
        var writer = Io.Writer.fixed(&buffer);
        try zeit.instant(.{ .unix_timestamp = unix_seconds }, &zeit.utc).time().strftime(&writer, format);
        return allocator.dupe(u8, writer.buffered());
    }
};

/// The clock `main` installs once at startup, so the warning handlers and the
/// store's one-time migration can read it without threading it through every
/// call. It is written before any listener accepts and never mutated after, so
/// the atomic only publishes a finished value.
var global_clock: Clock = .{};
var global_clock_ready: std.atomic.Value(bool) = .init(false);

/// Loads the timezone database into the process-wide clock. Returns the loading
/// error so the caller can log that the fallback rule is in use.
pub fn initSystemTimeZone(allocator: std.mem.Allocator, io: Io) !void {
    var loaded = try Clock.init(allocator, io);
    errdefer loaded.deinit();
    installClock(loaded);
}

/// Installs a clock without a database. Tests use it, and it is what a
/// deployment without `zoneinfo` ends up with.
pub fn useFallbackClock() void {
    installClock(.{});
}

pub fn clock() *const Clock {
    if (!global_clock_ready.load(.acquire) and builtin.is_test) {
        global_clock = .{};
        global_clock_ready.store(true, .release);
    }
    return &global_clock;
}

fn installClock(source: Clock) void {
    global_clock = source;
    global_clock_ready.store(true, .release);
}

/// The parts of an IMGW wall-clock reading, plus the epoch of its digits read
/// as if they were UTC. The caller applies the zone offset.
const Digits = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    utc: i64,
};

/// Validates `"YYYY-MM-DD HH:MM:SS"` against the calendar and converts the
/// digits to Unix seconds.
fn parseLocalDigits(local: []const u8) error{InvalidData}!Digits {
    if (local.len != 19 or local[4] != '-' or local[7] != '-' or
        local[10] != ' ' or local[13] != ':' or local[16] != ':') return error.InvalidData;

    const year = std.fmt.parseInt(u16, local[0..4], 10) catch return error.InvalidData;
    const month = std.fmt.parseInt(u8, local[5..7], 10) catch return error.InvalidData;
    const day = std.fmt.parseInt(u8, local[8..10], 10) catch return error.InvalidData;
    const hour = std.fmt.parseInt(u8, local[11..13], 10) catch return error.InvalidData;
    const minute = std.fmt.parseInt(u8, local[14..16], 10) catch return error.InvalidData;
    const second = std.fmt.parseInt(u8, local[17..19], 10) catch return error.InvalidData;
    // The epoch calendar starts in 1970 and the format always carries four
    // year digits, so only 1970..9999 can be turned into a date.
    if (year < epoch.epoch_year or year > 9999) return error.InvalidData;
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return error.InvalidData;

    // The day of the year validates against the calendar, which catches both a
    // month that cannot have that many days and a leap day in a common year.
    const day_of_year = daysBeforeMonth(year, month) + day - 1;
    const year_day: epoch.YearAndDay = .{ .year = year, .day = @intCast(day_of_year) };
    const month_day = year_day.calculateMonthDay();
    if (month_day.month.numeric() != month or @as(u64, month_day.day_index) + 1 != day) return error.InvalidData;

    const epoch_day = daysBeforeYear(year) + day_of_year;
    const day_seconds: u64 = @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
    const utc = std.math.cast(i64, epoch_day * std.time.s_per_day + day_seconds) orelse return error.InvalidData;

    return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second, .utc = utc };
}

/// The instant a set of calendar fields denotes once `offset` is subtracted.
fn utcInstant(fields: *const Digits, offset: i64) i64 {
    return fields.utc - offset;
}

fn lastSundayOfMonth(year: epoch.Year, month: u8) i64 {
    const days_in_month: i64 = epoch.getDaysInMonth(year, @enumFromInt(month));
    const first_weekday: i64 = @mod(@as(i64, @intCast(daysBeforeYear(year))) + @as(i64, @intCast(daysBeforeMonth(year, month))) + 4, 7);
    return days_in_month - @mod(first_weekday + days_in_month - 1, 7);
}

/// Days from 1970-01-01 to January 1st of `year`, which is never called with a
/// year the timestamp format cannot express.
fn daysBeforeYear(year: u16) u64 {
    var days: u64 = 0;
    var current: u16 = epoch.epoch_year;
    while (current < year) : (current += 1) {
        days += if (epoch.isLeapYear(current)) 366 else 365;
    }
    return days;
}

/// Days from January 1st to the first day of `month`, in the same year. The
/// caller has already validated that `month` is 1..12.
fn daysBeforeMonth(year: u16, month: u8) u64 {
    var days: u64 = 0;
    var current: u8 = 1;
    while (current < month) : (current += 1) {
        days += epoch.getDaysInMonth(year, @enumFromInt(current));
    }
    return days;
}

test "warsaw offset follows the last Sunday of March and October" {
    try std.testing.expectEqual(@as(i64, 3600), warsawOffsetSeconds(1768478400)); // 2026-01-15 12:00 UTC
    try std.testing.expectEqual(@as(i64, 7200), warsawOffsetSeconds(1784116800)); // 2026-07-15 12:00 UTC
    try std.testing.expectEqual(@as(i64, 3600), warsawOffsetSeconds(1774744200)); // 2026-03-29 00:30 UTC
    try std.testing.expectEqual(@as(i64, 7200), warsawOffsetSeconds(1774746000)); // 2026-03-29 01:00 UTC
    try std.testing.expectEqual(@as(i64, 7200), warsawOffsetSeconds(1792889999)); // 2026-10-25 00:59:59 UTC
    try std.testing.expectEqual(@as(i64, 3600), warsawOffsetSeconds(1792890000)); // 2026-10-25 01:00 UTC
}

test "the fallback clock renders and resolves IMGW readings" {
    const test_clock: Clock = .fixed();
    try std.testing.expectEqual(@as(i64, 1784116800), try test_clock.resolveInstant("2026-07-15 14:00:00"));
    try std.testing.expectEqual(@as(i64, 1768478400), try test_clock.resolveInstant("2026-01-15 13:00:00"));
    try std.testing.expectEqual(@as(i64, 1774746000), try test_clock.resolveInstant("2026-03-29 03:00:00"));

    const winter = try test_clock.localTime(std.testing.allocator, 1768478400);
    defer std.testing.allocator.free(winter);
    try std.testing.expectEqualStrings("2026-01-15 13:00:00", winter);

    const summer = try test_clock.localTime(std.testing.allocator, 1784116800);
    defer std.testing.allocator.free(summer);
    try std.testing.expectEqualStrings("2026-07-15 14:00:00", summer);

    const utc = try test_clock.utcText(std.testing.allocator, 1784116800);
    defer std.testing.allocator.free(utc);
    try std.testing.expectEqualStrings("2026-07-15T12:00:00Z", utc);
}

test "the store form is parsed back to its instant" {
    try std.testing.expectEqual(@as(i64, 1784116800), try Clock.utcEpoch("2026-07-15T12:00:00Z"));
    try std.testing.expectEqual(@as(i64, 0), try Clock.utcEpoch("1970-01-01T00:00:00Z"));
}

test "the database clock and the fallback agree on the switch readings" {
    var database = try Clock.init(std.testing.allocator, std.testing.io);
    defer database.deinit();
    const fallback: Clock = .fixed();

    // Every instant here was read out of the system tzdata. The spring switch
    // is 2026-03-29 01:00 UTC and the autumn one 2026-10-25 01:00 UTC.
    const cases = [_]struct { instant: i64, reading: []const u8 }{
        .{ .instant = 1774742399, .reading = "2026-03-29 00:59:59" },
        .{ .instant = 1774746000, .reading = "2026-03-29 03:00:00" },
        .{ .instant = 1792893599, .reading = "2026-10-25 02:59:59" },
        .{ .instant = 1792893600, .reading = "2026-10-25 03:00:00" },
        .{ .instant = 1768478400, .reading = "2026-01-15 13:00:00" },
        .{ .instant = 1784116800, .reading = "2026-07-15 14:00:00" },
        .{ .instant = 1789537800, .reading = "2026-09-16 07:50:00" },
    };
    for (cases) |case| {
        // The instant has that reading on the Warsaw wall clock, and the
        // reading resolves back to an instant with the same reading.
        const rendered = try database.localTime(std.testing.allocator, case.instant);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(case.reading, rendered);

        const again = try database.localTime(std.testing.allocator, try database.resolveInstant(case.reading));
        defer std.testing.allocator.free(again);
        try std.testing.expectEqualStrings(case.reading, again);
    }

    // The fallback carries the same rule, so it has to name the same offset for
    // every instant of the year, and the same instant for every reading outside
    // the repeated hour.
    var unix: i64 = 1767225600; // 2026-01-01 00:00 UTC
    while (unix < 1798761600) : (unix += 3600) { // through 2026-12-31
        try std.testing.expectEqual(fallback.offsetAt(unix), database.offsetAt(unix));
    }

    const unambiguous = [_][]const u8{
        "2026-03-29 00:59:59", "2026-03-29 03:00:00", "2026-10-25 03:00:00",
        "2026-01-15 13:00:00", "2026-07-15 14:00:00", "2026-09-16 07:50:00",
    };
    for (unambiguous) |reading| {
        try std.testing.expectEqual(try fallback.resolveInstant(reading), try database.resolveInstant(reading));
    }
}

test "malformed timestamps are rejected" {
    try std.testing.expectError(error.InvalidData, Clock.utcEpoch("2026-07-15 12:00:00"));
    try std.testing.expectError(error.InvalidData, Clock.utcEpoch("2026-13-15T12:00:00Z"));
    try std.testing.expectError(error.InvalidData, Clock.utcEpoch("2026-07-15T12:00:00"));
    try std.testing.expectError(error.InvalidData, parseLocalDigits("2026-07-15T12:00:00Z"));
    try std.testing.expectError(error.InvalidData, parseLocalDigits("2026-02-30 12:00:00"));
    try std.testing.expectError(error.InvalidData, parseLocalDigits("1969-12-31 23:59:59"));
}
