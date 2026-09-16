const std = @import("std");
const sqlite = @import("sqlite");

pub const Observation = struct {
    station_id: []const u8,
    station_name: []const u8,
    observed_at: []const u8,
    temperature_c: ?f64,
    wind_speed_m_s: ?f64,
    wind_direction_deg: ?i16,
    relative_humidity_percent: ?f64,
    precipitation_mm: ?f64,
    pressure_hpa: ?f64,
};

pub const Station = struct {
    station_id: []const u8,
    station_name: []const u8,
    last_observed_at: []const u8,
};

pub const HydroStation = struct {
    station_id: []const u8,
    station_name: []const u8,
    river: []const u8,
    voivodeship: []const u8,
    longitude: ?f64,
    latitude: ?f64,
    founded_year: ?i32,
    gauge_zero_m: ?f64,
    river_km: ?f64,
    warning_level_cm: ?f64,
    alarm_level_cm: ?f64,
    water_level_cm: ?f64,
    water_level_observed_at: ?[]const u8,
    water_temperature_c: ?f64,
    water_temperature_observed_at: ?[]const u8,
    flow_m3_s: ?f64,
    flow_observed_at: ?[]const u8,
    ice_phenomenon: ?i32,
    ice_phenomenon_observed_at: ?[]const u8,
    overgrowth_phenomenon: ?i32,
    overgrowth_phenomenon_observed_at: ?[]const u8,
    water_level_status: []const u8,
};

pub const HydroObservation = HydroStation;

pub const Store = struct {
    db: sqlite.Db,

    pub fn initFile(path: [:0]const u8) !Store {
        var store: Store = .{
            .db = try sqlite.Db.init(.{
                .mode = .{ .File = path },
                .open_flags = .{ .write = true, .create = true },
                .threading_mode = .Serialized,
            }),
        };
        errdefer store.deinit();
        try store.migrate();
        return store;
    }

    pub fn initMemory() !Store {
        var store: Store = .{
            .db = try sqlite.Db.init(.{
                .mode = .Memory,
                .open_flags = .{ .write = true, .create = true },
                .threading_mode = .Serialized,
            }),
        };
        errdefer store.deinit();
        try store.migrate();
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.db.deinit();
    }

    pub fn record(self: *Store, observation: Observation) !void {
        try self.db.exec(
            \\INSERT INTO weather_observations (
            \\    station_id, station_name, observed_at, temperature_c, wind_speed_m_s,
            \\    wind_direction_deg, relative_humidity_percent, precipitation_mm, pressure_hpa
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT (station_id, observed_at) DO UPDATE SET
            \\    station_name = excluded.station_name,
            \\    temperature_c = excluded.temperature_c,
            \\    wind_speed_m_s = excluded.wind_speed_m_s,
            \\    wind_direction_deg = excluded.wind_direction_deg,
            \\    relative_humidity_percent = excluded.relative_humidity_percent,
            \\    precipitation_mm = excluded.precipitation_mm,
            \\    pressure_hpa = excluded.pressure_hpa
        ,
            .{},
            .{
                .station_id = observation.station_id,
                .station_name = observation.station_name,
                .observed_at = observation.observed_at,
                .temperature_c = observation.temperature_c,
                .wind_speed_m_s = observation.wind_speed_m_s,
                .wind_direction_deg = observation.wind_direction_deg,
                .relative_humidity_percent = observation.relative_humidity_percent,
                .precipitation_mm = observation.precipitation_mm,
                .pressure_hpa = observation.pressure_hpa,
            },
        );
    }

    pub fn history(self: *Store, allocator: std.mem.Allocator, station_id: []const u8, since: []const u8) ![]Observation {
        var statement = try self.db.prepare(
            \\SELECT station_id, station_name, observed_at, temperature_c, wind_speed_m_s,
            \\       wind_direction_deg, relative_humidity_percent, precipitation_mm, pressure_hpa
            \\FROM weather_observations
            \\WHERE station_id = ? AND observed_at >= ?
            \\ORDER BY observed_at ASC
        );
        defer statement.deinit();
        return statement.all(Observation, allocator, .{}, .{ .station_id = station_id, .since = since });
    }

    pub fn stations(self: *Store, allocator: std.mem.Allocator) ![]Station {
        var statement = try self.db.prepare(
            \\SELECT station_id, station_name, MAX(observed_at)
            \\FROM weather_observations
            \\GROUP BY station_id, station_name
            \\ORDER BY station_name COLLATE NOCASE ASC
        );
        defer statement.deinit();
        return statement.all(Station, allocator, .{}, .{});
    }

    pub fn recordHydro(self: *Store, item: HydroObservation) !void {
        try self.db.exec(
            \\INSERT INTO hydro_observations (station_id, station_name, river, voivodeship, longitude, latitude, founded_year, gauge_zero_m, river_km, warning_level_cm, alarm_level_cm, water_level_cm, water_level_observed_at, water_temperature_c, water_temperature_observed_at, flow_m3_s, flow_observed_at, ice_phenomenon, ice_phenomenon_observed_at, overgrowth_phenomenon, overgrowth_phenomenon_observed_at, water_level_status)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT (station_id, water_level_observed_at) DO UPDATE SET
            \\ station_name=excluded.station_name, river=excluded.river, voivodeship=excluded.voivodeship, longitude=excluded.longitude, latitude=excluded.latitude, founded_year=excluded.founded_year, gauge_zero_m=excluded.gauge_zero_m, river_km=excluded.river_km, warning_level_cm=excluded.warning_level_cm, alarm_level_cm=excluded.alarm_level_cm, water_level_cm=excluded.water_level_cm, water_temperature_c=excluded.water_temperature_c, water_temperature_observed_at=excluded.water_temperature_observed_at, flow_m3_s=excluded.flow_m3_s, flow_observed_at=excluded.flow_observed_at, ice_phenomenon=excluded.ice_phenomenon, ice_phenomenon_observed_at=excluded.ice_phenomenon_observed_at, overgrowth_phenomenon=excluded.overgrowth_phenomenon, overgrowth_phenomenon_observed_at=excluded.overgrowth_phenomenon_observed_at, water_level_status=excluded.water_level_status
        , .{}, .{ .station_id = item.station_id, .station_name = item.station_name, .river = item.river, .voivodeship = item.voivodeship, .longitude = item.longitude, .latitude = item.latitude, .founded_year = item.founded_year, .gauge_zero_m = item.gauge_zero_m, .river_km = item.river_km, .warning_level_cm = item.warning_level_cm, .alarm_level_cm = item.alarm_level_cm, .water_level_cm = item.water_level_cm, .water_level_observed_at = item.water_level_observed_at, .water_temperature_c = item.water_temperature_c, .water_temperature_observed_at = item.water_temperature_observed_at, .flow_m3_s = item.flow_m3_s, .flow_observed_at = item.flow_observed_at, .ice_phenomenon = item.ice_phenomenon, .ice_phenomenon_observed_at = item.ice_phenomenon_observed_at, .overgrowth_phenomenon = item.overgrowth_phenomenon, .overgrowth_phenomenon_observed_at = item.overgrowth_phenomenon_observed_at, .water_level_status = item.water_level_status });
    }

    pub fn hydroStations(self: *Store, allocator: std.mem.Allocator) ![]HydroStation {
        var statement = try self.db.prepare(
            \\SELECT station_id, station_name, river, voivodeship, longitude, latitude, founded_year, gauge_zero_m, river_km, warning_level_cm, alarm_level_cm, water_level_cm, water_level_observed_at, water_temperature_c, water_temperature_observed_at, flow_m3_s, flow_observed_at, ice_phenomenon, ice_phenomenon_observed_at, overgrowth_phenomenon, overgrowth_phenomenon_observed_at, water_level_status
            \\FROM hydro_observations
            \\WHERE water_level_observed_at = (SELECT MAX(h.water_level_observed_at) FROM hydro_observations h WHERE h.station_id = hydro_observations.station_id)
        );
        defer statement.deinit();
        return statement.all(HydroStation, allocator, .{}, .{});
    }

    pub fn hydroHistory(self: *Store, allocator: std.mem.Allocator, station_id: []const u8, since: []const u8) ![]HydroObservation {
        var statement = try self.db.prepare(
            \\SELECT station_id, station_name, river, voivodeship, longitude, latitude, founded_year, gauge_zero_m, river_km, warning_level_cm, alarm_level_cm, water_level_cm, water_level_observed_at, water_temperature_c, water_temperature_observed_at, flow_m3_s, flow_observed_at, ice_phenomenon, ice_phenomenon_observed_at, overgrowth_phenomenon, overgrowth_phenomenon_observed_at, water_level_status
            \\FROM hydro_observations WHERE station_id = ? AND water_level_observed_at >= ? ORDER BY water_level_observed_at ASC
        );
        defer statement.deinit();
        return statement.all(HydroObservation, allocator, .{}, .{ .station_id = station_id, .since = since });
    }

    pub fn deinitHydro(allocator: std.mem.Allocator, items: []HydroObservation) void {
        for (items) |item| {
            allocator.free(item.station_id);
            allocator.free(item.station_name);
            allocator.free(item.river);
            allocator.free(item.voivodeship);
            allocator.free(item.water_level_status);
            inline for (.{ "water_level_observed_at", "water_temperature_observed_at", "flow_observed_at", "ice_phenomenon_observed_at", "overgrowth_phenomenon_observed_at" }) |field| {
                if (@field(item, field)) |value| allocator.free(value);
            }
        }
        allocator.free(items);
    }

    pub fn deinitHistory(allocator: std.mem.Allocator, observations: []Observation) void {
        deinitHistoryItems(allocator, observations);
        allocator.free(observations);
    }

    pub fn deinitHistoryItems(allocator: std.mem.Allocator, observations: []Observation) void {
        for (observations) |observation| {
            allocator.free(observation.station_id);
            allocator.free(observation.station_name);
            allocator.free(observation.observed_at);
        }
    }

    pub fn deinitStations(allocator: std.mem.Allocator, items: []Station) void {
        for (items) |station| {
            allocator.free(station.station_id);
            allocator.free(station.station_name);
            allocator.free(station.last_observed_at);
        }
        allocator.free(items);
    }

    fn migrate(self: *Store) !void {
        try self.db.execMulti(
            \\CREATE TABLE IF NOT EXISTS weather_observations (
            \\    station_id TEXT NOT NULL,
            \\    station_name TEXT NOT NULL,
            \\    observed_at TEXT NOT NULL,
            \\    temperature_c REAL,
            \\    wind_speed_m_s REAL,
            \\    wind_direction_deg INTEGER,
            \\    relative_humidity_percent REAL,
            \\    precipitation_mm REAL,
            \\    pressure_hpa REAL,
            \\    PRIMARY KEY (station_id, observed_at)
            \\);
            \\CREATE INDEX IF NOT EXISTS weather_observations_station_time
            \\    ON weather_observations (station_id, observed_at);
            \\CREATE TABLE IF NOT EXISTS hydro_observations (station_id TEXT NOT NULL, station_name TEXT NOT NULL, river TEXT NOT NULL, voivodeship TEXT NOT NULL, longitude REAL, latitude REAL, founded_year INTEGER, gauge_zero_m REAL, river_km REAL, warning_level_cm REAL, alarm_level_cm REAL, water_level_cm REAL, water_level_observed_at TEXT NOT NULL, water_temperature_c REAL, water_temperature_observed_at TEXT, flow_m3_s REAL, flow_observed_at TEXT, ice_phenomenon INTEGER, ice_phenomenon_observed_at TEXT, overgrowth_phenomenon INTEGER, overgrowth_phenomenon_observed_at TEXT, water_level_status TEXT NOT NULL, PRIMARY KEY (station_id, water_level_observed_at));
            \\CREATE INDEX IF NOT EXISTS hydro_observations_station_time ON hydro_observations (station_id, water_level_observed_at);
        ,
            .{},
        );
    }
};

test "stores each station observation once and returns its history" {
    var store = try Store.initMemory();
    defer store.deinit();

    try store.record(.{
        .station_id = "12424",
        .station_name = "Wrocław",
        .observed_at = "2026-09-16T17:00:00Z",
        .temperature_c = 18.2,
        .wind_speed_m_s = 3,
        .wind_direction_deg = 220,
        .relative_humidity_percent = 71.5,
        .precipitation_mm = 0,
        .pressure_hpa = 1012.4,
    });
    try store.record(.{
        .station_id = "12424",
        .station_name = "Wrocław",
        .observed_at = "2026-09-16T17:00:00Z",
        .temperature_c = 18.5,
        .wind_speed_m_s = 3,
        .wind_direction_deg = 220,
        .relative_humidity_percent = 71.5,
        .precipitation_mm = 0,
        .pressure_hpa = 1012.4,
    });

    const observations = try store.history(std.testing.allocator, "12424", "2026-09-16T00:00:00Z");
    defer Store.deinitHistory(std.testing.allocator, observations);

    try std.testing.expectEqual(@as(usize, 1), observations.len);
    try std.testing.expectEqualStrings("Wrocław", observations[0].station_name);
    try std.testing.expectApproxEqAbs(@as(f64, 18.5), observations[0].temperature_c.?, 0.001);
}
