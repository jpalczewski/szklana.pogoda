//! Sign-in codes: `/api/me/transfer-code` and `/api/me/recovery-code`.
//!
//! A browser that is signed in asks for a code and shows it to its person once,
//! who types it into another browser (a transfer code, ten minutes) or keeps it
//! for the day every browser is lost (a recovery code). The code travels only in
//! the response body, is never written to a log, and only its hash is stored.
//!
//! Both answer to a request that changes state, so they take the same `Origin`
//! check as the rest of `/api/me`, and one address may ask only so often: a
//! stolen cookie could otherwise mint recovery codes until the owner's own no
//! longer works.

const std = @import("std");
const router = @import("../router.zig");
const accounts = @import("../accounts/mod.zig");
const account = @import("account.zig");

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
