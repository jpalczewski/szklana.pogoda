const std = @import("std");
const sqlite = @import("sqlite");
const model = @import("model.zig");
const timestamps = @import("../timestamps.zig");
const warnings = @import("../warnings.zig");

/// Warning types are owned by `warnings.zig`; the store only names them in its
/// queries and leaves the public surface to `mod.zig`.
const Warning = warnings.Warning;
const WarningArea = warnings.Area;
const WarningSource = warnings.Source;

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

/// The model columns of `weather_observations`, in table order. `history`
/// selects exactly these, so the decoded row matches `model.Observation`: the
/// sqlite reader assigns columns to struct fields by position.
const observation_column_names = [_][]const u8{
    "station_id",                "station_name",     "observed_at",
    "temperature_c",             "wind_speed_m_s",   "wind_direction_deg",
    "relative_humidity_percent", "precipitation_mm", "pressure_hpa",
    "longitude",                 "latitude",
};

/// The table's columns: the model's plus the product label the row arrived
/// from. `source` trails the list because that is where `ALTER TABLE` appends
/// it on a database written before the label existed. The insert, the
/// placeholders and the upsert assignments derive from this list, so they
/// cannot drift apart.
const observation_table_column_names = blk: {
    // zlinter-disable-next-line no_undefined - every index is written by the loop and the line below before break :blk reads names
    var names: [observation_column_names.len + 1][]const u8 = undefined;
    for (observation_column_names, 0..) |name, index| names[index] = name;
    names[observation_column_names.len] = "source";
    break :blk names;
};
const observation_columns = joinColumns(&observation_table_column_names);
const observation_select_columns = joinColumns(&observation_column_names);
const observation_placeholders = placeholders(observation_table_column_names.len);
const observation_upsert = upsertAssignments(&observation_table_column_names);

/// Classifies the rows written before `weather_observations` recorded its
/// product, which is a one-time rewrite of existing data. IMGW's synoptic
/// network uses five-digit numeric station ids while the meteo network uses
/// nine-digit codes, so the id names the product unambiguously. New rows always
/// carry an explicit label, which makes the `source = ''` guard self-clearing.
const classify_observation_sources = std.fmt.comptimePrint(
    "UPDATE weather_observations SET source = CASE WHEN length(station_id) = 5 THEN '{s}' ELSE '{s}' END WHERE source = ''",
    .{ model.observation_source_labels[0], model.observation_source_labels[1] },
);

/// The columns of `hydro_observations` in table order.
const hydro_column_names = [_][]const u8{
    "station_id",                        "station_name",
    "river",                             "voivodeship",
    "longitude",                         "latitude",
    "founded_year",                      "gauge_zero_m",
    "river_km",                          "warning_level_cm",
    "alarm_level_cm",                    "water_level_cm",
    "water_level_observed_at",           "water_temperature_c",
    "water_temperature_observed_at",     "flow_m3_s",
    "flow_observed_at",                  "ice_phenomenon",
    "ice_phenomenon_observed_at",        "overgrowth_phenomenon",
    "overgrowth_phenomenon_observed_at", "water_level_status",
};
const hydro_columns = joinColumns(&hydro_column_names);
const hydro_placeholders = placeholders(hydro_column_names.len);
const hydro_upsert = upsertAssignments(&hydro_column_names);

/// The hydro columns that hold a timestamp. Hydro is the one product whose
/// parser keeps IMGW's wall-clock form, so a database written before the store
/// boundary converted it has to be rewritten once; see
/// `normalizeHydroTimestamps`.
const hydro_timestamp_columns = [_][]const u8{
    "water_level_observed_at",
    "water_temperature_observed_at",
    "flow_observed_at",
    "ice_phenomenon_observed_at",
    "overgrowth_phenomenon_observed_at",
};

/// Bumped whenever the schema gains a rewrite that existing rows need. The
/// value lives in SQLite's own `user_version`, so no extra table is needed.
const hydro_timestamp_version = 1;

/// Marks the rows a running migration has already shifted. The format is not a
/// timestamp: staying 19 characters long keeps the marker out of the
/// `length(...) = 19` guard that selects the pre-migration rows.
const migration_marker = "'~local-to-utc~'";
const pragma_user_version = "PRAGMA user_version = " ++ std.fmt.comptimePrint("{d}", .{hydro_timestamp_version});

/// The connection's page cache in kibibytes, which is the unit SQLite's
/// `cache_size` takes when the value is negative. Its default of 2 MiB is sized
/// for a database that is read continuously; this store writes one batch every
/// few minutes and reads nothing in between, so the cache is capped instead of
/// reserved for the life of the process.
const page_cache_kib = 512;
const pragma_page_cache = "PRAGMA cache_size = -" ++ std.fmt.comptimePrint("{d}", .{page_cache_kib});

pub const Store = struct {
    db: sqlite.Db,
    /// The wall clock the store reads; only the one-time hydro migration in
    /// `normalizeHydroTimestamps` needs it.
    clock: timestamps.Clock = .fixed(),

    pub fn initFile(allocator: std.mem.Allocator, path: [:0]const u8, clock: timestamps.Clock) !Store {
        var store: Store = .{
            .db = try sqlite.Db.init(.{
                .mode = .{ .File = path },
                .open_flags = .{ .write = true, .create = true },
                .threading_mode = .Serialized,
            }),
            .clock = clock,
        };
        errdefer store.deinit();
        try store.migrate(allocator);
        try store.tune();
        return store;
    }

    pub fn initMemory(allocator: std.mem.Allocator) !Store {
        var store: Store = .{
            .db = try sqlite.Db.init(.{
                .mode = .Memory,
                .open_flags = .{ .write = true, .create = true },
                .threading_mode = .Serialized,
            }),
        };
        errdefer store.deinit();
        try store.migrate(allocator);
        try store.tune();
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.db.deinit();
        self.* = undefined;
    }

    /// The connection settings the store relies on, applied once the schema is
    /// in place.
    fn tune(self: *Store) !void {
        try self.db.exec(pragma_page_cache, .{}, .{});
    }

    /// Hands back the page cache and the other transient memory SQLite holds
    /// for this connection. The updater calls it once a batch is written,
    /// because that is the only moment the cache fills up.
    pub fn releaseMemory(self: *Store) void {
        _ = sqlite.c.sqlite3_db_release_memory(self.db.db);
    }

    /// Reports whether `source` was polled successfully within the last
    /// `max_age_seconds`, so the updater can keep serving what it already
    /// stored instead of downloading the same data again. A source that has
    /// never been polled is never fresh.
    pub fn isFresh(self: *Store, source: []const u8, now_epoch: u64, max_age_seconds: u64) !bool {
        const last_success = try self.lastPollEpoch(source) orelse return false;
        if (last_success < 0) return false;
        // A poll dated in the future still counts as fresh rather than wrapping
        // around, which keeps the comparison below clear of unsigned overflow.
        const success_epoch: u64 = @intCast(last_success);
        if (success_epoch >= now_epoch) return true;
        return now_epoch - success_epoch <= max_age_seconds;
    }

    /// Stamps a successful poll of `source`. The updater calls this after a
    /// batch has been recorded, so only a poll that produced stored data can
    /// make the next one look fresh.
    pub fn recordPoll(self: *Store, source: []const u8, now_epoch: u64) !void {
        try self.db.exec(
            \\INSERT INTO source_state (source, last_success_epoch)
            \\VALUES (?, ?)
            \\ON CONFLICT (source) DO UPDATE SET
            \\    last_success_epoch = excluded.last_success_epoch
        ,
            .{},
            .{ source, now_epoch },
        );
    }

    /// The epoch of the last successful poll of `source`, or null when the
    /// source has never been polled.
    fn lastPollEpoch(self: *Store, source: []const u8) !?i64 {
        var statement = try self.db.prepare(
            "SELECT last_success_epoch FROM source_state WHERE source = ?",
        );
        defer statement.deinit();
        return statement.one(i64, .{}, .{source});
    }

    /// Writes one measurement under the product that produced it. `source` is
    /// one of `model.observation_source_labels`; it stays a stored label rather
    /// than a field of the observation, which remains product agnostic.
    pub fn record(self: *Store, source: []const u8, observation: model.Observation) !void {
        try self.db.exec(
            "INSERT INTO weather_observations (" ++ observation_columns ++ ")\n" ++
                "VALUES (" ++ observation_placeholders ++ ")\n" ++
                "ON CONFLICT (station_id, observed_at) DO UPDATE SET " ++ observation_upsert,
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
                .longitude = observation.longitude,
                .latitude = observation.latitude,
                .source = source,
            },
        );
    }

    pub fn history(self: *Store, allocator: std.mem.Allocator, station_id: []const u8, since: []const u8) ![]model.Observation {
        var statement = try self.db.prepare(
            "SELECT " ++ observation_select_columns ++ "\n" ++
                "FROM weather_observations\n" ++
                "WHERE station_id = ? AND observed_at >= ?\n" ++
                "ORDER BY observed_at ASC",
        );
        defer statement.deinit();
        return statement.all(model.Observation, allocator, .{}, .{ .station_id = station_id, .since = since });
    }

    /// The newest reading per station, optionally narrowed to one measurement
    /// product. `source` is a label from `model.observation_source_labels`.
    ///
    /// The coordinates are aggregated rather than read from the newest row:
    /// `MAX` skips nulls, so a station reports the position as soon as one of
    /// its stored readings carried one, even though rows written before the
    /// table held coordinates stay null. A station's position does not change,
    /// so which reading carried it does not matter.
    pub fn stations(self: *Store, allocator: std.mem.Allocator, source: ?[]const u8) ![]model.Station {
        const select =
            \\SELECT station_id, station_name, MAX(observed_at), MAX(longitude), MAX(latitude)
            \\FROM weather_observations
        ;
        const group =
            \\ GROUP BY station_id, station_name
            \\ ORDER BY station_name COLLATE NOCASE ASC
        ;
        if (source) |label| {
            // The select constant ends without a newline, so the clause opens with one.
            const sql = try std.fmt.allocPrint(allocator, select ++ "\nWHERE source = ?" ++ group, .{});
            defer allocator.free(sql);
            var statement = try self.db.prepareDynamic(sql);
            defer statement.deinit();
            return statement.all(model.Station, allocator, .{}, .{label});
        }
        var statement = try self.db.prepare(select ++ group);
        defer statement.deinit();
        return statement.all(model.Station, allocator, .{}, .{});
    }

    pub fn recordHydro(self: *Store, item: model.HydroObservation) !void {
        try self.db.exec("INSERT INTO hydro_observations (" ++ hydro_columns ++ ")\n" ++
            "VALUES (" ++ hydro_placeholders ++ ")\n" ++
            "ON CONFLICT (station_id, water_level_observed_at) DO UPDATE SET " ++ hydro_upsert, .{}, .{ .station_id = item.station_id, .station_name = item.station_name, .river = item.river, .voivodeship = item.voivodeship, .longitude = item.longitude, .latitude = item.latitude, .founded_year = item.founded_year, .gauge_zero_m = item.gauge_zero_m, .river_km = item.river_km, .warning_level_cm = item.warning_level_cm, .alarm_level_cm = item.alarm_level_cm, .water_level_cm = item.water_level_cm, .water_level_observed_at = item.water_level_observed_at, .water_temperature_c = item.water_temperature_c, .water_temperature_observed_at = item.water_temperature_observed_at, .flow_m3_s = item.flow_m3_s, .flow_observed_at = item.flow_observed_at, .ice_phenomenon = item.ice_phenomenon, .ice_phenomenon_observed_at = item.ice_phenomenon_observed_at, .overgrowth_phenomenon = item.overgrowth_phenomenon, .overgrowth_phenomenon_observed_at = item.overgrowth_phenomenon_observed_at, .water_level_status = item.water_level_status });
    }

    pub fn hydroStations(self: *Store, allocator: std.mem.Allocator) ![]model.HydroStation {
        var statement = try self.db.prepare(
            "SELECT " ++ hydro_columns ++ "\n" ++
                "FROM hydro_observations\n" ++
                "WHERE water_level_observed_at = (SELECT MAX(h.water_level_observed_at) FROM hydro_observations h WHERE h.station_id = hydro_observations.station_id)",
        );
        defer statement.deinit();
        return statement.all(model.HydroStation, allocator, .{}, .{});
    }

    pub fn hydroHistory(self: *Store, allocator: std.mem.Allocator, station_id: []const u8, since: []const u8) ![]model.HydroObservation {
        var statement = try self.db.prepare(
            "SELECT " ++ hydro_columns ++ "\n" ++
                "FROM hydro_observations WHERE station_id = ? AND water_level_observed_at >= ? ORDER BY water_level_observed_at ASC",
        );
        defer statement.deinit();
        return statement.all(model.HydroObservation, allocator, .{}, .{ .station_id = station_id, .since = since });
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

    /// Creates the schema and brings a database written by an older build up to
    /// date. The hydro table gained `normalized_at` when every timestamp it
    /// stores moved to the UTC form the other products already used, so
    /// `user_version` tracks which rewrites have already run. The observation
    /// table gained `source` later; its rewrite is guarded by the column itself
    /// and the self-clearing `source = ''` marker. It gained the two coordinate
    /// columns last, which need no rewrite at all: rows written before them stay
    /// null until the next poll of a product that publishes a position.
    fn migrate(self: *Store, allocator: std.mem.Allocator) !void {
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
            \\    longitude REAL,
            \\    latitude REAL,
            \\    source TEXT NOT NULL DEFAULT '',
            \\    PRIMARY KEY (station_id, observed_at)
            \\);
            \\CREATE INDEX IF NOT EXISTS weather_observations_station_time
            \\    ON weather_observations (station_id, observed_at);
            \\CREATE TABLE IF NOT EXISTS hydro_observations (station_id TEXT NOT NULL, station_name TEXT NOT NULL, river TEXT NOT NULL, voivodeship TEXT NOT NULL, longitude REAL, latitude REAL, founded_year INTEGER, gauge_zero_m REAL, river_km REAL, warning_level_cm REAL, alarm_level_cm REAL, water_level_cm REAL, water_level_observed_at TEXT NOT NULL, water_temperature_c REAL, water_temperature_observed_at TEXT, flow_m3_s REAL, flow_observed_at TEXT, ice_phenomenon INTEGER, ice_phenomenon_observed_at TEXT, overgrowth_phenomenon INTEGER, overgrowth_phenomenon_observed_at TEXT, water_level_status TEXT NOT NULL, normalized_at TEXT, PRIMARY KEY (station_id, water_level_observed_at));
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
            \\CREATE TABLE IF NOT EXISTS source_state (
            \\    source TEXT NOT NULL PRIMARY KEY,
            \\    last_success_epoch INTEGER NOT NULL
            \\);
        ,
            .{},
        );
        try self.normalizeHydroTimestamps(allocator);
        try self.classifyObservationSources();
        try self.addObservationCoordinates();
    }

    /// Gives a database written before the stations published their position the
    /// two coordinate columns. Nothing is backfilled: only the meteo product
    /// publishes a position, and its next poll writes it. The `hasColumn` guard
    /// keeps a second run harmless without `user_version` bookkeeping.
    fn addObservationCoordinates(self: *Store) !void {
        inline for (.{ "longitude", "latitude" }) |column| {
            if (!try hasColumn(&self.db, "weather_observations", column)) {
                const sql = comptime "ALTER TABLE weather_observations ADD COLUMN " ++ column ++ " REAL";
                try self.db.exec(sql, .{}, .{});
            }
        }
    }

    /// Gives a database written before `weather_observations` recorded its
    /// product the `source` column, then labels its legacy rows once. Every new
    /// row arrives with an explicit label, so the `source = ''` guard empties
    /// itself and a second run is a no-op; unlike the hydro rewrite this needs
    /// no `user_version` bookkeeping.
    fn classifyObservationSources(self: *Store) !void {
        if (!try hasColumn(&self.db, "weather_observations", "source")) {
            try self.db.exec("ALTER TABLE weather_observations ADD COLUMN source TEXT NOT NULL DEFAULT ''", .{}, .{});
        }
        // The index is created here rather than beside the table because a
        // database written before the label existed only gains the column just
        // above, and an index cannot name a column the table does not have yet.
        try self.db.exec("CREATE INDEX IF NOT EXISTS weather_observations_source ON weather_observations (source)", .{}, .{});
        try self.db.exec(classify_observation_sources, .{}, .{});
    }

    /// Rewrites hydro timestamps stored before hydro adopted the UTC form. The
    /// `"YYYY-MM-DD HH:MM:SS"` values are Europe/Warsaw wall clock, so the
    /// Warsaw offset of each reading is added to it. The offset comes from
    /// `timestamps`, so the rewrite and the parser cannot apply different rules,
    /// and the rows are published through the regular insert because a shifted
    /// timestamp can land on another row's primary key.
    ///
    /// Timestamps already written as `"YYYY-MM-DDTHH:MM:SSZ"` are recognisable
    /// by their length, which also keeps a second run harmless; `user_version`
    /// guards that on top.
    fn normalizeHydroTimestamps(self: *Store, allocator: std.mem.Allocator) !void {
        const version = (try self.db.pragma(i64, .{}, "user_version", null)) orelse 0;
        if (version >= hydro_timestamp_version) return;

        if (!try hasColumn(&self.db, "hydro_observations", "normalized_at")) {
            try self.db.exec("ALTER TABLE hydro_observations ADD COLUMN normalized_at TEXT", .{}, .{});
        }

        // Every timestamp column holds the same wall-clock form, so one
        // conversion per distinct reading serves all five of them.
        try self.db.exec(
            "CREATE TEMP TABLE IF NOT EXISTS hydro_timestamp_shift (local TEXT NOT NULL PRIMARY KEY, utc TEXT NOT NULL)",
            .{},
            .{},
        );
        try self.db.exec("DELETE FROM hydro_timestamp_shift", .{}, .{});

        var statement = try self.db.prepare(
            "SELECT DISTINCT trim(water_level_observed_at) FROM hydro_observations WHERE length(trim(water_level_observed_at)) = 19",
        );
        defer statement.deinit();
        var rows = try statement.iteratorAlloc([]const u8, allocator, .{});
        while (try rows.nextAlloc(allocator, .{})) |local| {
            defer allocator.free(local);
            const utc_text = try shiftedTimestamp(&self.clock, allocator, local);
            defer allocator.free(utc_text);
            try self.db.exec(
                "INSERT OR REPLACE INTO hydro_timestamp_shift (local, utc) VALUES (?, ?)",
                .{},
                .{ local, utc_text },
            );
        }

        inline for (hydro_timestamp_columns) |column| {
            const shift = comptime "UPDATE hydro_observations SET " ++ column ++
                " = (SELECT utc FROM hydro_timestamp_shift WHERE local = " ++ column ++ "), normalized_at = " ++ migration_marker ++
                " WHERE length(" ++ column ++ ") = 19";
            try self.db.exec(shift, .{}, .{});
        }
        const publish = "INSERT OR REPLACE INTO hydro_observations (" ++ hydro_columns ++ ")\n" ++
            "SELECT " ++ hydro_columns ++ " FROM hydro_observations WHERE normalized_at = " ++ migration_marker;
        try self.db.exec(publish, .{}, .{});
        try self.db.exec("DELETE FROM hydro_observations WHERE normalized_at IS NOT NULL AND normalized_at <> " ++ migration_marker, .{}, .{});
        try self.db.exec("UPDATE hydro_observations SET normalized_at = NULL WHERE normalized_at = " ++ migration_marker, .{}, .{});
        try self.db.exec(pragma_user_version, .{}, .{});
    }
};

fn warningSource(value: []const u8) !WarningSource {
    return WarningSource.fromQuery(value) orelse error.InvalidData;
}

/// Reports whether `table` already carries `column`, so a migration does not
/// try to add it twice. The identifiers are compile-time constants, which is
/// what lets the pragma be built as a comptime query.
fn hasColumn(db: *sqlite.Db, comptime table: []const u8, comptime column: []const u8) !bool {
    const sql = comptime std.fmt.comptimePrint(
        "SELECT COUNT(*) FROM pragma_table_info('{s}') WHERE name = '{s}'",
        .{ table, column },
    );
    const present = (try db.one(i64, sql, .{}, .{})) orelse 0;
    return present > 0;
}

/// Rewrites one IMGW wall-clock reading into the UTC-suffixed form the store
/// keeps. The instant is the reading less its Warsaw offset; the offset is
/// derived two hours back so a reading inside a fall-back night still lands on
/// the offset that was in force when it was taken.
fn shiftedTimestamp(clock: *const timestamps.Clock, allocator: std.mem.Allocator, local: []const u8) ![]u8 {
    return clock.utcText(allocator, try clock.resolveInstant(local));
}

/// Comma-joins column names for an insert or select list. Every caller needs
/// the result as a compile-time SQL constant, so these builders are comptime
/// only.
fn joinColumns(comptime names: []const []const u8) []const u8 {
    var text: []const u8 = "";
    for (names, 0..) |name, index| {
        if (index != 0) text = text ++ ", ";
        text = text ++ name;
    }
    return text;
}

fn placeholders(comptime count: usize) []const u8 {
    var text: []const u8 = "";
    for (0..count) |index| {
        if (index != 0) text = text ++ ", ";
        text = text ++ "?";
    }
    return text;
}

/// Builds the `column = excluded.column` assignments of an upsert from the same
/// column list the insert uses.
fn upsertAssignments(comptime names: []const []const u8) []const u8 {
    var text: []const u8 = "";
    for (names, 0..) |name, index| {
        if (index != 0) text = text ++ ", ";
        text = text ++ name ++ " = excluded." ++ name;
    }
    return text;
}

/// Container-level so the comptime builders can see the names.
const join_fixture = [_][]const u8{ "a", "b" };
const upsert_fixture = [_][]const u8{ "a", "b" };

test "column lists are derived from one source" {
    try std.testing.expectEqualStrings("a, b", comptime joinColumns(&join_fixture));
    try std.testing.expectEqualStrings("?, ?, ?", comptime placeholders(3));
    try std.testing.expectEqualStrings("a = excluded.a, b = excluded.b", comptime upsertAssignments(&upsert_fixture));
    // The placeholder count has to follow the column list, or an insert binds
    // the wrong number of values.
    try std.testing.expectEqual(hydro_column_names.len, std.mem.count(u8, hydro_placeholders, "?"));
    try std.testing.expectEqual(observation_table_column_names.len, std.mem.count(u8, observation_placeholders, "?"));
    // The history select has to match `model.Observation`, so it cannot carry
    // the stored product label the insert does.
    try std.testing.expectEqualStrings(observation_select_columns, comptime joinColumns(&observation_column_names));
    try std.testing.expect(std.mem.find(u8, observation_columns, "source") != null);
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
    var store = try Store.initMemory(std.testing.allocator);
    defer store.deinit();

    try store.record("synop", .{
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
    try store.record("synop", .{
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
    defer model.deinitObservations(std.testing.allocator, observations);

    try std.testing.expectEqual(@as(usize, 1), observations.len);
    try std.testing.expectEqualStrings("Wrocław", observations[0].station_name);
    try std.testing.expectApproxEqAbs(@as(f64, 18.5), observations[0].temperature_c.?, 0.001);
    // A synoptic reading carries no position, so both fields stay null.
    try std.testing.expect(observations[0].longitude == null);
    try std.testing.expect(observations[0].latitude == null);
}

test "stations are listed per measurement product" {
    var store = try Store.initMemory(std.testing.allocator);
    defer store.deinit();

    const synoptic: model.Observation = .{
        .station_id = "12424",
        .station_name = "Wrocław",
        .observed_at = "2026-09-16T17:00:00Z",
        .temperature_c = 18.5,
        .wind_speed_m_s = null,
        .wind_direction_deg = null,
        .relative_humidity_percent = null,
        .precipitation_mm = null,
        .pressure_hpa = 1012.4,
    };
    var meteorological = synoptic;
    meteorological.station_id = "249180010";
    meteorological.station_name = "PSZCZYNA";
    meteorological.longitude = 18.9306;
    meteorological.latitude = 49.9342;

    try store.record("synop", synoptic);
    try store.record("meteo", meteorological);

    const all = try store.stations(std.testing.allocator, null);
    defer model.deinitStations(std.testing.allocator, all);
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const synoptic_only = try store.stations(std.testing.allocator, "synop");
    defer model.deinitStations(std.testing.allocator, synoptic_only);
    try std.testing.expectEqual(@as(usize, 1), synoptic_only.len);
    try std.testing.expectEqualStrings("12424", synoptic_only[0].station_id);
    // The synoptic product publishes no position.
    try std.testing.expect(synoptic_only[0].longitude == null);
    try std.testing.expect(synoptic_only[0].latitude == null);

    const meteo_only = try store.stations(std.testing.allocator, "meteo");
    defer model.deinitStations(std.testing.allocator, meteo_only);
    try std.testing.expectEqual(@as(usize, 1), meteo_only.len);
    try std.testing.expectEqualStrings("249180010", meteo_only[0].station_id);
    try std.testing.expectApproxEqAbs(@as(f64, 18.9306), meteo_only[0].longitude.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 49.9342), meteo_only[0].latitude.?, 0.0001);

    const unknown = try store.stations(std.testing.allocator, "hydro");
    defer model.deinitStations(std.testing.allocator, unknown);
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
}

test "a station reports the position any of its readings carried" {
    var store = try Store.initMemory(std.testing.allocator);
    defer store.deinit();

    // A reading written before the table held coordinates, and a newer one that
    // carries them: the listing has to report the station's position, not the
    // null of its newest row.
    try store.record("meteo", .{
        .station_id = "249180010",
        .station_name = "PSZCZYNA",
        .observed_at = "2026-09-16T17:00:00Z",
        .temperature_c = 17.5,
        .wind_speed_m_s = null,
        .wind_direction_deg = null,
        .relative_humidity_percent = null,
        .precipitation_mm = null,
        .pressure_hpa = null,
    });
    try store.record("meteo", .{
        .station_id = "249180010",
        .station_name = "PSZCZYNA",
        .observed_at = "2026-09-16T17:10:00Z",
        .temperature_c = 17.8,
        .wind_speed_m_s = null,
        .wind_direction_deg = null,
        .relative_humidity_percent = null,
        .precipitation_mm = null,
        .pressure_hpa = null,
        .longitude = 18.9306,
        .latitude = 49.9342,
    });

    const stations = try store.stations(std.testing.allocator, "meteo");
    defer model.deinitStations(std.testing.allocator, stations);
    try std.testing.expectEqual(@as(usize, 1), stations.len);
    try std.testing.expectEqualStrings("2026-09-16T17:10:00Z", stations[0].last_observed_at);
    try std.testing.expectApproxEqAbs(@as(f64, 18.9306), stations[0].longitude.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 49.9342), stations[0].latitude.?, 0.0001);
}

test "a source is fresh only until its recorded poll ages out" {
    var store = try Store.initMemory(std.testing.allocator);
    defer store.deinit();

    // Nothing was polled yet, so even a brand new process has to fetch.
    try std.testing.expect(!try store.isFresh("synop", 1_000, 600));

    try store.recordPoll("synop", 1_000);
    try std.testing.expect(try store.isFresh("synop", 1_000, 600));
    try std.testing.expect(try store.isFresh("synop", 1_600, 600));
    // Exactly at the limit the data is still considered fresh, and one second
    // later it is not.
    try std.testing.expect(!try store.isFresh("synop", 1_601, 600));

    // Sources are tracked independently, so a fresh synop does not hide a
    // stale meteo.
    try std.testing.expect(!try store.isFresh("meteo", 1_600, 600));
    try store.recordPoll("meteo", 1_200);
    try std.testing.expect(try store.isFresh("meteo", 1_600, 600));
    try store.recordPoll("synop", 1_600);
    try std.testing.expect(try store.isFresh("synop", 1_600, 600));
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
    var store = try Store.initMemory(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 1), try store.recordWarnings(&.{testWarning()}, "2026-09-16 23:05:00"));
    try std.testing.expectEqual(@as(usize, 1), try store.recordWarnings(&.{testWarning()}, "2026-09-16 23:55:00"));

    const items = try store.warningHistory(std.testing.allocator, .{});
    defer warnings.deinitWarnings(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(u32, 1), items[0].revision);
    try std.testing.expectEqualStrings("2026-09-16 23:05:00", items[0].first_seen_at);
    try std.testing.expectEqualStrings("2026-09-16 23:55:00", items[0].last_seen_at);
    try std.testing.expectEqual(@as(usize, 2), items[0].areas.len);
    try std.testing.expectEqualStrings("2467", items[0].areas[1].teryt.?);
}

test "changed warning content becomes a new stored revision" {
    var store = try Store.initMemory(std.testing.allocator);
    defer store.deinit();

    _ = try store.recordWarnings(&.{testWarning()}, "2026-09-16 23:05:00");
    var changed = testWarning();
    changed.content = "Zaktualizowana treść ostrzeżenia.";
    changed.areas = &.{.{ .teryt = "2415" }};
    _ = try store.recordWarnings(&.{changed}, "2026-09-16 23:35:00");

    const history = try store.warningHistory(std.testing.allocator, .{});
    defer warnings.deinitWarnings(std.testing.allocator, history);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqual(@as(u32, 1), history[0].revision);
    try std.testing.expectEqual(@as(u32, 2), history[1].revision);
    try std.testing.expectEqualStrings("Zaktualizowana treść ostrzeżenia.", history[1].content);
    try std.testing.expectEqual(@as(usize, 1), history[1].areas.len);

    const active = try store.activeWarnings(std.testing.allocator, .{
        .effective_to_gte = "2026-09-16 23:50:00",
        .latest_only = true,
    });
    defer warnings.deinitWarnings(std.testing.allocator, active);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(@as(u32, 2), active[0].revision);
    try std.testing.expectEqualStrings("Sk20260916094336328", active[0].warning_id);
}

test "active warnings expire, filter by TERYT and stay source separated" {
    var store = try Store.initMemory(std.testing.allocator);
    defer store.deinit();

    var without_areas = testWarning();
    without_areas.warning_id = "Sk20260916094339999";
    without_areas.areas = &.{};

    _ = try store.recordWarnings(&.{ testWarning(), without_areas, testHydroWarning() }, "2026-09-16 23:05:00");

    const still_active = try store.activeWarnings(std.testing.allocator, .{
        .effective_to_gte = "2026-09-17 06:00:00",
        .latest_only = true,
    });
    defer warnings.deinitWarnings(std.testing.allocator, still_active);
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
    defer warnings.deinitWarnings(std.testing.allocator, expired);
    try std.testing.expectEqual(@as(usize, 1), expired.len);
    try std.testing.expectEqual(WarningSource.hydro, expired[0].source);

    const county = try store.activeWarnings(std.testing.allocator, .{
        .teryt = "2467",
        .effective_to_gte = "2026-09-17 06:00:00",
        .latest_only = true,
    });
    defer warnings.deinitWarnings(std.testing.allocator, county);
    try std.testing.expectEqual(@as(usize, 1), county.len);
    try std.testing.expectEqualStrings("Sk20260916094336328", county[0].warning_id);

    const unknown_county = try store.activeWarnings(std.testing.allocator, .{
        .teryt = "9999",
        .effective_to_gte = "2026-09-17 06:00:00",
        .latest_only = true,
    });
    defer warnings.deinitWarnings(std.testing.allocator, unknown_county);
    try std.testing.expectEqual(@as(usize, 0), unknown_county.len);

    const revisions = try store.warningRevisions(std.testing.allocator, .meteo, "Sk20260916094336328");
    defer warnings.deinitWarnings(std.testing.allocator, revisions);
    try std.testing.expectEqual(@as(usize, 1), revisions.len);
    try std.testing.expectEqualStrings("Intensywne opady deszczu", revisions[0].event);
    try std.testing.expectEqualStrings("2026-09-16 23:05:00", revisions[0].first_seen_at);

    const hydro = try store.warningHistory(std.testing.allocator, .{ .source = .hydro });
    defer warnings.deinitWarnings(std.testing.allocator, hydro);
    try std.testing.expectEqual(@as(usize, 1), hydro.len);
    try std.testing.expectEqualStrings("Z_P_WP_1856", hydro[0].areas[0].basin_code.?);
    try std.testing.expectEqual(@as(?i16, -1), hydro[0].severity);
}

fn testHydroObservation() model.HydroObservation {
    return .{
        .station_id = "151140030",
        .station_name = "Przewoźniki",
        .river = "Skroda",
        .voivodeship = "lubuskie",
        .longitude = 14.8217,
        .latitude = 51.5253,
        .founded_year = 1954,
        .gauge_zero_m = 100.5,
        .river_km = 12.3,
        .warning_level_cm = 300,
        .alarm_level_cm = 340,
        .water_level_cm = 310,
        .water_level_observed_at = "2026-09-16T05:50:00Z",
        .water_temperature_c = 12.5,
        .water_temperature_observed_at = "2026-09-16T05:50:00Z",
        .flow_m3_s = 0.11,
        .flow_observed_at = "2026-09-16T05:50:00Z",
        .ice_phenomenon = null,
        .ice_phenomenon_observed_at = null,
        .overgrowth_phenomenon = null,
        .overgrowth_phenomenon_observed_at = null,
        .water_level_status = "warning",
    };
}

test "stores gauge readings and returns the latest one plus their history" {
    var store = try Store.initMemory(std.testing.allocator);
    defer store.deinit();

    try store.recordHydro(testHydroObservation());

    var newer = testHydroObservation();
    newer.water_level_observed_at = "2026-09-16T06:50:00Z";
    newer.water_level_cm = 320;
    try store.recordHydro(newer);

    const stations = try store.hydroStations(std.testing.allocator);
    defer model.deinitHydro(std.testing.allocator, stations);
    try std.testing.expectEqual(@as(usize, 1), stations.len);
    try std.testing.expectEqualStrings("2026-09-16T06:50:00Z", stations[0].water_level_observed_at.?);
    try std.testing.expectApproxEqAbs(@as(f64, 320), stations[0].water_level_cm.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.11), stations[0].flow_m3_s.?, 0.001);
    try std.testing.expectEqualStrings("Skroda", stations[0].river);

    const history = try store.hydroHistory(std.testing.allocator, "151140030", "2026-09-16T00:00:00Z");
    defer model.deinitHydro(std.testing.allocator, history);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("2026-09-16T05:50:00Z", history[0].water_level_observed_at.?);

    // Re-recording the same reading updates it in place instead of adding a row.
    try store.recordHydro(testHydroObservation());
    const unchanged = try store.hydroHistory(std.testing.allocator, "151140030", "2026-09-16T00:00:00Z");
    defer model.deinitHydro(std.testing.allocator, unchanged);
    try std.testing.expectEqual(@as(usize, 2), unchanged.len);
    try std.testing.expectApproxEqAbs(@as(f64, 310), unchanged[0].water_level_cm.?, 0.001);
}

test "a legacy hydro timestamp is rewritten from Warsaw wall clock to UTC" {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/szklana-pogoda-migration-{d}.db", .{std.os.linux.getpid()}, 0);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer cwd.deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("failed to clean up test database {s}: {t}", .{ path, err }),
    };
    // A database as the previous build left it: the hydro table without the
    // marker column, a row holding a Warsaw wall-clock timestamp, and a
    // user_version that still asks for the rewrite.
    {
        var legacy = try sqlite.Db.init(.{
            .mode = .{ .File = path },
            .open_flags = .{ .write = true, .create = true },
            .threading_mode = .Serialized,
        });
        defer legacy.deinit();
        try legacy.exec("CREATE TABLE hydro_observations (station_id TEXT NOT NULL, station_name TEXT NOT NULL, river TEXT NOT NULL, voivodeship TEXT NOT NULL, longitude REAL, latitude REAL, founded_year INTEGER, gauge_zero_m REAL, river_km REAL, warning_level_cm REAL, alarm_level_cm REAL, water_level_cm REAL, water_level_observed_at TEXT NOT NULL, water_temperature_c REAL, water_temperature_observed_at TEXT, flow_m3_s REAL, flow_observed_at TEXT, ice_phenomenon INTEGER, ice_phenomenon_observed_at TEXT, overgrowth_phenomenon INTEGER, overgrowth_phenomenon_observed_at TEXT, water_level_status TEXT NOT NULL, PRIMARY KEY (station_id, water_level_observed_at))", .{}, .{});
        try legacy.exec("INSERT INTO hydro_observations VALUES ('151140030', 'Przewoźniki', 'Skroda', 'lubuskie', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 310, '2026-09-16 07:50:00', NULL, '2026-09-16 07:50:00', NULL, '2026-09-16 07:50:00', NULL, '2026-09-16 07:50:00', NULL, '2026-09-16 07:50:00', 'warning')", .{}, .{});
        try legacy.exec("PRAGMA user_version = 0", .{}, .{});
    }

    var store = try Store.initFile(std.testing.allocator, path, .fixed());
    defer store.deinit();

    var rows = try store.db.prepare("SELECT water_level_observed_at, flow_observed_at, overgrowth_phenomenon_observed_at, normalized_at FROM hydro_observations");
    defer rows.deinit();
    const row = (try rows.oneAlloc(struct {
        water_level_observed_at: []const u8,
        flow_observed_at: []const u8,
        overgrowth_phenomenon_observed_at: []const u8,
        normalized_at: ?[]const u8,
    }, std.testing.allocator, .{}, .{})).?;
    defer std.testing.allocator.free(row.water_level_observed_at);
    defer std.testing.allocator.free(row.flow_observed_at);
    defer std.testing.allocator.free(row.overgrowth_phenomenon_observed_at);
    defer if (row.normalized_at) |marker| std.testing.allocator.free(marker);

    // 07:50 in Warsaw summer time is 05:50 UTC, and the marker is cleared so
    // the regular queries never see it.
    try std.testing.expectEqualStrings("2026-09-16T05:50:00Z", row.water_level_observed_at);
    try std.testing.expectEqualStrings("2026-09-16T05:50:00Z", row.flow_observed_at);
    try std.testing.expectEqualStrings("2026-09-16T05:50:00Z", row.overgrowth_phenomenon_observed_at);
    try std.testing.expect(row.normalized_at == null);
    try std.testing.expectEqual(hydro_timestamp_version, (try store.db.pragma(i64, .{}, "user_version", null)).?);

    // Re-running is a no-op, so the timestamps are not shifted twice.
    try store.migrate(std.testing.allocator);
    var again = try store.db.prepare("SELECT water_level_observed_at FROM hydro_observations");
    defer again.deinit();
    const unchanged = (try again.oneAlloc([]const u8, std.testing.allocator, .{}, .{})).?;
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("2026-09-16T05:50:00Z", unchanged);
}

test "a legacy observation row is labelled with its measurement product" {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/szklana-pogoda-source-{d}.db", .{std.os.linux.getpid()}, 0);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer cwd.deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("failed to clean up test database {s}: {t}", .{ path, err }),
    };
    // A database as the previous build left it: the observation table without
    // the product label and without the coordinate columns, holding one
    // synoptic (five-digit) and one meteo (nine-digit) station.
    {
        var legacy = try sqlite.Db.init(.{
            .mode = .{ .File = path },
            .open_flags = .{ .write = true, .create = true },
            .threading_mode = .Serialized,
        });
        defer legacy.deinit();
        try legacy.exec("CREATE TABLE weather_observations (station_id TEXT NOT NULL, station_name TEXT NOT NULL, observed_at TEXT NOT NULL, temperature_c REAL, wind_speed_m_s REAL, wind_direction_deg INTEGER, relative_humidity_percent REAL, precipitation_mm REAL, pressure_hpa REAL, PRIMARY KEY (station_id, observed_at))", .{}, .{});
        try legacy.exec("INSERT INTO weather_observations VALUES ('12424', 'Wrocław', '2026-09-16T17:00:00Z', 18.5, NULL, NULL, NULL, NULL, 1012.4)", .{}, .{});
        try legacy.exec("INSERT INTO weather_observations VALUES ('249180010', 'PSZCZYNA', '2026-09-16T17:10:00Z', 17.5, NULL, NULL, NULL, NULL, NULL)", .{}, .{});
    }

    var store = try Store.initFile(std.testing.allocator, path, .fixed());
    defer store.deinit();

    const synoptic = try store.stations(std.testing.allocator, "synop");
    defer model.deinitStations(std.testing.allocator, synoptic);
    try std.testing.expectEqual(@as(usize, 1), synoptic.len);
    try std.testing.expectEqualStrings("12424", synoptic[0].station_id);

    const meteo = try store.stations(std.testing.allocator, "meteo");
    defer model.deinitStations(std.testing.allocator, meteo);
    try std.testing.expectEqual(@as(usize, 1), meteo.len);
    try std.testing.expectEqualStrings("249180010", meteo[0].station_id);
    // The coordinate columns arrived empty: only a new poll can fill them.
    try std.testing.expect(meteo[0].longitude == null);
    try std.testing.expect(meteo[0].latitude == null);

    // The `source = ''` guard clears itself, so a second run keeps the labels.
    try store.migrate(std.testing.allocator);
    const again = try store.stations(std.testing.allocator, "synop");
    defer model.deinitStations(std.testing.allocator, again);
    try std.testing.expectEqual(@as(usize, 1), again.len);
}
