//! Sign-in codes: `/api/me/transfer-code`, `/api/me/recovery-code` and
//! `/api/me/login`.
//!
//! A browser that is signed in asks for a code and shows it to its person once,
//! who types it into another browser (a transfer code, ten minutes) or keeps it
//! for the day every browser is lost (a recovery code). Typing it into
//! `/api/me/login` signs that browser in to the account and joins whatever it
//! held on its own into it. A code travels only in a request or response body,
//! never in a URL, is never written to a log, an error or a metric label, and
//! only its hash is stored.
//!
//! All three answer to a request that changes state, so they take the same
//! `Origin` check as the rest of `/api/me`, and one address may ask only so
//! often: for a code, because a stolen cookie could otherwise mint recovery codes
//! until the owner's own no longer works; to sign in, because a transfer code is
//! short enough to be worth guessing.

const std = @import("std");
const router = @import("../router.zig");
const accounts = @import("../accounts/mod.zig");
const account = @import("account.zig");
const metrics = @import("../metrics/mod.zig");

const Kind = accounts.code.Kind;

/// Tries this many random codes before giving up on a collision with another
/// user's, which with this many bits does not happen.
const max_draws = 3;

const TransferResponse = struct {
    code: []const u8,
    expires_in_seconds: i64,
};

const RecoveryResponse = struct {
    code: []const u8,
};

const LoginRequest = struct {
    code: []const u8,
};

const LoginResponse = struct {
    session: bool,
    /// The browser held an account of its own, and it was joined into this one.
    merged: bool,
};

/// `POST /api/me/transfer-code`: a code for another browser to sign in with. It
/// replaces the one this account had.
pub const transferCode = account.require(transferCodeHandler);

/// `POST /api/me/recovery-code`: a code that signs in again and again, shown
/// only now. It replaces the one this account had, which stops working.
pub const recoveryCode = account.require(recoveryCodeHandler);

fn transferCodeHandler(app: *router.App, request: *router.RequestContext, session: account.Session) router.AppError!router.Response {
    var text_buffer: [accounts.code.max_formatted_length]u8 = undefined;
    const text = try issue(app, request, session, .transfer, &text_buffer);
    return router.Response.jsonValue(request.allocator, .ok, TransferResponse{
        .code = text,
        .expires_in_seconds = accounts.store.transfer_code_seconds,
    });
}

fn recoveryCodeHandler(app: *router.App, request: *router.RequestContext, session: account.Session) router.AppError!router.Response {
    var text_buffer: [accounts.code.max_formatted_length]u8 = undefined;
    const text = try issue(app, request, session, .recovery, &text_buffer);
    return router.Response.jsonValue(request.allocator, .ok, RecoveryResponse{ .code = text });
}

/// `POST /api/me/login` with `{"code": "..."}`: signs the browser in to the
/// account the code belongs to and sets a new session cookie. A browser that
/// held an account of its own has it joined in. It never makes an account: with
/// no session and no valid code there is nothing to sign in to.
pub const login = account.optional(loginHandler);

fn loginHandler(app: *router.App, request: *router.RequestContext, session: ?account.Session) router.AppError!router.Response {
    const store = app.accounts orelse return error.AccountsUnavailable;
    const io = app.io orelse return error.AccountsUnavailable;
    const now = account.nowSeconds(io);

    try account.requireJson(request);
    if (app.login_limiter) |limiter| {
        // Before the code is read, so a refused request costs nothing and its
        // kind is not known.
        if (!limiter.allow(io, request.client_ip, now)) {
            countLogin(app, .unknown, .limited);
            return error.TooManyRequests;
        }
    }

    var code = readCode(request) catch |err| {
        if (err == error.InvalidCode) countLogin(app, .unknown, .invalid);
        return err;
    };
    defer std.crypto.secureZero(u8, &code.chars);
    const kind = loginKind(code.kind);

    const new_token = accounts.token.generate(io) catch |err| {
        std.log.err("no secure randomness for a session token: {t}", .{err});
        return error.AccountsUnavailable;
    };
    const current: ?accounts.token.Hash = if (session) |caller| caller.token_hash else null;
    const redeemed = store.redeem(io, code, current, accounts.token.hash(&new_token).?, now) catch |err| switch (err) {
        error.InvalidCode => {
            countLogin(app, kind, .invalid);
            return error.InvalidCode;
        },
        else => {
            std.log.err("signing in with a code failed: {t}", .{err});
            return error.AccountsUnavailable;
        },
    };
    countLogin(app, kind, .succeeded);

    var response = try router.Response.jsonValue(request.allocator, .ok, LoginResponse{ .session = true, .merged = redeemed.merged });
    // A browser that was already in this account keeps its session.
    if (redeemed.signed_in) response.set_cookie = try accounts.cookie.set(request.allocator, app.cookie_policy, new_token);
    return response;
}

/// The code in the body, in canonical form. A body that is not `{"code": "…"}` is
/// a bad request; text that cannot be a code is an invalid one.
fn readCode(request: *router.RequestContext) router.AppError!accounts.code.Code {
    const body = request.body orelse return error.BadRequest;
    const bytes = try body.readAll(request.allocator);
    defer std.crypto.secureZero(u8, bytes);
    const parsed = std.json.parseFromSlice(LoginRequest, request.allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.BadRequest;
    defer parsed.deinit();
    return accounts.code.normalise(parsed.value.code) orelse error.InvalidCode;
}

fn loginKind(kind: Kind) metrics.LoginKind {
    return switch (kind) {
        .recovery => .recovery,
        .transfer => .transfer,
    };
}

fn countLogin(app: *router.App, kind: metrics.LoginKind, result: metrics.LoginResult) void {
    if (app.metrics) |registry| registry.loginAttempt(kind, result);
}

/// Draws and stores a code of `kind` for the caller's account and returns it as
/// it is shown, in `buffer`.
fn issue(
    app: *router.App,
    request: *router.RequestContext,
    session: account.Session,
    kind: Kind,
    buffer: *[accounts.code.max_formatted_length]u8,
) router.AppError![]const u8 {
    const store = app.accounts orelse return error.AccountsUnavailable;
    const io = app.io orelse return error.AccountsUnavailable;
    const now = account.nowSeconds(io);
    if (app.code_limiter) |limiter| {
        if (!limiter.allow(io, request.client_ip, now)) return error.TooManyRequests;
    }

    for (0..max_draws) |_| {
        var code = accounts.code.generate(io, kind) catch |err| {
            std.log.err("no secure randomness for a sign-in code: {t}", .{err});
            return error.AccountsUnavailable;
        };
        defer std.crypto.secureZero(u8, &code.chars);

        const stored: anyerror!void = switch (kind) {
            .transfer => store.issueTransferCode(io, session.user_id, code.hash(), now),
            .recovery => store.issueRecoveryCode(io, session.user_id, code.hash()),
        };
        stored catch |err| switch (err) {
            error.CodeCollision => continue,
            else => {
                std.log.err("storing a {t} code failed: {t}", .{ kind, err });
                return error.AccountsUnavailable;
            },
        };
        return code.format(buffer);
    }
    std.log.err("no {t} code could be stored after {d} draws", .{ kind, max_draws });
    return error.AccountsUnavailable;
}

const testing_site = @import("account_testing.zig");
const Site = testing_site.Site;

/// A request of a browser on the site's own origin, holding `browser`'s session.
fn asBrowser(site: *Site, browser: testing_site.Browser, handler: router.Handler, client_ip: []const u8) router.AppError!router.Response {
    return site.send(handler, .{
        .method = .POST,
        .headers = &.{ testing_site.same_site, testing_site.local_host, .{ .name = "Cookie", .value = browser.cookie } },
        .client_ip = client_ip,
    });
}

fn clockNow() i64 {
    return std.Io.Clock.real.now(std.testing.io).toSeconds();
}

/// The code out of a `{"code":"…"}` body, in canonical form.
fn codeIn(body: []const u8) accounts.code.Code {
    const start = std.mem.find(u8, body, "\"code\":\"").? + "\"code\":\"".len;
    const end = std.mem.findScalarPos(u8, body, start, '"').?;
    return accounts.code.normalise(body[start..end]).?;
}

test "a signed-in browser is given a transfer code that another browser can sign in with" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();

    const response = try asBrowser(site, owner, transferCode, "203.0.113.4");
    try std.testing.expectEqualStrings("private, no-store", response.cache_control.?);
    try std.testing.expect(response.set_cookie == null);
    try std.testing.expect(std.mem.find(u8, response.body, "\"expires_in_seconds\":600") != null);
    const code = codeIn(response.body);
    try std.testing.expectEqual(Kind.transfer, code.kind);

    const other = try site.store.redeem(std.testing.io, code, null, accounts.token.hash(&(try accounts.token.generate(std.testing.io))).?, clockNow());
    try std.testing.expectEqual(owner.user_id, other.user_id);
}

test "a new transfer code replaces the one before it" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();

    const first = codeIn((try asBrowser(site, owner, transferCode, "")).body);
    const second = codeIn((try asBrowser(site, owner, transferCode, "")).body);
    const fresh = accounts.token.hash(&(try accounts.token.generate(std.testing.io))).?;
    try std.testing.expectError(error.InvalidCode, site.store.redeem(std.testing.io, first, null, fresh, clockNow()));
    _ = try site.store.redeem(std.testing.io, second, null, fresh, clockNow());
}

test "a recovery code is long, is shown in the answer and is remembered as set" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    try std.testing.expect(!try site.store.hasRecovery(owner.user_id));

    const response = try asBrowser(site, owner, recoveryCode, "");
    try std.testing.expect(std.mem.find(u8, response.body, "expires") == null);
    const code = codeIn(response.body);
    try std.testing.expectEqual(Kind.recovery, code.kind);
    try std.testing.expect(try site.store.hasRecovery(owner.user_id));

    const back = try site.store.redeem(std.testing.io, code, null, accounts.token.hash(&(try accounts.token.generate(std.testing.io))).?, clockNow());
    try std.testing.expectEqual(owner.user_id, back.user_id);
}

test "a new recovery code retires the old one" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    const first = codeIn((try asBrowser(site, owner, recoveryCode, "")).body);
    _ = codeIn((try asBrowser(site, owner, recoveryCode, "")).body);
    try std.testing.expectError(error.InvalidCode, site.store.redeem(std.testing.io, first, null, accounts.token.hash(&(try accounts.token.generate(std.testing.io))).?, clockNow()));
}

test "codes are issued only to a browser with a session, from the site's own origin" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();

    try std.testing.expectError(error.Unauthorized, site.call(transferCode, .POST, &.{ testing_site.same_site, testing_site.local_host }));
    try std.testing.expectError(error.Forbidden, site.call(transferCode, .POST, &.{.{ .name = "Cookie", .value = owner.cookie }}));
    try std.testing.expectError(error.Forbidden, site.call(recoveryCode, .POST, &.{ .{ .name = "Origin", .value = "https://evil.example" }, testing_site.local_host, .{ .name = "Cookie", .value = owner.cookie } }));
}

test "one address may ask for only so many codes" {
    const site = try Site.create();
    defer site.destroy();
    var limiter: accounts.Limiter = .init(std.testing.allocator, 2, 3600, .refuse);
    defer limiter.deinit();
    site.app.code_limiter = &limiter;
    const owner = try site.browser();

    _ = try asBrowser(site, owner, transferCode, "203.0.113.4");
    _ = try asBrowser(site, owner, recoveryCode, "203.0.113.4");
    try std.testing.expectError(error.TooManyRequests, asBrowser(site, owner, transferCode, "203.0.113.4"));
    _ = try asBrowser(site, owner, transferCode, "203.0.113.5");
}

test "whether the account has a recovery code is reported to its browser" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    const status_headers = [_]router.Header{.{ .name = "Cookie", .value = owner.cookie }};

    const before = try site.call(account.sessionStatus, .GET, &status_headers);
    try std.testing.expectEqualStrings("{\"session\":true,\"has_recovery\":false}", before.body);
    _ = try asBrowser(site, owner, recoveryCode, "");
    const after = try site.call(account.sessionStatus, .GET, &status_headers);
    try std.testing.expectEqualStrings("{\"session\":true,\"has_recovery\":true}", after.body);
}

/// A request to `/api/me/login` from a browser on the site's own origin.
fn signInWith(site: *Site, cookie: ?[]const u8, body: []const u8) router.AppError!router.Response {
    const json: router.Header = .{ .name = "Content-Type", .value = "application/json" };
    const with_cookie = [_]router.Header{ testing_site.same_site, testing_site.local_host, json, .{ .name = "Cookie", .value = cookie orelse "" } };
    return site.send(login, .{
        .method = .POST,
        .headers = if (cookie != null) &with_cookie else with_cookie[0..3],
        .body = body,
        .client_ip = "203.0.113.4",
    });
}

fn codeBody(site: *Site, code: accounts.code.Code) ![]const u8 {
    return std.fmt.allocPrint(site.arena.allocator(), "{{\"code\":\"{s}\"}}", .{code.text()});
}

fn transferFor(site: *Site, owner: testing_site.Browser) !accounts.code.Code {
    return codeIn((try asBrowser(site, owner, transferCode, "")).body);
}

fn sessionOf(site: *Site, cookie: []const u8) ![]const u8 {
    return (try site.call(account.sessionStatus, .GET, &.{.{ .name = "Cookie", .value = cookie }})).body;
}

test "a transfer code signs another browser in and joins the account it had" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    const visitor = try site.browser();
    try site.store.addFavorite(owner.user_id, "Zakopane", 1);
    try site.store.addFavorite(visitor.user_id, "Gdańsk", 2);
    const code = try transferFor(site, owner);

    const response = try signInWith(site, visitor.cookie, try codeBody(site, code));
    try std.testing.expectEqualStrings("{\"session\":true,\"merged\":true}", response.body);
    try std.testing.expectEqualStrings("private, no-store", response.cache_control.?);
    try std.testing.expect(std.mem.startsWith(u8, response.set_cookie.?, "sid="));

    // The token the browser had is gone and the one it was given is the owner's.
    try std.testing.expectEqualStrings("{\"session\":false,\"has_recovery\":false}", try sessionOf(site, visitor.cookie));
    const given = try std.fmt.allocPrint(site.arena.allocator(), "sid={s}", .{testing_site.tokenOf(response.set_cookie.?)});
    try std.testing.expectEqualStrings("{\"session\":true,\"has_recovery\":false}", try sessionOf(site, given));
    const names = try site.store.favorites(std.testing.allocator, owner.user_id);
    defer {
        for (names) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
}

test "a browser with no session is signed in and has nothing to join" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    const code = try transferFor(site, owner);

    const response = try signInWith(site, null, try codeBody(site, code));
    try std.testing.expectEqualStrings("{\"session\":true,\"merged\":false}", response.body);
    try std.testing.expect(response.set_cookie != null);
}

test "a browser already in the account keeps its session and is not given another" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    const code = try transferFor(site, owner);

    const response = try signInWith(site, owner.cookie, try codeBody(site, code));
    try std.testing.expectEqualStrings("{\"session\":true,\"merged\":false}", response.body);
    try std.testing.expect(response.set_cookie == null);
    try std.testing.expectEqualStrings("{\"session\":true,\"has_recovery\":false}", try sessionOf(site, owner.cookie));
}

test "a recovery code signs in again and again" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    const code = codeIn((try asBrowser(site, owner, recoveryCode, "")).body);

    for (0..2) |_| {
        const response = try signInWith(site, null, try codeBody(site, code));
        try std.testing.expect(response.set_cookie != null);
    }
}

test "a code that is wrong, spent or nonsense is refused the same way" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    const code = try transferFor(site, owner);

    _ = try signInWith(site, null, try codeBody(site, code));
    try std.testing.expectError(error.InvalidCode, signInWith(site, null, try codeBody(site, code)));
    try std.testing.expectError(error.InvalidCode, signInWith(site, null, "{\"code\":\"ABCDE12345\"}"));
    try std.testing.expectError(error.InvalidCode, signInWith(site, null, "{\"code\":\"not a code\"}"));
    try std.testing.expectError(error.InvalidCode, signInWith(site, null, "{\"code\":\"\"}"));
}

test "a body that is not a code request is a bad request" {
    const site = try Site.create();
    defer site.destroy();
    try std.testing.expectError(error.BadRequest, signInWith(site, null, "not json"));
    try std.testing.expectError(error.BadRequest, signInWith(site, null, "{}"));
    try std.testing.expectError(error.BadRequest, signInWith(site, null, "{\"code\":5}"));
    // No declared content type, whatever it says.
    try std.testing.expectError(error.BadRequest, site.send(login, .{
        .method = .POST,
        .headers = &.{ testing_site.same_site, testing_site.local_host },
        .body = "{\"code\":\"ABCDE12345\"}",
    }));
    // No body at all.
    try std.testing.expectError(error.BadRequest, site.send(login, .{
        .method = .POST,
        .headers = &.{ testing_site.same_site, testing_site.local_host, .{ .name = "Content-Type", .value = "application/json" } },
    }));
}

test "signing in needs the site's own origin" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    const code = try transferFor(site, owner);
    const json: router.Header = .{ .name = "Content-Type", .value = "application/json" };
    const body = try codeBody(site, code);

    try std.testing.expectError(error.Forbidden, site.send(login, .{ .method = .POST, .headers = &.{ testing_site.local_host, json }, .body = body }));
    try std.testing.expectError(error.Forbidden, site.send(login, .{
        .method = .POST,
        .headers = &.{ .{ .name = "Origin", .value = "https://evil.example" }, testing_site.local_host, json },
        .body = body,
    }));
    // Refused before the code was touched: it still works from the right origin.
    _ = try signInWith(site, null, body);
}

test "one address may try only so many codes, and the attempts are counted by kind" {
    const site = try Site.create();
    defer site.destroy();
    var limiter: accounts.Limiter = .init(std.testing.allocator, 3, 600, .refuse);
    defer limiter.deinit();
    site.app.login_limiter = &limiter;
    var registry = metrics.Registry.init(std.testing.allocator);
    defer registry.deinit();
    registry.declareLogins();
    site.app.metrics = &registry;
    const owner = try site.browser();
    const code = try transferFor(site, owner);

    try std.testing.expectError(error.InvalidCode, signInWith(site, null, "{\"code\":\"ABCDE12345\"}"));
    try std.testing.expectError(error.InvalidCode, signInWith(site, null, "{\"code\":\"nonsense\"}"));
    _ = try signInWith(site, null, try codeBody(site, code));
    // The right code, but this address has used up its attempts.
    try std.testing.expectError(error.TooManyRequests, signInWith(site, null, try codeBody(site, try transferFor(site, owner))));

    const rendered = try registry.renderAlloc(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    for ([_][]const u8{
        "szklana_pogoda_login_attempts_total{kind=\"transfer\",result=\"invalid\"} 1\n",
        "szklana_pogoda_login_attempts_total{kind=\"unknown\",result=\"invalid\"} 1\n",
        "szklana_pogoda_login_attempts_total{kind=\"transfer\",result=\"succeeded\"} 1\n",
        "szklana_pogoda_login_attempts_total{kind=\"unknown\",result=\"limited\"} 1\n",
    }) |expected| {
        try std.testing.expect(std.mem.find(u8, rendered, expected) != null);
    }
}

test "the code is never echoed back" {
    const site = try Site.create();
    defer site.destroy();
    const owner = try site.browser();
    const code = try transferFor(site, owner);

    const response = try signInWith(site, null, try codeBody(site, code));
    try std.testing.expect(std.mem.find(u8, response.body, code.text()) == null);
    try std.testing.expect(std.mem.find(u8, response.set_cookie.?, code.text()) == null);
}
