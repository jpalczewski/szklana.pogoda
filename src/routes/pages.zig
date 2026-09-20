const std = @import("std");
const router = @import("../router.zig");
const i18n = @import("i18n");
const antistorm = @import("../antistorm/mod.zig");
const link_preview = @import("../link_preview.zig");
const openmeteo = @import("../openmeteo/mod.zig");
const compression = @import("../compression.zig");

const style_css = @embedFile("../web/98.css");

/// The pages link every asset as `/<file>?v=<content hash>`, so that URL never
/// changes meaning and a browser or CDN may keep it for good.
const immutable = "public, max-age=31536000, immutable";

/// Anything else must be asked about again: the HTML names the current assets,
/// and an asset fetched without its hash could be any version of the file.
const revalidate = "no-cache";

pub const home = localizedHome(i18n.pl_html, i18n.gzipped.pl_html, i18n.pl);

pub const homeEn = localizedHome(i18n.en_html, i18n.gzipped.en_html, i18n.en);

/// The page in one language. A link that names a city (`/?city=Zakopane`) gets
/// that city's weather in its link-preview tags, because a messenger's crawler
/// reads the HTML and does not run the page's script. The page never fails on
/// that account: a city the table does not know, or a forecast that cannot be
/// had, serves the page as it is.
fn localizedHome(comptime html: []const u8, comptime gzipped: []const u8, comptime Strings: type) router.Handler {
    const parts = splitAtLinkPreview(html);
    return struct {
        fn handle(app: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
            const city = requestedCity(ctx) orelse return page(encoded(ctx, router.Response.html(html), gzipped));
            const forecast = forecastFor(app, ctx.allocator, city);
            defer if (forecast) |known| known.deinit(ctx.allocator);

            const tags = try link_preview.render(ctx.allocator, Strings, city.name, forecast);
            defer ctx.allocator.free(tags);
            const body = try std.mem.concat(ctx.allocator, u8, &.{ parts.head, tags, parts.tail });
            if (!wantsGzip(ctx)) return page(varyOnEncoding(router.Response.html(body)));

            // This page exists only for this request, so it is compressed now
            // rather than by the build; the plain copy is not kept.
            defer ctx.allocator.free(body);
            var response = router.Response.html(try compression.gzip(ctx.allocator, body, .default));
            response.content_encoding = gzip_coding;
            return page(varyOnEncoding(response));
        }
    }.handle;
}

const HtmlParts = struct {
    head: []const u8,
    tail: []const u8,
};

/// The page around the generic link-preview tags the template carries; a build
/// whose template lost the markers stops here.
fn splitAtLinkPreview(comptime html: []const u8) HtmlParts {
    @setEvalBranchQuota(10_000_000);
    const start = std.mem.find(u8, html, link_preview.start_marker) orelse
        @compileError("index.html.in: no " ++ link_preview.start_marker);
    const end = std.mem.find(u8, html, link_preview.end_marker) orelse
        @compileError("index.html.in: no " ++ link_preview.end_marker);
    if (end < start) @compileError("index.html.in: the link-preview markers are swapped");
    return .{ .head = html[0..start], .tail = html[end + link_preview.end_marker.len ..] };
}

/// The city `?city=` names, resolved through the table like the API does. The
/// name is percent-decoded first, because a browser sends it that way and
/// `RequestContext.param` returns values verbatim.
fn requestedCity(ctx: *const router.RequestContext) ?*const antistorm.cities.City {
    // zlinter-disable-next-line no_undefined - filled by paramDecoded before being read
    var buffer: [antistorm.cities.max_name_bytes * 3]u8 = undefined;
    const name = ctx.paramDecoded("city", &buffer) orelse return null;
    const found = antistorm.cities.find(name) orelse return null;
    return antistorm.cities.byId(found.id);
}

/// The forecast for `city`, or null when there is no client or it failed. The
/// failure is logged and otherwise ignored: a preview without weather is still
/// a preview.
fn forecastFor(app: *router.App, allocator: std.mem.Allocator, city: *const antistorm.cities.City) ?openmeteo.Forecast {
    const client = app.forecast orelse return null;
    return client.get(allocator, city.latitude, city.longitude) catch |err| {
        std.log.warn("forecast for the link preview of {s} failed: {t}", .{ city.name, err });
        return null;
    };
}

pub fn style(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
    return asset(ctx, encoded(ctx, router.Response.css(style_css), i18n.gzipped.@"98.css"), i18n.versions.@"98.css");
}

/// The app's own stylesheet is a template (`app.css.in`) that the build renders,
/// because it links the fonts by their hashes.
pub fn appStyle(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
    return asset(ctx, encoded(ctx, router.Response.css(i18n.stylesheets.@"app.css"), i18n.gzipped.@"app.css"), i18n.versions.@"app.css");
}

/// A font the stylesheet loads. woff2 is compressed already, so it is sent as
/// it is and, unlike the text assets, its answer does not vary by encoding.
fn font(comptime name: []const u8) router.Handler {
    const body = @embedFile("../web/fonts/" ++ name);
    return struct {
        fn handle(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
            return asset(ctx, router.Response.woff2(body), @field(i18n.versions, name));
        }
    }.handle;
}

pub const regularFont = font("pixelated-ms-sans-serif.woff2");
pub const boldFont = font("pixelated-ms-sans-serif-bold.woff2");

/// A script the page loads: the app's own files (see the script tags in
/// `index.html.in`, whose order is the load order) and the vendored libraries.
fn script(comptime name: []const u8) router.Handler {
    const body = @embedFile("../web/" ++ name);
    return struct {
        fn handle(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
            return asset(ctx, encoded(ctx, router.Response.javascript(body), @field(i18n.gzipped, name)), @field(i18n.versions, name));
        }
    }.handle;
}

pub const arrivalScript = script("arrival.js");
pub const libScript = script("lib.js");
pub const windowsScript = script("windows.js");
pub const accountScript = script("account.js");
pub const imgwScript = script("imgw.js");
pub const forecastScript = script("forecast.js");
pub const appScript = script("app.js");
pub const alpineScript = script("alpine.js");
pub const qrcodeScript = script("qrcode.js");

/// The weather icons as one sprite of `<symbol>`s, drawn by the build from
/// `src/web/weather_icons.txt`.
pub fn iconSprite(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
    return asset(ctx, encoded(ctx, router.Response.svg(i18n.icons_svg), i18n.gzipped.@"icons.svg"), i18n.versions.@"icons.svg");
}

/// The favicon: one of the same icons as a stand-alone image.
pub fn favicon(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
    return asset(ctx, encoded(ctx, router.Response.svg(i18n.favicon_svg), i18n.gzipped.@"favicon.svg"), i18n.versions.@"favicon.svg");
}

const gzip_coding = "gzip";

fn wantsGzip(ctx: *const router.RequestContext) bool {
    return compression.acceptsGzip(ctx.header("accept-encoding"));
}

/// The answer depends on `Accept-Encoding`, so a cache must key on it.
fn varyOnEncoding(response: router.Response) router.Response {
    var result = response;
    result.vary = "Accept-Encoding";
    return result;
}

/// `response` in gzip form when the client accepts it. `gzipped` is the same
/// body compressed by the build, so nothing is compressed per request.
fn encoded(ctx: *const router.RequestContext, response: router.Response, gzipped: []const u8) router.Response {
    var result = varyOnEncoding(response);
    if (wantsGzip(ctx)) {
        result.body = gzipped;
        result.content_encoding = gzip_coding;
    }
    return result;
}

fn page(response: router.Response) router.Response {
    var result = response;
    result.cache_control = revalidate;
    return result;
}

/// An asset is cached for good only when the request names the version this
/// build serves; a bare URL or a stale hash gets the current file, uncached.
fn asset(ctx: *const router.RequestContext, response: router.Response, version: []const u8) router.Response {
    var result = response;
    const requested = ctx.param("v") orelse "";
    result.cache_control = if (std.mem.eql(u8, requested, version)) immutable else revalidate;
    return result;
}

fn testContext(path: []const u8, query: ?[]const u8) router.RequestContext {
    return .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = path,
        .query = query,
        .headers = &.{},
        .body = null,
    };
}

const accepts_gzip = [_]router.Header{.{ .name = "Accept-Encoding", .value = "gzip, deflate, br" }};

fn gunzipped(bytes: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(bytes);
    // zlinter-disable-next-line no_undefined - filled by the decompressor before being read
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    return decompressor.reader.allocRemaining(std.testing.allocator, .unlimited);
}

test "the pages are always revalidated" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var ctx = testContext("/", null);

    const polish = try home(&app, &ctx);
    const english = try homeEn(&app, &ctx);

    try std.testing.expectEqualStrings(revalidate, polish.cache_control.?);
    try std.testing.expectEqualStrings(revalidate, english.cache_control.?);
}

test "an asset requested by its current hash is cached for good" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var query_buffer: [64]u8 = undefined;
    const query = try std.fmt.bufPrint(&query_buffer, "v={s}", .{i18n.versions.@"app.js"});
    var ctx = testContext("/app.js", query);

    const response = try appScript(&app, &ctx);

    try std.testing.expectEqualStrings(immutable, response.cache_control.?);
}

test "an asset requested bare or by a stale hash is revalidated" {
    var app: router.App = .{ .max_body_bytes = 16 };

    var bare = testContext("/app.js", null);
    var stale = testContext("/app.js", "v=0000000000000000");
    var other_key = testContext("/app.js", "x=1");

    try std.testing.expectEqualStrings(revalidate, (try appScript(&app, &bare)).cache_control.?);
    try std.testing.expectEqualStrings(revalidate, (try appScript(&app, &stale)).cache_control.?);
    try std.testing.expectEqualStrings(revalidate, (try appScript(&app, &other_key)).cache_control.?);
}

test "the served page links every asset by the hash the handlers expect" {
    const links = [_][]const u8{
        "/98.css?v=" ++ i18n.versions.@"98.css",
        "/app.css?v=" ++ i18n.versions.@"app.css",
        "/pixelated-ms-sans-serif.woff2?v=" ++ i18n.versions.@"pixelated-ms-sans-serif.woff2",
        "/pixelated-ms-sans-serif-bold.woff2?v=" ++ i18n.versions.@"pixelated-ms-sans-serif-bold.woff2",
        "/arrival.js?v=" ++ i18n.versions.@"arrival.js",
        "/lib.js?v=" ++ i18n.versions.@"lib.js",
        "/windows.js?v=" ++ i18n.versions.@"windows.js",
        "/account.js?v=" ++ i18n.versions.@"account.js",
        "/imgw.js?v=" ++ i18n.versions.@"imgw.js",
        "/forecast.js?v=" ++ i18n.versions.@"forecast.js",
        "/app.js?v=" ++ i18n.versions.@"app.js",
        "/alpine.js?v=" ++ i18n.versions.@"alpine.js",
        "/qrcode.js?v=" ++ i18n.versions.@"qrcode.js",
        "/favicon.svg?v=" ++ i18n.versions.@"favicon.svg",
        "data-weather-icons=\"/icons.svg?v=" ++ i18n.versions.@"icons.svg",
    };
    for (links) |link| {
        try std.testing.expect(std.mem.find(u8, i18n.pl_html, link) != null);
        try std.testing.expect(std.mem.find(u8, i18n.en_html, link) != null);
    }
}

test "a versioned asset URL still reaches its route" {
    var app: router.App = .{ .max_body_bytes = 16 };
    const routes = [_]router.Route{.{ .method = .GET, .path = "/app.js", .handler = appScript }};
    const target = router.splitTarget("/app.js?v=abc");
    var ctx = testContext(target.path, target.query);

    const response = try router.dispatch(&routes, &app, &ctx);

    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", response.content_type);
}

test "the icon sprite has a symbol for every forecast icon" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var ctx = testContext("/icons.svg", null);

    const response = try iconSprite(&app, &ctx);

    try std.testing.expectEqualStrings("image/svg+xml", response.content_type);
    for ([_][]const u8{ "clear", "partly", "cloudy", "fog", "drizzle", "rain", "showers", "snow", "thunderstorm" }) |name| {
        var needle_buffer: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buffer, "<symbol id=\"{s}\"", .{name});
        try std.testing.expect(std.mem.find(u8, response.body, needle) != null);
    }
}

test "the favicon is a stand-alone svg" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var ctx = testContext("/favicon.svg", null);

    const response = try favicon(&app, &ctx);

    try std.testing.expectEqualStrings("image/svg+xml", response.content_type);
    try std.testing.expect(std.mem.startsWith(u8, response.body, "<svg xmlns="));
    try std.testing.expect(std.mem.find(u8, response.body, "<symbol") == null);
}

test "the icon files are cached for good only by their current hash" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var query_buffer: [64]u8 = undefined;
    const query = try std.fmt.bufPrint(&query_buffer, "v={s}", .{i18n.versions.@"icons.svg"});
    var current = testContext("/icons.svg", query);
    var bare = testContext("/icons.svg", null);

    try std.testing.expectEqualStrings(immutable, (try iconSprite(&app, &current)).cache_control.?);
    try std.testing.expectEqualStrings(revalidate, (try iconSprite(&app, &bare)).cache_control.?);
}

const fixture_body =
    \\{"latitude":49.3,"longitude":19.95,"current":{"time":"2026-09-18T14:00","temperature_2m":18.4,"apparent_temperature":16.6,"relative_humidity_2m":63,"precipitation":0.0,"weather_code":3,"wind_speed_10m":11.2,"wind_direction_10m":240},"daily":{"time":["2026-09-18"],"weather_code":[3],"temperature_2m_max":[19.5],"temperature_2m_min":[10.1],"precipitation_sum":[0.0],"precipitation_probability_max":[10],"sunrise":["2026-09-18T06:15"],"sunset":["2026-09-18T19:02"]},"hourly":{"time":["2026-09-18T14:00"],"temperature_2m":[18.4],"precipitation_probability":[10],"precipitation":[0.0],"weather_code":[3],"wind_speed_10m":[11.2],"wind_direction_10m":[240]}}
;

fn fetchFixture(allocator: std.mem.Allocator, _: std.Io, _: []const u8) openmeteo.Error![]u8 {
    return allocator.dupe(u8, fixture_body);
}

fn fetchUnavailable(_: std.mem.Allocator, _: std.Io, _: []const u8) openmeteo.Error![]u8 {
    return error.NetworkUnavailable;
}

fn fixtureClient(fetch: openmeteo.client.Fetch) openmeteo.Client {
    return .{ .allocator = std.testing.allocator, .io = std.testing.io, .ttl_seconds = 900, .fetch = fetch };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.find(u8, haystack, needle) != null;
}

test "a link that names a city carries that city's weather in its preview" {
    var client = fixtureClient(&fetchFixture);
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var ctx = testContext("/", "city=Zakopane");

    const response = try home(&app, &ctx);
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqualStrings(revalidate, response.cache_control.?);
    try std.testing.expect(contains(response.body, "<meta property=\"og:title\" content=\"Zakopane: 18°C, pochmurno\" />"));
    try std.testing.expect(contains(response.body, "Odczuwalna 17°C"));
    // The generic tags are replaced, not repeated.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, response.body, "property=\"og:title\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, response.body, "name=\"description\""));
    try std.testing.expect(!contains(response.body, link_preview.start_marker));
    // The rest of the page is untouched.
    try std.testing.expect(contains(response.body, "<title>szklana.pogoda</title>"));
    try std.testing.expect(std.mem.endsWith(u8, response.body, "</html>\n"));
}

test "the English page says the weather in English" {
    var client = fixtureClient(&fetchFixture);
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var ctx = testContext("/en/", "city=Zakopane");

    const response = try homeEn(&app, &ctx);
    defer std.testing.allocator.free(response.body);

    try std.testing.expect(contains(response.body, "content=\"Zakopane: 18°C, overcast\""));
    try std.testing.expect(contains(response.body, "Feels like 17°C"));
    try std.testing.expect(contains(response.body, "content=\"en_GB\""));
}

test "a page with no city is exactly the page the build made" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var bare = testContext("/", null);
    var other_key = testContext("/", "x=1");
    var empty = testContext("/", "city=");

    try std.testing.expectEqualStrings(i18n.pl_html, (try home(&app, &bare)).body);
    try std.testing.expectEqualStrings(i18n.pl_html, (try home(&app, &other_key)).body);
    try std.testing.expectEqualStrings(i18n.pl_html, (try home(&app, &empty)).body);
    try std.testing.expect(contains(i18n.pl_html, "property=\"og:title\" content=\"szklana.pogoda\""));
}

test "a city the table does not know serves the page as it is" {
    var client = fixtureClient(&fetchFixture);
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var ctx = testContext("/", "city=Atlantyda");

    const response = try home(&app, &ctx);

    try std.testing.expectEqualStrings(i18n.pl_html, response.body);
}

test "a forecast that cannot be had leaves the city's name and the generic description" {
    var client = fixtureClient(&fetchUnavailable);
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var ctx = testContext("/", "city=Zakopane");

    const response = try home(&app, &ctx);
    defer std.testing.allocator.free(response.body);

    try std.testing.expect(contains(response.body, "og:title\" content=\"Zakopane – szklana.pogoda\""));
    try std.testing.expect(contains(response.body, "Pogoda dla polskich miast"));
}

test "a server with no forecast client still names the city" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var ctx = testContext("/", "city=Zakopane");

    const response = try home(&app, &ctx);
    defer std.testing.allocator.free(response.body);

    try std.testing.expect(contains(response.body, "og:title\" content=\"Zakopane – szklana.pogoda\""));
}

test "a percent-encoded or lazily spelled name resolves to the table's spelling" {
    var app: router.App = .{ .max_body_bytes = 16 };
    const queries = [_][]const u8{
        "city=Bia%C5%82a%20Podlaska",
        "city=Bia%C5%82a+Podlaska",
        "city=biala%20podlaska",
    };
    for (queries) |query| {
        var ctx = testContext("/", query);
        const response = try home(&app, &ctx);
        defer std.testing.allocator.free(response.body);
        try std.testing.expect(contains(response.body, "og:title\" content=\"Biała Podlaska – szklana.pogoda\""));
    }
}

test "text after the city in the query never reaches the tags" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var ctx = testContext("/", "city=Zakopane%22%3E%3Cscript%3E");

    const response = try home(&app, &ctx);

    try std.testing.expectEqualStrings(i18n.pl_html, response.body);
}

test "a client that accepts gzip gets the page and the assets as the build compressed them" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var ctx = testContext("/", null);
    ctx.headers = &accepts_gzip;

    const polish = try home(&app, &ctx);
    const english = try homeEn(&app, &ctx);
    const script_response = try appScript(&app, &ctx);
    const sprite = try iconSprite(&app, &ctx);

    for ([_]router.Response{ polish, english, script_response, sprite }) |response| {
        try std.testing.expectEqualStrings("gzip", response.content_encoding.?);
        try std.testing.expectEqualStrings("Accept-Encoding", response.vary.?);
    }
    try std.testing.expectEqualStrings(i18n.gzipped.pl_html, polish.body);
    try std.testing.expectEqualStrings(i18n.gzipped.en_html, english.body);
    try std.testing.expectEqualStrings(i18n.gzipped.@"app.js", script_response.body);

    const restored = try gunzipped(polish.body);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(i18n.pl_html, restored);
    try std.testing.expect(polish.body.len < i18n.pl_html.len / 2);
}

test "a client that does not accept gzip gets the plain body, still marked as varying" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var ctx = testContext("/app.js", null);
    const refusing = [_]router.Header{.{ .name = "Accept-Encoding", .value = "gzip;q=0, br" }};

    const bare = try appScript(&app, &ctx);
    ctx.headers = &refusing;
    const refused = try appScript(&app, &ctx);

    for ([_]router.Response{ bare, refused }) |response| {
        try std.testing.expect(response.content_encoding == null);
        try std.testing.expectEqualStrings("Accept-Encoding", response.vary.?);
    }
    try std.testing.expectEqualStrings(@embedFile("../web/app.js"), bare.body);
    try std.testing.expectEqualStrings(@embedFile("../web/app.js"), refused.body);
}

test "every asset's gzip form is what its file compresses to" {
    inline for (.{ "98.css", "arrival.js", "lib.js", "windows.js", "account.js", "imgw.js", "forecast.js", "app.js", "alpine.js", "qrcode.js" }) |name| {
        const restored = try gunzipped(@field(i18n.gzipped, name));
        defer std.testing.allocator.free(restored);
        try std.testing.expectEqualStrings(@embedFile("../web/" ++ name), restored);
    }
    // The app stylesheet is rendered by the build, so it is compared with that.
    const rendered = try gunzipped(i18n.gzipped.@"app.css");
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(i18n.stylesheets.@"app.css", rendered);
    const sprite = try gunzipped(i18n.gzipped.@"icons.svg");
    defer std.testing.allocator.free(sprite);
    try std.testing.expectEqualStrings(i18n.icons_svg, sprite);
    const icon = try gunzipped(i18n.gzipped.@"favicon.svg");
    defer std.testing.allocator.free(icon);
    try std.testing.expectEqualStrings(i18n.favicon_svg, icon);
}

test "the page for a city is compressed per request when the client accepts gzip" {
    var client = fixtureClient(&fetchFixture);
    defer client.deinit();
    var app: router.App = .{ .max_body_bytes = 16, .forecast = &client };
    var ctx = testContext("/", "city=Zakopane");
    ctx.headers = &accepts_gzip;

    const response = try home(&app, &ctx);
    defer std.testing.allocator.free(response.body);

    try std.testing.expectEqualStrings("gzip", response.content_encoding.?);
    try std.testing.expectEqualStrings("Accept-Encoding", response.vary.?);
    try std.testing.expectEqualStrings(revalidate, response.cache_control.?);
    const restored = try gunzipped(response.body);
    defer std.testing.allocator.free(restored);
    try std.testing.expect(contains(restored, "<meta property=\"og:title\" content=\"Zakopane: 18°C, pochmurno\" />"));
    try std.testing.expect(std.mem.endsWith(u8, restored, "</html>\n"));
}

test "the fonts are served as woff2 and cached for good only by their current hash" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var query_buffer: [64]u8 = undefined;
    const query = try std.fmt.bufPrint(&query_buffer, "v={s}", .{i18n.versions.@"pixelated-ms-sans-serif.woff2"});
    var current = testContext("/pixelated-ms-sans-serif.woff2", query);
    var bare = testContext("/pixelated-ms-sans-serif-bold.woff2", null);
    current.headers = &accepts_gzip;

    const regular = try regularFont(&app, &current);
    const bold = try boldFont(&app, &bare);

    try std.testing.expectEqualStrings("font/woff2", regular.content_type);
    try std.testing.expectEqualStrings(immutable, regular.cache_control.?);
    try std.testing.expectEqualStrings(revalidate, bold.cache_control.?);
    // A woff2 file is compressed already, so it is never sent in another coding.
    try std.testing.expect(regular.content_encoding == null and regular.vary == null);
    try std.testing.expectEqualStrings("wOF2", regular.body[0..4]);
    try std.testing.expectEqualStrings("wOF2", bold.body[0..4]);
}

test "the stylesheet links each font by the hash its handler expects" {
    const css = i18n.stylesheets.@"app.css";
    try std.testing.expect(contains(css, "url(\"/pixelated-ms-sans-serif.woff2?v=" ++ i18n.versions.@"pixelated-ms-sans-serif.woff2" ++ "\")"));
    try std.testing.expect(contains(css, "url(\"/pixelated-ms-sans-serif-bold.woff2?v=" ++ i18n.versions.@"pixelated-ms-sans-serif-bold.woff2" ++ "\")"));
    try std.testing.expect(!contains(css, "{{"));
    // The vendored stylesheet no longer carries the fonts inline.
    try std.testing.expect(!contains(style_css, "data:font"));
    try std.testing.expect(contains(style_css, "\"Pixelated MS Sans Serif\""));
}

test "the app stylesheet is served with the hash of what it was rendered to" {
    var app: router.App = .{ .max_body_bytes = 16 };
    var ctx = testContext("/app.css", null);

    const response = try appStyle(&app, &ctx);

    try std.testing.expectEqualStrings(i18n.stylesheets.@"app.css", response.body);
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, response.body), try std.fmt.parseInt(u64, i18n.versions.@"app.css", 16));
}
