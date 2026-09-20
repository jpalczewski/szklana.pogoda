//! The cities a user keeps: `/api/me/favorites`.
//!
//! A city is named the way the rest of the API names it, by `?city=`, and is
//! stored under the spelling of the Antistorm table: `gorzow+wielkopolski` and
//! `Gorz%C3%B3w%20Wielkopolski` are one favourite. It is stored by name and never by the table's position,
//! because the position is the id and a regenerated table shifts every id.
//! A favourite whose city has left the table is skipped when listing.

const std = @import("std");
const Io = std.Io;
const router = @import("../router.zig");
const antistorm = @import("../antistorm/mod.zig");
const account = @import("account.zig");

const Entry = struct {
    city_name: []const u8,
    latitude: f64,
    longitude: f64,
};

const FavoritesResponse = struct {
    favorites: []const Entry,
};

/// `GET /api/me/favorites` lists the caller's cities; a browser with no
/// session has none, and asking does not give it one.
pub const list = account.optional(listHandler);

/// `POST /api/me/favorites?city=` adds a city and answers with the new list.
/// This is the request that makes an account, when the browser has none. A
/// city that is not in the table is refused first, so that a request which
/// keeps nothing does not create a user.
pub fn add(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
    _ = try requestedCity(request);
    return ensuredAdd(app, request);
}

const ensuredAdd = account.ensure(addHandler);

/// `DELETE /api/me/favorites?city=` removes a city and answers with the list.
pub const remove = account.optional(removeHandler);

fn listHandler(app: *router.App, request: *router.RequestContext, session: ?account.Session) router.AppError!router.Response {
    return respond(app, request, session);
}

fn addHandler(app: *router.App, request: *router.RequestContext, session: account.Session) router.AppError!router.Response {
    const store = app.accounts orelse return error.AccountsUnavailable;
    const io = app.io orelse return error.AccountsUnavailable;
    const city = try requestedCity(request);
    store.addFavorite(session.user_id, city.name, Io.Clock.real.now(io).toSeconds()) catch |err| switch (err) {
        error.FavoritesFull => return error.BadRequest,
        else => {
            std.log.err("adding a favourite failed: {t}", .{err});
            return error.AccountsUnavailable;
        },
    };
    return respond(app, request, session);
}

fn removeHandler(app: *router.App, request: *router.RequestContext, session: ?account.Session) router.AppError!router.Response {
    const store = app.accounts orelse return error.AccountsUnavailable;
    const city = try requestedCity(request);
    if (session) |caller| {
        store.removeFavorite(caller.user_id, city.name) catch |err| {
            std.log.err("removing a favourite failed: {t}", .{err});
            return error.AccountsUnavailable;
        };
    }
    return respond(app, request, session);
}

fn respond(app: *router.App, request: *router.RequestContext, session: ?account.Session) router.AppError!router.Response {
    const store = app.accounts orelse return error.AccountsUnavailable;
    var entries: std.ArrayList(Entry) = .empty;
    if (session) |caller| {
        const names = store.favorites(request.allocator, caller.user_id) catch |err| {
            std.log.err("listing favourites failed: {t}", .{err});
            return error.AccountsUnavailable;
        };
        for (names) |name| {
            const found = antistorm.cities.find(name) orelse continue;
            const city = antistorm.cities.byId(found.id) orelse continue;
            try entries.append(request.allocator, .{
                .city_name = city.name,
                .latitude = city.latitude,
                .longitude = city.longitude,
            });
        }
    }
    return router.Response.jsonValue(request.allocator, .ok, FavoritesResponse{ .favorites = entries.items });
}

/// The city `?city=` names, in the table's spelling.
fn requestedCity(request: *router.RequestContext) router.AppError!*const antistorm.cities.City {
    // zlinter-disable-next-line no_undefined - filled by paramDecoded before being read
    var buffer: [antistorm.cities.max_name_bytes * 3]u8 = undefined;
    const name = request.paramDecoded("city", &buffer) orelse return error.BadRequest;
    if (name.len == 0) return error.BadRequest;
    const found = antistorm.cities.find(name) orelse return error.UnknownCity;
    return antistorm.cities.byId(found.id) orelse error.UnknownCity;
}

const TestSite = struct {
    store: @import("../accounts/mod.zig").Store,
    arena: std.heap.ArenaAllocator,
    app: router.App,

    fn init() !*TestSite {
        const site = try std.testing.allocator.create(TestSite);
        site.* = .{
            .store = try @import("../accounts/mod.zig").Store.initMemory(),
            .arena = .init(std.testing.allocator),
            .app = .{ .max_body_bytes = 16, .io = std.testing.io },
        };
        site.app.accounts = &site.store;
        return site;
    }

    fn deinit(self: *TestSite) void {
        self.arena.deinit();
        self.store.deinit();
        std.testing.allocator.destroy(self);
    }

    fn call(self: *TestSite, handler: router.Handler, method: std.http.Method, query: ?[]const u8, cookie: ?[]const u8) router.AppError!router.Response {
        const origin: router.Header = .{ .name = "Origin", .value = "http://localhost:8080" };
        const host: router.Header = .{ .name = "Host", .value = "localhost:8080" };
        const with_cookie = [_]router.Header{ origin, host, .{ .name = "Cookie", .value = cookie orelse "" } };
        var request: router.RequestContext = .{
            .allocator = self.arena.allocator(),
            .method = method,
            .path = "/api/me/favorites",
            .query = query,
            .headers = if (cookie != null) &with_cookie else with_cookie[0..2],
            .body = null,
        };
        return handler(&self.app, &request);
    }

    /// The cookie header a browser would send back after `set_cookie`.
    fn cookieFor(self: *TestSite, set_cookie: []const u8) ![]const u8 {
        const start = std.mem.findScalar(u8, set_cookie, ';').?;
        return self.arena.allocator().dupe(u8, set_cookie[0..start]);
    }
};

test "the first favourite makes the account and the cookie brings it back" {
    const site = try TestSite.init();
    defer site.deinit();

    const added = try site.call(add, .POST, "city=Zakopane", null);
    try std.testing.expect(added.set_cookie != null);
    try std.testing.expect(std.mem.startsWith(u8, added.body, "{\"favorites\":[{\"city_name\":\"Zakopane\""));

    const cookie = try site.cookieFor(added.set_cookie.?);
    const listed = try site.call(list, .GET, null, cookie);
    try std.testing.expectEqualStrings(added.body, listed.body);
    try std.testing.expect(listed.set_cookie == null);
}

test "a browser with no account has no favourites and asking makes none" {
    const site = try TestSite.init();
    defer site.deinit();
    const listed = try site.call(list, .GET, null, null);
    try std.testing.expectEqualStrings("{\"favorites\":[]}", listed.body);
    try std.testing.expect(listed.set_cookie == null);
    try std.testing.expectEqual(@as(i64, 0), (try site.store.db.one(i64, "SELECT COUNT(*) FROM users", .{}, .{})).?);
}

test "a lazy or percent-encoded spelling is stored as the table's" {
    const site = try TestSite.init();
    defer site.deinit();
    const first = try site.call(add, .POST, "city=gorzow+wielkopolski", null);
    const cookie = try site.cookieFor(first.set_cookie.?);
    _ = try site.call(add, .POST, "city=Gorz%C3%B3w+Wielkopolski", cookie);
    _ = try site.call(add, .POST, "city=GDANSK", cookie);

    const listed = try site.call(list, .GET, null, cookie);
    try std.testing.expect(std.mem.find(u8, listed.body, "\"city_name\":\"Gorzów Wielkopolski\"") != null);
    try std.testing.expect(std.mem.find(u8, listed.body, "\"city_name\":\"Gdańsk\"") != null);
    // Gorzów Wielkopolski was added twice and is one favourite.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, listed.body, "Gorzów"));
}

test "a city outside the table, or none at all, is refused and makes no account" {
    const site = try TestSite.init();
    defer site.deinit();
    try std.testing.expectError(error.UnknownCity, site.call(add, .POST, "city=Atlantyda", null));
    try std.testing.expectError(error.BadRequest, site.call(add, .POST, "city=", null));
    try std.testing.expectError(error.BadRequest, site.call(add, .POST, null, null));
    try std.testing.expectEqual(@as(i64, 0), (try site.store.db.one(i64, "SELECT COUNT(*) FROM users", .{}, .{})).?);
}

test "removing a favourite leaves the others, and needs no account to be harmless" {
    const site = try TestSite.init();
    defer site.deinit();
    const first = try site.call(add, .POST, "city=Zakopane", null);
    const cookie = try site.cookieFor(first.set_cookie.?);
    _ = try site.call(add, .POST, "city=Gdansk", cookie);

    const after = try site.call(remove, .DELETE, "city=zakopane", cookie);
    try std.testing.expect(std.mem.find(u8, after.body, "Zakopane") == null);
    try std.testing.expect(std.mem.find(u8, after.body, "Gdańsk") != null);

    const anonymous = try site.call(remove, .DELETE, "city=Gdansk", null);
    try std.testing.expectEqualStrings("{\"favorites\":[]}", anonymous.body);
}

test "changing favourites needs the site's origin" {
    const site = try TestSite.init();
    defer site.deinit();
    var request: router.RequestContext = .{
        .allocator = site.arena.allocator(),
        .method = .POST,
        .path = "/api/me/favorites",
        .query = "city=Zakopane",
        .headers = &.{.{ .name = "Origin", .value = "https://evil.example" }},
        .body = null,
    };
    try std.testing.expectError(error.Forbidden, add(&site.app, &request));
    try std.testing.expectEqual(@as(i64, 0), (try site.store.db.one(i64, "SELECT COUNT(*) FROM users", .{}, .{})).?);
}
