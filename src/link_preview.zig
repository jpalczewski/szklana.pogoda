//! The `<meta>` tags a messenger reads to draw a link preview.
//!
//! A messenger's crawler fetches the page and does not run its script, so the
//! weather a shared link shows has to be in the HTML the server sends. The
//! template carries generic tags between two comment markers; for a link that
//! names a city, `render` builds the block that replaces them.
//!
//! The functions are generic over the locale struct `tools/i18n_gen.zig` emits
//! (`i18n.pl`, `i18n.en`), so the words are the page's own and a key missing
//! from a locale is a compile error.

const std = @import("std");
const openmeteo = @import("openmeteo/mod.zig");

/// Comment markers in `src/web/index.html.in` around the generic tags.
pub const start_marker = "<!--link-preview:start-->";
pub const end_marker = "<!--link-preview:end-->";

/// The tags for `city`: its current weather when a forecast is at hand, or
/// just its name when it is not. The caller frees the result.
///
/// `city` must be a name from the city table, never text a request supplied;
/// it is still escaped, because a table is not a promise about quotes.
pub fn render(
    allocator: std.mem.Allocator,
    comptime Strings: type,
    city: []const u8,
    forecast: ?openmeteo.Forecast,
) std.mem.Allocator.Error![]u8 {
    // A writer over memory fails only when the allocation does.
    return build(allocator, Strings, city, forecast) catch error.OutOfMemory;
}

fn build(
    allocator: std.mem.Allocator,
    comptime Strings: type,
    city: []const u8,
    forecast: ?openmeteo.Forecast,
) (std.Io.Writer.Error || std.mem.Allocator.Error)![]u8 {
    var title: std.Io.Writer.Allocating = .init(allocator);
    defer title.deinit();
    var description: std.Io.Writer.Allocating = .init(allocator);
    defer description.deinit();

    if (forecast) |known| {
        try writeTitle(Strings, &title.writer, city, known);
        try writeDescription(Strings, &description.writer, known);
    } else {
        try title.writer.print("{s} – {s}", .{ city, Strings.page_title });
    }
    if (description.written().len == 0) try description.writer.writeAll(Strings.og_description);

    var tags: std.Io.Writer.Allocating = .init(allocator);
    errdefer tags.deinit();
    try writeTag(&tags.writer, "name", "description", description.written());
    try writeTag(&tags.writer, "property", "og:type", "website");
    try writeTag(&tags.writer, "property", "og:site_name", Strings.page_title);
    try writeTag(&tags.writer, "property", "og:locale", Strings.og_locale);
    try writeTag(&tags.writer, "property", "og:title", title.written());
    try writeTag(&tags.writer, "property", "og:description", description.written());
    try writeTag(&tags.writer, "name", "twitter:card", "summary");
    return tags.toOwnedSlice();
}

/// `Zakopane: 18°C, pochmurno`; a code the site has no word for leaves the
/// word out rather than guessing one.
fn writeTitle(comptime Strings: type, writer: *std.Io.Writer, city: []const u8, forecast: openmeteo.Forecast) std.Io.Writer.Error!void {
    try writer.print("{s}: {d}°C", .{ city, degrees(forecast.current.temperature_c) });
    if (openmeteo.model.condition(forecast.current.weather_code)) |condition| {
        try writer.writeAll(", ");
        try writer.writeAll(conditionWord(Strings, condition));
    }
}

/// `Odczuwalna 17°C · Wiatr 11 km/h · Opad 10% · Min / maks 10° / 19°`; the
/// day's figures are left out when Open-Meteo sent no day.
fn writeDescription(comptime Strings: type, writer: *std.Io.Writer, forecast: openmeteo.Forecast) std.Io.Writer.Error!void {
    const current = forecast.current;
    try writer.print("{s} {d}°C · {s} {d} km/h", .{
        Strings.forecast_feels_like,
        degrees(current.apparent_temperature_c),
        Strings.forecast_wind,
        degrees(current.wind_speed_kmh),
    });
    if (forecast.daily.len == 0) return;
    const today = forecast.daily[0];
    try writer.print(" · {s} {d}% · {s} {d}° / {d}°", .{
        Strings.forecast_precipitation,
        today.precipitation_chance_percent,
        Strings.forecast_col_range,
        degrees(today.temperature_min_c),
        degrees(today.temperature_max_c),
    });
}

fn conditionWord(comptime Strings: type, condition: openmeteo.model.Condition) []const u8 {
    return switch (condition) {
        inline else => |known| @field(Strings, "wmo_" ++ @tagName(known)),
    };
}

/// A reading rounded to whole degrees (or km/h). Saturating, because the
/// value comes from a decoded number and a conversion must not be able to
/// trap; `-0.4` reads as `0`, never `-0`.
fn degrees(value: f64) i32 {
    return std.math.lossyCast(i32, @round(value));
}

fn writeTag(writer: *std.Io.Writer, comptime attribute: []const u8, name: []const u8, content: []const u8) std.Io.Writer.Error!void {
    try writer.print("  <meta {s}=\"{s}\" content=\"", .{ attribute, name });
    try writeEscaped(writer, content);
    try writer.writeAll("\" />\n");
}

/// Escapes text for a double-quoted attribute.
fn writeEscaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(byte),
    };
}

const test_strings = struct {
    pub const page_title = "szklana.pogoda";
    pub const og_description = "Generic";
    pub const og_locale = "pl_PL";
    pub const forecast_feels_like = "Odczuwalna";
    pub const forecast_wind = "Wiatr";
    pub const forecast_precipitation = "Opad";
    pub const forecast_col_range = "Min / maks";
    pub const wmo_clear = "bezchmurnie";
    pub const wmo_partly = "częściowe zachmurzenie";
    pub const wmo_cloudy = "pochmurno";
    pub const wmo_fog = "mgła";
    pub const wmo_drizzle = "mżawka";
    pub const wmo_rain = "deszcz";
    pub const wmo_showers = "przelotne opady";
    pub const wmo_snow = "śnieg";
    pub const wmo_thunderstorm = "burza";
};

fn testForecast(days: []openmeteo.Day) openmeteo.Forecast {
    return .{
        .latitude = 49.3,
        .longitude = 19.9,
        .current = .{
            .time = "2026-09-18T14:00",
            .temperature_c = 18.4,
            .apparent_temperature_c = 16.6,
            .relative_humidity_percent = 63,
            .precipitation_mm = 0,
            .weather_code = 3,
            .wind_speed_kmh = 11.2,
            .wind_direction_deg = 240,
        },
        .daily = days,
        .hourly = &.{},
    };
}

var test_day: [1]openmeteo.Day = .{.{
    .date = "2026-09-18",
    .weather_code = 3,
    .temperature_min_c = 10.1,
    .temperature_max_c = 19.5,
    .precipitation_sum_mm = 0,
    .precipitation_chance_percent = 10,
    .sunrise = "2026-09-18T06:15",
    .sunset = "2026-09-18T19:02",
}};

test "a city with a forecast is titled with its weather" {
    const tags = try render(std.testing.allocator, test_strings, "Zakopane", testForecast(&test_day));
    defer std.testing.allocator.free(tags);

    try std.testing.expect(std.mem.find(u8, tags, "<meta property=\"og:title\" content=\"Zakopane: 18°C, pochmurno\" />") != null);
    try std.testing.expect(std.mem.find(u8, tags, "content=\"Odczuwalna 17°C · Wiatr 11 km/h · Opad 10% · Min / maks 10° / 20°\"") != null);
    try std.testing.expect(std.mem.find(u8, tags, "<meta name=\"description\" content=\"Odczuwalna") != null);
    try std.testing.expect(std.mem.find(u8, tags, "<meta property=\"og:locale\" content=\"pl_PL\" />") != null);
    try std.testing.expect(std.mem.find(u8, tags, "<meta name=\"twitter:card\" content=\"summary\" />") != null);
}

test "a city without a forecast is named and described generically" {
    const tags = try render(std.testing.allocator, test_strings, "Zakopane", null);
    defer std.testing.allocator.free(tags);

    try std.testing.expect(std.mem.find(u8, tags, "content=\"Zakopane – szklana.pogoda\"") != null);
    try std.testing.expect(std.mem.find(u8, tags, "<meta property=\"og:description\" content=\"Generic\" />") != null);
}

test "a forecast without a day leaves the day's figures out" {
    const tags = try render(std.testing.allocator, test_strings, "Zakopane", testForecast(&.{}));
    defer std.testing.allocator.free(tags);

    try std.testing.expect(std.mem.find(u8, tags, "content=\"Odczuwalna 17°C · Wiatr 11 km/h\"") != null);
}

test "a weather code the site has no word for leaves the word out" {
    var forecast = testForecast(&test_day);
    forecast.current.weather_code = 4;

    const tags = try render(std.testing.allocator, test_strings, "Zakopane", forecast);
    defer std.testing.allocator.free(tags);

    try std.testing.expect(std.mem.find(u8, tags, "content=\"Zakopane: 18°C\"") != null);
}

test "every interpolated value is escaped for an attribute" {
    const tags = try render(std.testing.allocator, test_strings, "A&B \"<x>\" 'y'", null);
    defer std.testing.allocator.free(tags);

    try std.testing.expect(std.mem.find(u8, tags, "A&amp;B &quot;&lt;x&gt;&quot; &#39;y&#39; – szklana.pogoda") != null);
    try std.testing.expect(std.mem.find(u8, tags, "\"<x>\"") == null);
}

test "a reading rounds to whole degrees and never reads as negative zero" {
    try std.testing.expectEqual(@as(i32, 0), degrees(-0.4));
    try std.testing.expectEqual(@as(i32, -1), degrees(-0.6));
    try std.testing.expectEqual(@as(i32, 3), degrees(2.5));
    try std.testing.expectEqual(std.math.maxInt(i32), degrees(1e30));
}
