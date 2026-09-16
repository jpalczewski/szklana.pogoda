const std = @import("std");
const sqlite = @import("sqlite");
const warnings = @import("warnings.zig");

pub const Warning = warnings.Warning;
pub const WarningArea = warnings.Area;
pub const WarningSource = warnings.Source;

/// Everything that narrows a warning query. `effective_to_gte` compares
/// against IMGW's `"YYYY-MM-DD HH:MM:SS"` local-time format and expresses
/// "still valid at", while `latest_only` collapses each warning to its newest
/// revision.
pub const WarningFilter = struct {
    warning_id: ?[]const u8 = null,
    source: ?WarningSource = null,
    teryt: ?[]const u8 = null,
    effective_to_gte: ?[]const u8 = null,
    latest_only: bool = false,
};

/// One row of `weather_warnings` as stored: text columns are read as owned
/// slices that are handed over to the caller's `Warning`.
const WarningRow = struct {
    source: []const u8,
    warning_id: []const u8,
    revision: i64,
    event: []const u8,
    severity: ?i16,
    probability_percent: ?i16,
    office: []const u8,
    published_at: []const u8,
    effective_from: []const u8,
    effective_to: []const u8,
    content: []const u8,
    comment: ?[]const u8,
    first_seen_at: []const u8,
    last_seen_at: []const u8,
};

const AreaRow = struct {
    source: []const u8,
    warning_id: []const u8,
    revision: i64,
    teryt: []const u8,
    voivodeship: []const u8,
    description: []const u8,
    basin_code: []const u8,
};

const WarningRevisionRow = struct {
    revision: u32,
    /// Wyhash of the warning content, bit cast to a signed integer so SQLite
    /// can store and compare it without any text handling.
    content_hash: i64,
};

/// Both warning queries share the same filter and the same ordering so they
/// can be zipped in a single merge pass.
const warning_select =
    \\SELECT w.source, w.warning_id, w.revision, w.event, w.severity,
    \\       w.probability_percent, w.office, w.published_at, w.effective_from,
    \\       w.effective_to, w.content, w.comment, w.first_seen_at, w.last_seen_at
    \\FROM weather_warnings w
;
const warning_order = "\nORDER BY w.source ASC, w.warning_id ASC, w.revision ASC";

const warning_area_select =
    \\SELECT a.source, a.warning_id, a.revision, a.teryt, a.voivodeship, a.description, a.basin_code
    \\FROM weather_warning_areas a
    \\JOIN weather_warnings w
    \\  ON w.source = a.source AND w.warning_id = a.warning_id AND w.revision = a.revision
;
const warning_area_order = "\nORDER BY a.source ASC, a.warning_id ASC, a.revision ASC";

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

    /// Stores every warning of a fresh IMGW response. A warning already known
    /// with unchanged content only gets `last_seen_at` refreshed; changed
    /// content becomes a new revision, which is what keeps the full history
    /// without duplicating rows on every poll.
    ///
    /// The statements are not wrapped in one transaction: the updater task
    /// writes observations over the same serialized connection, so a `BEGIN`
    /// here could swallow unrelated writes and roll them back. Areas are
    /// written with `INSERT OR IGNORE` instead, which makes a batch that was
    /// interrupted halfway heal on the next poll.
    pub fn recordWarnings(self: *Store, items: []const Warning, seen_at: []const u8) !usize {
        var stored: usize = 0;
        for (items) |item| {
            try self.recordWarning(item, seen_at);
            stored += 1;
        }
        return stored;
    }

    fn recordWarning(self: *Store, item: Warning, seen_at: []const u8) !void {
        const content_hash: i64 = @bitCast(warnings.contentHash(item));
        const latest = try self.latestWarningRevision(item.source, item.warning_id);
        if (latest) |previous| {
            if (previous.content_hash == content_hash) {
                try self.db.exec(
                    \\UPDATE weather_warnings SET last_seen_at = ?
                    \\WHERE source = ? AND warning_id = ? AND revision = ?
                ,
                    .{},
                    .{ seen_at, @tagName(item.source), item.warning_id, previous.revision },
                );
                try self.insertWarningAreas(item, previous.revision);
                return;
            }
            return self.insertWarning(item, previous.revision + 1, content_hash, seen_at);
        }
        return self.insertWarning(item, 1, content_hash, seen_at);
    }

    fn latestWarningRevision(self: *Store, source: WarningSource, warning_id: []const u8) !?WarningRevisionRow {
        var statement = try self.db.prepare(
            \\SELECT revision, content_hash FROM weather_warnings
            \\WHERE source = ? AND warning_id = ?
            \\ORDER BY revision DESC LIMIT 1
        );
        defer statement.deinit();
        return statement.one(WarningRevisionRow, .{}, .{ @tagName(source), warning_id });
    }

    fn insertWarning(self: *Store, item: Warning, revision: u32, content_hash: i64, seen_at: []const u8) !void {
        try self.db.exec(
            \\INSERT INTO weather_warnings (
            \\    source, warning_id, revision, content_hash, event, severity,
            \\    probability_percent, office, published_at, effective_from, effective_to,
            \\    content, comment, first_seen_at, last_seen_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ,
            .{},
            .{
                @tagName(item.source),
                item.warning_id,
                revision,
                content_hash,
                item.event,
                item.severity,
                item.probability_percent,
                item.office,
                item.published_at,
                item.effective_from,
                item.effective_to,
                item.content,
                item.comment,
                seen_at,
                seen_at,
            },
        );

        try self.insertWarningAreas(item, revision);
    }

    /// Idempotent so that re-recording a warning also repairs an earlier batch
    /// that was interrupted between its header and its areas.
    fn insertWarningAreas(self: *Store, item: Warning, revision: u32) !void {
        for (item.areas) |area| {
            try self.db.exec(
                \\INSERT OR IGNORE INTO weather_warning_areas (
                \\    source, warning_id, revision, teryt, voivodeship, description, basin_code
                \\) VALUES (?, ?, ?, ?, ?, ?, ?)
            ,
                .{},
                .{
                    @tagName(item.source),
                    item.warning_id,
                    revision,
                    area.teryt orelse "",
                    area.voivodeship orelse "",
                    area.description orelse "",
                    area.basin_code orelse "",
                },
            );
        }
    }

    pub fn activeWarnings(self: *Store, allocator: std.mem.Allocator, filter: WarningFilter) ![]Warning {
        return self.warningsMatching(allocator, filter);
    }

    /// Returns every stored revision, expired ones included, which is the
    /// history view of the warnings.
    pub fn warningHistory(self: *Store, allocator: std.mem.Allocator, filter: WarningFilter) ![]Warning {
        return self.warningsMatching(allocator, filter);
    }

    pub fn warningRevisions(self: *Store, allocator: std.mem.Allocator, source: WarningSource, warning_id: []const u8) ![]Warning {
        return self.warningsMatching(allocator, .{ .source = source, .teryt = null, .effective_to_gte = null, .latest_only = false, .warning_id = warning_id });
    }

    /// Runs the warnings query and its areas query with the same filter and
    /// zips them back together. Both are ordered by
    /// (source, warning_id, revision), so one merge pass is enough.
    fn warningsMatching(self: *Store, allocator: std.mem.Allocator, filter: WarningFilter) ![]Warning {
        var clause: std.ArrayList(u8) = .empty;
        defer clause.deinit(allocator);
        var binds: std.ArrayList(?[]const u8) = .empty;
        defer binds.deinit(allocator);

        // The SELECT constants end without a newline, so the clause opens with one.
        try clause.appendSlice(allocator, "\nWHERE 1 = 1");
        if (filter.warning_id) |value| {
            try clause.appendSlice(allocator, " AND w.warning_id = ?");
            try binds.append(allocator, value);
        }
        if (filter.source) |value| {
            try clause.appendSlice(allocator, " AND w.source = ?");
            try binds.append(allocator, @tagName(value));
        }
        if (filter.effective_to_gte) |value| {
            try clause.appendSlice(allocator, " AND w.effective_to >= ?");
            try binds.append(allocator, value);
        }
        if (filter.teryt) |value| {
            try clause.appendSlice(allocator, " AND EXISTS (SELECT 1 FROM weather_warning_areas t" ++
                " WHERE t.source = w.source AND t.warning_id = w.warning_id" ++
                " AND t.revision = w.revision AND t.teryt = ?)");
            try binds.append(allocator, value);
        }
        if (filter.latest_only) {
            try clause.appendSlice(allocator, " AND w.revision = (SELECT MAX(x.revision) FROM weather_warnings x" ++
                " WHERE x.source = w.source AND x.warning_id = w.warning_id)");
        }

        const warnings_sql = try std.fmt.allocPrint(allocator, warning_select ++ "{s}" ++ warning_order, .{clause.items});
        defer allocator.free(warnings_sql);
        const areas_sql = try std.fmt.allocPrint(allocator, warning_area_select ++ "{s}" ++ warning_area_order, .{clause.items});
        defer allocator.free(areas_sql);

        var items: std.ArrayList(Warning) = .empty;
        errdefer {
            warnings.deinitWarningItems(allocator, items.items);
            items.deinit(allocator);
        }

        var warning_statement = try self.db.prepareDynamic(warnings_sql);
        defer warning_statement.deinit();
        const rows = try warning_statement.all(WarningRow, allocator, .{}, binds.items);
        defer allocator.free(rows);

        for (rows) |row| {
            // `source` is the only column that is converted rather than handed
            // over, so it is released here.
            const source = warningSource(row.source) catch |err| {
                allocator.free(row.source);
                return err;
            };
            allocator.free(row.source);
            try items.append(allocator, .{
                .source = source,
                .warning_id = row.warning_id,
                .revision = @intCast(row.revision),
                .event = row.event,
                .severity = row.severity,
                .probability_percent = row.probability_percent,
                .office = row.office,
                .published_at = row.published_at,
                .effective_from = row.effective_from,
                .effective_to = row.effective_to,
                .content = row.content,
                .comment = row.comment,
                .first_seen_at = row.first_seen_at,
                .last_seen_at = row.last_seen_at,
            });
        }

        var area_statement = try self.db.prepareDynamic(areas_sql);
        defer area_statement.deinit();
        const area_rows = try area_statement.all(AreaRow, allocator, .{}, binds.items);
        defer allocator.free(area_rows);

        var cursor: usize = 0;
        for (items.items) |*item| {
            var areas: std.ArrayList(WarningArea) = .empty;
            errdefer {
                warnings.deinitAreas(allocator, areas.items);
                areas.deinit(allocator);
            }
            while (cursor < area_rows.len and matchesWarning(area_rows[cursor], item.*)) : (cursor += 1) {
                try areas.append(allocator, takeAreaRow(allocator, area_rows[cursor]));
            }
            item.areas = try areas.toOwnedSlice(allocator);
        }
        // Defensive: unmatched area rows would otherwise leak their strings.
        while (cursor < area_rows.len) : (cursor += 1) {
            warnings.deinitArea(allocator, takeAreaRow(allocator, area_rows[cursor]));
        }

        return items.toOwnedSlice(allocator);
    }

    pub fn deinitWarnings(allocator: std.mem.Allocator, items: []Warning) void {
        warnings.deinitWarnings(allocator, items);
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
            \\CREATE TABLE IF NOT EXISTS weather_warnings (
            \\    source TEXT NOT NULL,
            \\    warning_id TEXT NOT NULL,
            \\    revision INTEGER NOT NULL,
            \\    content_hash INTEGER NOT NULL,
            \\    event TEXT NOT NULL,
            \\    severity INTEGER,
            \\    probability_percent INTEGER,
            \\    office TEXT NOT NULL,
            \\    published_at TEXT NOT NULL,
            \\    effective_from TEXT NOT NULL,
            \\    effective_to TEXT NOT NULL,
            \\    content TEXT NOT NULL,
            \\    comment TEXT,
            \\    first_seen_at TEXT NOT NULL,
            \\    last_seen_at TEXT NOT NULL,
            \\    PRIMARY KEY (source, warning_id, revision)
            \\);
            \\CREATE INDEX IF NOT EXISTS weather_warnings_validity ON weather_warnings (effective_to, source);
            \\CREATE TABLE IF NOT EXISTS weather_warning_areas (
            \\    source TEXT NOT NULL,
            \\    warning_id TEXT NOT NULL,
            \\    revision INTEGER NOT NULL,
            \\    teryt TEXT NOT NULL DEFAULT '',
            \\    voivodeship TEXT NOT NULL DEFAULT '',
            \\    description TEXT NOT NULL DEFAULT '',
            \\    basin_code TEXT NOT NULL DEFAULT '',
            \\    PRIMARY KEY (source, warning_id, revision, teryt, voivodeship, description, basin_code)
            \\);
        ,
            .{},
        );
    }
};

fn warningSource(value: []const u8) !WarningSource {
    return WarningSource.fromQuery(value) orelse error.InvalidData;
}

fn matchesWarning(row: AreaRow, item: Warning) bool {
    return std.mem.eql(u8, row.source, @tagName(item.source)) and
        std.mem.eql(u8, row.warning_id, item.warning_id) and
        row.revision == @as(i64, item.revision);
}

/// Turns an areas row into the model type. The key columns are only needed for
/// the merge and are released here; every remaining column is handed over.
fn takeAreaRow(allocator: std.mem.Allocator, row: AreaRow) WarningArea {
    allocator.free(row.source);
    allocator.free(row.warning_id);
    return .{
        .teryt = takeAreaText(allocator, row.teryt),
        .voivodeship = takeAreaText(allocator, row.voivodeship),
        .description = takeAreaText(allocator, row.description),
        .basin_code = takeAreaText(allocator, row.basin_code),
    };
}

/// Area columns are stored as `''` for "not applicable" so that the composite
/// primary key stays meaningful; the API reports them as null again. The
/// reader already allocated the text, so an empty value is released rather
/// than reported as a leak.
fn takeAreaText(allocator: std.mem.Allocator, value: []const u8) ?[]const u8 {
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

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

fn testWarning() Warning {
    return .{
        .source = .meteo,
        .warning_id = "Sk20260916094336328",
        .event = "Intensywne opady deszczu",
        .severity = 1,
        .probability_percent = 80,
        .office = "Centralne Biuro Prognoz Meteorologicznych w Warszawie",
        .published_at = "2026-09-16 11:43:00",
        .effective_from = "2026-09-16 23:00:00",
        .effective_to = "2026-09-17 07:00:00",
        .content = "Prognozowane są opady deszczu.",
        .areas = &.{ .{ .teryt = "2415" }, .{ .teryt = "2467" } },
    };
}

fn testHydroWarning() Warning {
    return .{
        .source = .hydro,
        .warning_id = "Biuro Prognoz Hydrologicznych we Wrocławiu#31#2026-05-17 08:45:07",
        .event = "Susza hydrologiczna",
        .severity = -1,
        .probability_percent = 90,
        .office = "Biuro Prognoz Hydrologicznych we Wrocławiu",
        .published_at = "2026-05-17 08:45:07",
        .effective_from = "2026-05-17 08:45:56",
        .effective_to = "9999-12-31 23:59:59",
        .content = "Niskie przepływy wody.",
        .areas = &.{.{
            .voivodeship = "wielkopolskie",
            .description = "wielkopolskie, Kanał Mosiński",
            .basin_code = "Z_P_WP_1856",
        }},
    };
}

test "records a warning once and only refreshes its last seen time" {
    var store = try Store.initMemory();
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 1), try store.recordWarnings(&.{testWarning()}, "2026-09-16 23:05:00"));
    try std.testing.expectEqual(@as(usize, 1), try store.recordWarnings(&.{testWarning()}, "2026-09-16 23:55:00"));

    const items = try store.warningHistory(std.testing.allocator, .{});
    defer Store.deinitWarnings(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(u32, 1), items[0].revision);
    try std.testing.expectEqualStrings("2026-09-16 23:05:00", items[0].first_seen_at);
    try std.testing.expectEqualStrings("2026-09-16 23:55:00", items[0].last_seen_at);
    try std.testing.expectEqual(@as(usize, 2), items[0].areas.len);
    try std.testing.expectEqualStrings("2467", items[0].areas[1].teryt.?);
}

test "changed warning content becomes a new stored revision" {
    var store = try Store.initMemory();
    defer store.deinit();

    _ = try store.recordWarnings(&.{testWarning()}, "2026-09-16 23:05:00");
    var changed = testWarning();
    changed.content = "Zaktualizowana treść ostrzeżenia.";
    changed.areas = &.{.{ .teryt = "2415" }};
    _ = try store.recordWarnings(&.{changed}, "2026-09-16 23:35:00");

    const history = try store.warningHistory(std.testing.allocator, .{});
    defer Store.deinitWarnings(std.testing.allocator, history);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqual(@as(u32, 1), history[0].revision);
    try std.testing.expectEqual(@as(u32, 2), history[1].revision);
    try std.testing.expectEqualStrings("Zaktualizowana treść ostrzeżenia.", history[1].content);
    try std.testing.expectEqual(@as(usize, 1), history[1].areas.len);

    const active = try store.activeWarnings(std.testing.allocator, .{
        .effective_to_gte = "2026-09-16 23:50:00",
        .latest_only = true,
    });
    defer Store.deinitWarnings(std.testing.allocator, active);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(@as(u32, 2), active[0].revision);
    try std.testing.expectEqualStrings("Sk20260916094336328", active[0].warning_id);
}

test "active warnings expire, filter by TERYT and stay source separated" {
    var store = try Store.initMemory();
    defer store.deinit();

    var without_areas = testWarning();
    without_areas.warning_id = "Sk20260916094339999";
    without_areas.areas = &.{};

    _ = try store.recordWarnings(&.{ testWarning(), without_areas, testHydroWarning() }, "2026-09-16 23:05:00");

    const still_active = try store.activeWarnings(std.testing.allocator, .{
        .effective_to_gte = "2026-09-17 06:00:00",
        .latest_only = true,
    });
    defer Store.deinitWarnings(std.testing.allocator, still_active);
    try std.testing.expectEqual(@as(usize, 3), still_active.len);
    // Warnings are ordered by source first, so find the county-less one by id.
    const area_less = for (still_active, 0..) |item, index| {
        if (std.mem.eql(u8, item.warning_id, "Sk20260916094339999")) break index;
    } else unreachable;
    try std.testing.expectEqual(@as(usize, 0), still_active[area_less].areas.len);
    try std.testing.expectEqual(WarningSource.hydro, still_active[0].source);

    const expired = try store.activeWarnings(std.testing.allocator, .{
        .effective_to_gte = "2026-09-17 08:00:00",
        .latest_only = true,
    });
    defer Store.deinitWarnings(std.testing.allocator, expired);
    try std.testing.expectEqual(@as(usize, 1), expired.len);
    try std.testing.expectEqual(WarningSource.hydro, expired[0].source);

    const county = try store.activeWarnings(std.testing.allocator, .{
        .teryt = "2467",
        .effective_to_gte = "2026-09-17 06:00:00",
        .latest_only = true,
    });
    defer Store.deinitWarnings(std.testing.allocator, county);
    try std.testing.expectEqual(@as(usize, 1), county.len);
    try std.testing.expectEqualStrings("Sk20260916094336328", county[0].warning_id);

    const unknown_county = try store.activeWarnings(std.testing.allocator, .{
        .teryt = "9999",
        .effective_to_gte = "2026-09-17 06:00:00",
        .latest_only = true,
    });
    defer Store.deinitWarnings(std.testing.allocator, unknown_county);
    try std.testing.expectEqual(@as(usize, 0), unknown_county.len);

    const revisions = try store.warningRevisions(std.testing.allocator, .meteo, "Sk20260916094336328");
    defer Store.deinitWarnings(std.testing.allocator, revisions);
    try std.testing.expectEqual(@as(usize, 1), revisions.len);
    try std.testing.expectEqualStrings("Intensywne opady deszczu", revisions[0].event);
    try std.testing.expectEqualStrings("2026-09-16 23:05:00", revisions[0].first_seen_at);

    const hydro = try store.warningHistory(std.testing.allocator, .{ .source = .hydro });
    defer Store.deinitWarnings(std.testing.allocator, hydro);
    try std.testing.expectEqual(@as(usize, 1), hydro.len);
    try std.testing.expectEqualStrings("Z_P_WP_1856", hydro[0].areas[0].basin_code.?);
    try std.testing.expectEqual(@as(?i16, -1), hydro[0].severity);
}
