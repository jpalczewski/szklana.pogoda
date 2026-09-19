//! Open-Meteo's forecast: current conditions, a daily summary and the next
//! 24 hours.
//!
//! One module for the public Open-Meteo endpoint: the domain model
//! (`model`), independent of I/O, and the client that turns a coordinate
//! into a forecast (`client`). Nothing here depends on the weather store or
//! on IMGW: Open-Meteo is the only source this module reads.

pub const model = @import("model.zig");
pub const client = @import("client.zig");

pub const Client = client.Client;
pub const Forecast = model.Forecast;
pub const Current = model.Current;
pub const Day = model.Day;
pub const Hour = model.Hour;
pub const Error = client.Error;
