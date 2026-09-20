//! Accounts: anonymous users and the sessions that identify a browser as one.
//!
//! `store.zig` owns the SQLite file and its schema, `token.zig` what the cookie
//! carries and what the database keeps of it, and `cookie.zig` how that travels
//! in HTTP headers. The routes that use them live in `routes/account.zig`, so
//! this module knows nothing about the router.

pub const token = @import("token.zig");
pub const cookie = @import("cookie.zig");
pub const store = @import("store.zig");

pub const Store = store.Store;
pub const Lookup = store.Lookup;
