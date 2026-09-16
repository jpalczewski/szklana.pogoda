//! Public IMGW data.
//!
//! Every product lives in its own small file that owns three things: the
//! endpoint URL, the raw record shape and the mapping into the application
//! model. Products share the transport (`http`), the IMGW value coercion rules
//! (`value`) and the JSON array decoder (`records`), so adding an endpoint
//! means adding one product file rather than another copy of the plumbing.

pub const value = @import("value.zig");
pub const http = @import("http.zig");
pub const records = @import("records.zig");

/// Measurement products. Synop and meteo both yield weather observations.
pub const synop = @import("synop.zig");
pub const meteo = @import("meteo.zig");
pub const hydro = @import("hydro.zig");

/// Warning products, normalized into the shared `warnings` domain model.
pub const warnings = struct {
    pub const meteo = @import("warnings_meteo.zig");
    pub const hydro = @import("warnings_hydro.zig");

    /// Validity-window decoding shared by both warning products.
    pub const fields = @import("warning_fields.zig");
};

pub const Error = value.Error;
