//! A stand-in for the site, for the tests of the account routes: an in-memory
//! accounts store behind an `App`, and a way to call a handler as a browser
//! would. Only tests import this file. It is not in `main`'s `modules` because
//! it holds no tests of its own and `std.testing` exists only in test builds.

const std = @import("std");
const router = @import("../router.zig");
const accounts = @import("../accounts/mod.zig");

/// The headers a browser on `http://localhost:8080` puts on a request that
/// changes state.
pub const same_site: router.Header = .{ .name = "Origin", .value = "http://localhost:8080" };
pub const local_host: router.Header = .{ .name = "Host", .value = "localhost:8080" };

pub const Request = struct {
    method: std.http.Method = .GET,
    query: ?[]const u8 = null,
    headers: []const router.Header = &.{},
    body: ?[]const u8 = null,
    client_ip: []const u8 = "",
};

pub const Browser = struct {
    user_id: i64,
    /// The `Cookie` header value.
    cookie: []const u8,
};

pub const Site = struct {
    store: accounts.Store,
    arena: std.heap.ArenaAllocator,
    app: router.App,

    pub fn create() !*Site {
        const site = try std.testing.allocator.create(Site);
        site.* = .{
            .store = try accounts.Store.initMemory(),
            .arena = .init(std.testing.allocator),
            .app = .{ .max_body_bytes = 256, .io = std.testing.io },
        };
        site.app.accounts = &site.store;
        return site;
    }

    pub fn destroy(self: *Site) void {
        self.arena.deinit();
        self.store.deinit();
        std.testing.allocator.destroy(self);
    }

    pub fn send(self: *Site, handler: router.Handler, request: Request) router.AppError!router.Response {
        var reader: std.Io.Reader = .fixed(request.body orelse "");
        var body: router.Body = .init(&reader, self.app.max_body_bytes);
        var context: router.RequestContext = .{
            .allocator = self.arena.allocator(),
            .method = request.method,
            .path = "/api/me",
            .query = request.query,
            .headers = request.headers,
            .body = if (request.body != null) &body else null,
            .client_ip = request.client_ip,
        };
        return handler(&self.app, &context);
    }

    /// A browser that already has a session: a new user and the cookie header
    /// its requests carry.
    pub fn browser(self: *Site) !Browser {
        const now = std.Io.Clock.real.now(std.testing.io).toSeconds();
        const text = try accounts.token.generate(std.testing.io);
        const user_id = try self.store.createUser(now);
        try self.store.createSession(user_id, accounts.token.hash(&text).?, now);
        const cookie = try std.fmt.allocPrint(self.arena.allocator(), "sid={s}", .{&text});
        return .{ .user_id = user_id, .cookie = cookie };
    }

    /// `send` with only a method and headers.
    pub fn call(self: *Site, handler: router.Handler, method: std.http.Method, headers: []const router.Header) router.AppError!router.Response {
        return self.send(handler, .{ .method = method, .headers = headers });
    }
};

/// The token a `Set-Cookie` value carries, which the next request sends back.
pub fn tokenOf(set_cookie: []const u8) []const u8 {
    const start = std.mem.findScalar(u8, set_cookie, '=').? + 1;
    return set_cookie[start..][0..accounts.token.text_len];
}
