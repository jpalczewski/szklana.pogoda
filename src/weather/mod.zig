//! The weather domain.
//!
//! The observation and hydro models, their SQLite store and the updater that
//! keeps both fed from the IMGW sources. The IMGW client lives in `imgw/` and
//! maps its wire records into the model, so the sources depend on the model
//! rather than on storage. The warning model stays in `warnings.zig` and is
//! re-exported here so callers have a single import site.

/// Model types and the ownership rules for their text fields.
pub const model = @import("model.zig");

const store = @import("store.zig");

pub const Store = store.Store;
pub const WarningFilter = store.WarningFilter;

pub const Observation = model.Observation;
pub const Station = model.Station;
pub const HydroObservation = model.HydroObservation;
pub const HydroStation = model.HydroStation;

/// The polling loop that feeds the store from the IMGW products.
pub const updater = @import("updater.zig");

/// The warning domain, owned by `warnings.zig` and only surfaced here.
pub const warnings = @import("../warnings.zig");
pub const Warning = warnings.Warning;
pub const WarningArea = warnings.Area;
pub const WarningSource = warnings.Source;
