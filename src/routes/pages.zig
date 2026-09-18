const std = @import("std");
const router = @import("../router.zig");
const i18n = @import("i18n");

const style_css = @embedFile("../web/98.css");
const app_css = @embedFile("../web/app.css");
const app_js = @embedFile("../web/app.js");
const alpine_js = @embedFile("../web/alpine.js");

/// The pages link every asset as `/<file>?v=<content hash>`, so that URL never
/// changes meaning and a browser or CDN may keep it for good.
const immutable = "public, max-age=31536000, immutable";

/// Anything else must be asked about again: the HTML names the current assets,
/// and an asset fetched without its hash could be any version of the file.
const revalidate = "no-cache";

pub fn home(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return page(router.Response.html(i18n.pl_html));
}

pub fn homeEn(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return page(router.Response.html(i18n.en_html));
}

pub fn style(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
    return asset(ctx, router.Response.css(style_css), i18n.versions.@"98.css");
}

pub fn appStyle(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
    return asset(ctx, router.Response.css(app_css), i18n.versions.@"app.css");
}

pub fn appScript(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
    return asset(ctx, router.Response.javascript(app_js), i18n.versions.@"app.js");
}

pub fn alpineScript(_: *router.App, ctx: *router.RequestContext) router.AppError!router.Response {
    return asset(ctx, router.Response.javascript(alpine_js), i18n.versions.@"alpine.js");
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
        "/app.js?v=" ++ i18n.versions.@"app.js",
        "/alpine.js?v=" ++ i18n.versions.@"alpine.js",
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
