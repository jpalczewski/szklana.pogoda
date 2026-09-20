//! The routes that tell a browser apart from another: `/api/me/*`.
//!
//! A handler that needs the caller's session is written against `Session` and
//! wrapped by the policy that decides where the session comes from:
//!
//! - `optional` runs the handler with or without a session, for a page that
//!   asks who it is talking to on load.
//! - `require` answers 401 to a request with no session.
//! - `ensure` creates an anonymous user and its session when there is none and
//!   sets the cookie on whatever the handler returns, so an account is made by
//!   the first request that has something to keep, not by a visit.
//!
//! All three refuse a request that changes state unless its `Origin` is the
//! site's own, and mark the answer `private, no-store`: it depends on a cookie,
//! so no cache in front may reuse it for somebody else.

const std = @import("std");
const Io = std.Io;
const router = @import("../router.zig");
const accounts = @import("../accounts/mod.zig");
const metrics = @import("../metrics/mod.zig");

/// The caller, as far as a handler needs to know.
pub const Session = struct {
    user_id: i64,
    token_hash: accounts.token.Hash,
};

pub const SessionHandler = *const fn (*router.App, *router.RequestContext, Session) router.AppError!router.Response;
pub const OptionalSessionHandler = *const fn (*router.App, *router.RequestContext, ?Session) router.AppError!router.Response;

const private_cache = "private, no-store";

pub fn optional(comptime handler: OptionalSessionHandler) router.Handler {
    return struct {
        fn handle(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
            try guard(app, request);
            return private(try handler(app, request, try resolve(app, request)));
        }
    }.handle;
}

pub fn require(comptime handler: SessionHandler) router.Handler {
    return struct {
        fn handle(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
            try guard(app, request);
            const session = try resolve(app, request) orelse return error.Unauthorized;
            return private(try handler(app, request, session));
        }
    }.handle;
}

pub fn ensure(comptime handler: SessionHandler) router.Handler {
    return struct {
        fn handle(app: *router.App, request: *router.RequestContext) router.AppError!router.Response {
            try guard(app, request);
            if (try resolve(app, request)) |session| return private(try handler(app, request, session));

            const created = try create(app, request.allocator, request.client_ip);
            var response = private(try handler(app, request, created.session));
            response.set_cookie = created.cookie;
            return response;
        }
    }.handle;
}

/// Says whether the request comes with a session: `{"session": true}`.
pub const sessionStatus = optional(sessionStatusHandler);

fn sessionStatusHandler(_: *router.App, request: *router.RequestContext, session: ?Session) router.AppError!router.Response {
    return router.Response.jsonValue(request.allocator, .ok, .{ .session = session != null });
}

/// Ends the caller's session and tells the browser to drop the cookie. The
/// user and its data stay; only this browser's way in is gone.
pub const signOut = require(signOutHandler);

fn signOutHandler(app: *router.App, request: *router.RequestContext, session: Session) router.AppError!router.Response {
    const store = app.accounts orelse return error.AccountsUnavailable;
    store.deleteSession(session.token_hash) catch |err| {
        std.log.err("sign-out failed: {t}", .{err});
        return error.AccountsUnavailable;
    };
    var response = try router.Response.jsonValue(request.allocator, .ok, .{ .session = false });
    response.set_cookie = try accounts.cookie.clear(request.allocator, app.cookie_policy);
    return response;
}

fn private(response: router.Response) router.Response {
    var marked = response;
    if (marked.cache_control == null) marked.cache_control = private_cache;
    return marked;
}

/// Refuses a request that changes state unless it names the site as its origin.
/// A browser attaches `Origin` to every such request it makes and a page on
/// another site cannot change it, which is what stops that page from riding the
/// visitor's cookie. `SameSite=Lax` already withholds the cookie from most of
/// them; this covers the rest.
fn guard(app: *router.App, request: *router.RequestContext) router.AppError!void {
    if (request.method == .GET or request.method == .HEAD) return;
    const origin = request.header("origin") orelse return error.Forbidden;
    if (app.public_origin) |expected| {
        if (std.ascii.eqlIgnoreCase(origin, expected)) return;
        return error.Forbidden;
    }
    // Without a configured origin, the request's own host stands in: correct
    // for local development, and no worse than the browser's own same-origin
    // check, which is the one being repeated here.
    const scheme_end = std.mem.find(u8, origin, "://") orelse return error.Forbidden;
    const host = request.header("host") orelse return error.Forbidden;
    if (!std.ascii.eqlIgnoreCase(origin[scheme_end + 3 ..], host)) return error.Forbidden;
}

/// The session the request's cookie names, or null when there is none it can
/// use. Every outcome is counted.
fn resolve(app: *router.App, request: *router.RequestContext) router.AppError!?Session {
    const store = app.accounts orelse return error.AccountsUnavailable;
    const io = app.io orelse return error.AccountsUnavailable;

    const raw = accounts.cookie.read(app.cookie_policy, request.header("cookie")) orelse {
        recordLookup(app, .missing);
        return null;
    };
    const hash = accounts.token.hash(raw) orelse {
        recordLookup(app, .invalid);
        return null;
    };
    const found = store.lookup(hash, nowSeconds(io)) catch |err| {
        std.log.err("session lookup failed: {t}", .{err});
        return error.AccountsUnavailable;
    };
    switch (found) {
        .valid => |user_id| {
            recordLookup(app, .valid);
            return .{ .user_id = user_id, .token_hash = hash };
        },
        .expired => recordLookup(app, .expired),
        .unknown => recordLookup(app, .unknown),
    }
    return null;
}

const Created = struct {
    session: Session,
    /// The `Set-Cookie` value that hands the new token to the browser.
    cookie: []const u8,
};

fn create(app: *router.App, allocator: std.mem.Allocator, client_ip: []const u8) router.AppError!Created {
    const store = app.accounts orelse return error.AccountsUnavailable;
    const io = app.io orelse return error.AccountsUnavailable;

    const now = nowSeconds(io);
    if (app.new_session_limiter) |limiter| {
        if (!limiter.allow(io, client_ip, now)) return error.TooManyRequests;
    }
    const text = accounts.token.generate(io) catch |err| {
        std.log.err("no secure randomness for a session token: {t}", .{err});
        return error.AccountsUnavailable;
    };
    const hash = accounts.token.hash(&text).?;
    const user_id = store.createUser(now) catch |err| {
        std.log.err("creating a user failed: {t}", .{err});
        return error.AccountsUnavailable;
    };
    store.createSession(user_id, hash, now) catch |err| {
        std.log.err("creating a session failed: {t}", .{err});
        return error.AccountsUnavailable;
    };
    if (app.metrics) |registry| registry.sessionCreated();
    return .{
        .session = .{ .user_id = user_id, .token_hash = hash },
        .cookie = try accounts.cookie.set(allocator, app.cookie_policy, text),
    };
}

fn recordLookup(app: *router.App, result: metrics.SessionResult) void {
    if (app.metrics) |registry| registry.sessionLookup(result);
}

fn nowSeconds(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

const TestSite = struct {
    store: accounts.Store,
    arena: std.heap.ArenaAllocator,
    app: router.App,

    fn init() !*TestSite {
        const site = try std.testing.allocator.create(TestSite);
        site.* = .{
            .store = try accounts.Store.initMemory(),
            .arena = .init(std.testing.allocator),
            .app = .{ .max_body_bytes = 16, .io = std.testing.io },
        };
        site.app.accounts = &site.store;
        return site;
    }

    fn destroy(self: *TestSite) void {
        self.arena.deinit();
        self.store.deinit();
        std.testing.allocator.destroy(self);
    }

    fn call(self: *TestSite, handler: router.Handler, method: std.http.Method, headers: []const router.Header) router.AppError!router.Response {
        var request: router.RequestContext = .{
            .allocator = self.arena.allocator(),
            .method = method,
            .path = "/api/me",
            .query = null,
            .headers = headers,
            .body = null,
        };
        return handler(&self.app, &request);
    }
};

/// The token a `Set-Cookie` value carries, which the next request sends back.
fn tokenOf(set_cookie: []const u8) []const u8 {
    const start = std.mem.findScalar(u8, set_cookie, '=').? + 1;
    return set_cookie[start..][0..accounts.token.text_len];
}

fn echoUser(_: *router.App, request: *router.RequestContext, session: Session) router.AppError!router.Response {
    return router.Response.jsonValue(request.allocator, .ok, .{ .user = session.user_id });
}

const same_site: router.Header = .{ .name = "Origin", .value = "http://localhost:8080" };
const local_host: router.Header = .{ .name = "Host", .value = "localhost:8080" };

test "a request without a cookie has no session and the answer is not cacheable" {
    const site = try TestSite.init();
    defer site.destroy();

    const response = try site.call(sessionStatus, .GET, &.{});
    try std.testing.expectEqualStrings("{\"session\":false}", response.body);
    try std.testing.expectEqualStrings("private, no-store", response.cache_control.?);
    try std.testing.expect(response.set_cookie == null);
}

test "ensure makes a user on the first request and recognises the browser after" {
    const site = try TestSite.init();
    defer site.destroy();
    const keep = ensure(echoUser);

    const first = try site.call(keep, .POST, &.{ same_site, local_host });
    const cookie = first.set_cookie.?;
    try std.testing.expect(std.mem.startsWith(u8, cookie, "sid="));
    try std.testing.expectEqualStrings("{\"user\":1}", first.body);

    var cookie_header_buffer: [64]u8 = undefined;
    const cookie_header = try std.fmt.bufPrint(&cookie_header_buffer, "sid={s}", .{tokenOf(cookie)});
    const returning: router.Header = .{ .name = "Cookie", .value = cookie_header };

    const second = try site.call(keep, .POST, &.{ same_site, local_host, returning });
    try std.testing.expect(second.set_cookie == null);
    try std.testing.expectEqualStrings("{\"user\":1}", second.body);
    try std.testing.expectEqualStrings("{\"session\":true}", (try site.call(sessionStatus, .GET, &.{returning})).body);
}

test "require answers 401 without a session and runs the handler with one" {
    const site = try TestSite.init();
    defer site.destroy();
    try std.testing.expectError(error.Unauthorized, site.call(require(echoUser), .GET, &.{}));

    const created = try site.call(ensure(echoUser), .POST, &.{ same_site, local_host });
    var cookie_header_buffer: [64]u8 = undefined;
    const cookie_header = try std.fmt.bufPrint(&cookie_header_buffer, "sid={s}", .{tokenOf(created.set_cookie.?)});
    const response = try site.call(require(echoUser), .GET, &.{.{ .name = "Cookie", .value = cookie_header }});
    try std.testing.expectEqualStrings("{\"user\":1}", response.body);
}

test "a cookie that is not a token, or that nobody issued, is no session" {
    const site = try TestSite.init();
    defer site.destroy();
    try std.testing.expectEqualStrings("{\"session\":false}", (try site.call(sessionStatus, .GET, &.{.{ .name = "Cookie", .value = "sid=garbage" }})).body);
    const forged = "sid=" ++ "A" ** accounts.token.text_len;
    try std.testing.expectEqualStrings("{\"session\":false}", (try site.call(sessionStatus, .GET, &.{.{ .name = "Cookie", .value = forged }})).body);
}

test "a request that changes state must come from the site's own origin" {
    const site = try TestSite.init();
    defer site.destroy();
    const keep = ensure(echoUser);

    try std.testing.expectError(error.Forbidden, site.call(keep, .POST, &.{local_host}));
    try std.testing.expectError(error.Forbidden, site.call(keep, .POST, &.{ .{ .name = "Origin", .value = "https://evil.example" }, local_host }));
    try std.testing.expectError(error.Forbidden, site.call(keep, .POST, &.{ .{ .name = "Origin", .value = "null" }, local_host }));
    _ = try site.call(keep, .POST, &.{ same_site, local_host });
}

test "with a configured origin only that origin is accepted" {
    const site = try TestSite.init();
    defer site.destroy();
    site.app.public_origin = "https://szklana.pogoda";
    site.app.cookie_policy = .secure;
    const keep = ensure(echoUser);

    const good = try site.call(keep, .POST, &.{.{ .name = "Origin", .value = "https://szklana.pogoda" }});
    try std.testing.expect(std.mem.startsWith(u8, good.set_cookie.?, "__Host-sid="));
    try std.testing.expect(std.mem.endsWith(u8, good.set_cookie.?, "; Secure"));
    // The request's own host is no longer enough.
    try std.testing.expectError(error.Forbidden, site.call(keep, .POST, &.{ same_site, local_host }));
}

test "signing out ends the session, clears the cookie and needs the site's origin" {
    const site = try TestSite.init();
    defer site.destroy();
    const created = try site.call(ensure(echoUser), .POST, &.{ same_site, local_host });
    var cookie_header_buffer: [64]u8 = undefined;
    const cookie_header = try std.fmt.bufPrint(&cookie_header_buffer, "sid={s}", .{tokenOf(created.set_cookie.?)});
    const returning: router.Header = .{ .name = "Cookie", .value = cookie_header };

    try std.testing.expectError(error.Forbidden, site.call(signOut, .DELETE, &.{returning}));
    try std.testing.expectEqualStrings("{\"session\":true}", (try site.call(sessionStatus, .GET, &.{returning})).body);

    const response = try site.call(signOut, .DELETE, &.{ same_site, local_host, returning });
    try std.testing.expect(std.mem.find(u8, response.set_cookie.?, "Max-Age=0") != null);
    try std.testing.expectEqualStrings("{\"session\":false}", (try site.call(sessionStatus, .GET, &.{returning})).body);
    try std.testing.expectError(error.Unauthorized, site.call(signOut, .DELETE, &.{ same_site, local_host, returning }));
}

test "one address may make only so many accounts, and known browsers do not count" {
    const site = try TestSite.init();
    defer site.destroy();
    var limiter: accounts.Limiter = .init(std.testing.allocator, 2, 3600);
    defer limiter.deinit();
    site.app.new_session_limiter = &limiter;
    const keep = ensure(echoUser);

    var first_request: router.RequestContext = .{
        .allocator = site.arena.allocator(),
        .method = .POST,
        .path = "/api/me",
        .query = null,
        .headers = &.{ same_site, local_host },
        .body = null,
        .client_ip = "203.0.113.4",
    };
    const first = try keep(&site.app, &first_request);
    _ = try keep(&site.app, &first_request);
    try std.testing.expectError(error.TooManyRequests, keep(&site.app, &first_request));

    // A browser that already has a session is not making an account.
    var cookie_header_buffer: [64]u8 = undefined;
    const cookie_header = try std.fmt.bufPrint(&cookie_header_buffer, "sid={s}", .{tokenOf(first.set_cookie.?)});
    first_request.headers = &.{ same_site, local_host, .{ .name = "Cookie", .value = cookie_header } };
    _ = try keep(&site.app, &first_request);

    // Another address has its own count.
    first_request.headers = &.{ same_site, local_host };
    first_request.client_ip = "203.0.113.5";
    _ = try keep(&site.app, &first_request);
}

test "the account routes need the accounts store" {
    var app: router.App = .{ .max_body_bytes = 16, .io = std.testing.io };
    var request: router.RequestContext = .{
        .allocator = std.testing.allocator,
        .method = .GET,
        .path = "/api/me",
        .query = null,
        .headers = &.{},
        .body = null,
    };
    try std.testing.expectError(error.AccountsUnavailable, sessionStatus(&app, &request));
}
