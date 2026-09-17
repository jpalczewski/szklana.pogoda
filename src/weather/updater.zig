const std = @import("std");
const Io = std.Io;

const imgw = @import("../imgw/mod.zig");
const model = @import("model.zig");
const storage = @import("store.zig");
const warnings = @import("../warnings.zig");
const timestamps = @import("../timestamps.zig");

/// How long a successful poll keeps its product fresh, measured per source.
/// Inside that window nothing is downloaded again: IMGW publishes measurements
/// on its own cadence, so within one interval of that cadence the stored rows
/// are as good as a response that just arrived. The updater stamps
/// `source_state` on every successful poll, so once the window passes the next
/// poll downloads again.
///
/// The windows are shorter than the publication cadence on purpose. The
/// polling interval decides how often `run` contacts IMGW; the window only
/// stops a restart or an overlapping poll from repeating a request whose
/// answer is already stored.
const freshness = struct {
    /// Synoptic measurements are published once an hour.
    const synop_seconds: u64 = 10 * 60;
    /// Meteo measurements are published every ten minutes.
    const meteo_seconds: u64 = 5 * 60;
    /// Hydrological levels and flows are published every ten to thirty minutes.
    const hydro_seconds: u64 = 5 * 60;
};

/// What one poll pass hands to a source: the store being written, the product
/// label used in the log lines, the wall-clock reading the warning sources
/// stamp their rows with and the epoch that dates a successful poll.
const Context = struct {
    store: *storage.Store,
    label: []const u8,
    seen_at: []const u8 = "",
    now_seconds: u64 = 0,
};

/// One IMGW product wired for polling: how to fetch a batch, how to release it,
/// how to rewrite its timestamps into the store's form, how to write it and how
/// long a poll of it stays fresh. Adding a product means adding one entry to a
/// table below, not another copy of the update loop.
fn Source(comptime Item: type) type {
    return struct {
        label: []const u8,
        fetch: *const fn (std.mem.Allocator, Io) imgw.Error![]Item,
        deinit: *const fn (std.mem.Allocator, []Item) void,
        record: *const fn ([]const Item, Context) anyerror!usize,
        max_age_seconds: u64,
        /// Rewrites IMGW wall-clock timestamps in place before they are stored.
        /// Null for a product whose parser already emits the UTC-suffixed form
        /// the store keeps, which is what synop and meteo do.
        fromWarsaw: ?*const fn (std.mem.Allocator, []Item, Context) anyerror!void = null,
    };
}

/// Both measurement products normalize into `model.Observation`, so only the
/// fetch and the freshness window differ.
const measurement_sources = [_]Source(model.Observation){
    .{ .label = "synop", .fetch = &imgw.synop.fetch, .deinit = &model.deinitObservations, .record = &recordObservations, .max_age_seconds = freshness.synop_seconds },
    .{ .label = "meteo", .fetch = &imgw.meteo.fetch, .deinit = &model.deinitObservations, .record = &recordObservations, .max_age_seconds = freshness.meteo_seconds },
};

const hydro_source: Source(model.HydroObservation) = .{
    .label = "hydro",
    .fetch = &imgw.hydro.fetch,
    .deinit = &model.deinitHydro,
    .record = &recordHydroObservations,
    .max_age_seconds = freshness.hydro_seconds,
    .fromWarsaw = &hydroTimestampsToUtc,
};

/// The hydro parser keeps IMGW's wall-clock timestamps verbatim, so the store
/// boundary is where they take the UTC form every other product arrives in.
fn hydroTimestampsToUtc(allocator: std.mem.Allocator, items: []model.HydroObservation, context: Context) anyerror!void {
    return model.utcHydroTimestamps(allocator, items, context, struct {
        fn resolve(ctx: Context, alloc: std.mem.Allocator, local: []const u8) anyerror![]u8 {
            return ctx.store.clock.utcText(alloc, try ctx.store.clock.resolveInstant(local));
        }
    }.resolve);
}

/// Warnings change independently of the measurements, so they run on their own
/// cadence and against their own sources. They are listed on every poll, which
/// is what keeps them from outliving their validity window, so a fresh poll is
/// exactly as good as a fresh response here too.
const warning_sources = [_]Source(warnings.Warning){
    .{ .label = "meteo warning", .fetch = &imgw.warnings.meteo.fetch, .deinit = &warnings.deinitWarnings, .record = &recordWarningBatch, .max_age_seconds = freshness.meteo_seconds },
    .{ .label = "hydro warning", .fetch = &imgw.warnings.hydro.fetch, .deinit = &warnings.deinitWarnings, .record = &recordWarningBatch, .max_age_seconds = freshness.hydro_seconds },
};

/// `scratch` backs the temporary memory of a poll and nothing else: a poll
/// downloads a few megabytes, decodes them and writes them to the store, and
/// every byte of that is dead once the product is stored. `main` therefore
/// passes `std.heap.page_allocator` so the pages go back to the kernel instead
/// of staying mapped, empty and dirty inside the process allocator until it
/// exits.
pub fn run(scratch: std.mem.Allocator, io: Io, store: *storage.Store, interval_seconds: u64) void {
    while (true) {
        for (measurement_sources) |source| {
            poll(model.Observation, source, source.fetch, scratch, io, .{ .store = store, .label = source.label, .now_seconds = nowSeconds(io) });
        }
        poll(model.HydroObservation, hydro_source, hydro_source.fetch, scratch, io, .{ .store = store, .label = hydro_source.label, .now_seconds = nowSeconds(io) });
        sleep(io, interval_seconds) catch return;
    }
}

/// The warnings run on their own cadence; `scratch` has the same meaning as in
/// `run`.
pub fn runWarnings(scratch: std.mem.Allocator, io: Io, store: *storage.Store, interval_seconds: u64) void {
    while (true) {
        updateWarnings(scratch, io, store);
        sleep(io, interval_seconds) catch return;
    }
}

fn updateWarnings(scratch: std.mem.Allocator, io: Io, store: *storage.Store) void {
    const now_seconds = nowSeconds(io);
    const seen_at = timestamps.clock().localNow(scratch, io) catch |err| {
        std.log.err("reading the wall clock failed: {t}", .{err});
        return;
    };
    defer scratch.free(seen_at);

    for (warning_sources) |source| {
        poll(warnings.Warning, source, source.fetch, scratch, io, .{ .store = store, .label = source.label, .seen_at = seen_at, .now_seconds = now_seconds });
    }
}

/// One poll of one product: reuse, fetch, store, report. Each source is stored
/// independently so one failing endpoint does not hide the others.
///
/// The store already holds the previous response, so a source polled within
/// its freshness window is left alone and the endpoint is not contacted at all.
/// `fetch` is a parameter only so a test can observe that decision without a
/// network; every production call passes the source's own fetch.
///
/// The decoded batch lives in an arena over `scratch` that is released before
/// this function returns. That is the whole point of the arena: the response
/// body and the items built from it are large, short-lived and independent of
/// each other, so a general-purpose allocator keeps their pages mapped long
/// after they are freed, while an arena hands them back in one step.
fn poll(
    comptime Item: type,
    source: Source(Item),
    fetch: *const fn (std.mem.Allocator, Io) imgw.Error![]Item,
    scratch: std.mem.Allocator,
    io: Io,
    context: Context,
) void {
    const fresh = context.store.isFresh(source.label, context.now_seconds, source.max_age_seconds) catch |err| {
        // A store that cannot answer has to answer conservatively: update
        // rather than serve data of unknown age.
        std.log.err("checking the freshness of IMGW {s} failed: {t}", .{ context.label, err });
        return;
    };
    if (fresh) {
        std.log.info("IMGW {s} is fresh, skipping the download", .{context.label});
        return;
    }

    var arena: std.heap.ArenaAllocator = .init(scratch);
    defer arena.deinit();
    const work = arena.allocator();

    const items = fetch(work, io) catch |err| {
        std.log.err("IMGW {s} fetch failed: {t}", .{ context.label, err });
        return;
    };
    defer source.deinit(work, items);

    if (source.fromWarsaw) |convert| {
        convert(work, items, context) catch |err| {
            std.log.err("rewriting IMGW {s} timestamps failed: {t}", .{ context.label, err });
            return;
        };
    }

    const saved = source.record(items, context) catch |err| {
        std.log.err("saving IMGW {s} failed: {t}", .{ context.label, err });
        return;
    };
    context.store.releaseMemory();
    context.store.recordPoll(source.label, context.now_seconds) catch |err| {
        std.log.err("recording the IMGW {s} poll failed: {t}", .{ context.label, err });
        return;
    };
    std.log.info("IMGW {s} update saved {d}/{d}", .{ context.label, saved, items.len });
}

/// A failing row is logged and skipped so a single bad station does not discard
/// the rest of the batch. The source label is the product the poll belongs to,
/// which is what lets the store list synoptic and meteorological stations apart.
fn recordObservations(items: []const model.Observation, context: Context) anyerror!usize {
    var saved: usize = 0;
    for (items) |item| {
        context.store.record(context.label, item) catch |err| {
            std.log.err("saving IMGW {s} observation for {s} failed: {t}", .{ context.label, item.station_id, err });
            continue;
        };
        saved += 1;
    }
    return saved;
}

fn recordHydroObservations(items: []const model.HydroObservation, context: Context) anyerror!usize {
    var saved: usize = 0;
    for (items) |item| {
        context.store.recordHydro(item) catch |err| {
            std.log.err("saving IMGW {s} gauge {s} failed: {t}", .{ context.label, item.station_id, err });
            continue;
        };
        saved += 1;
    }
    return saved;
}

fn recordWarningBatch(items: []const warnings.Warning, context: Context) anyerror!usize {
    return context.store.recordWarnings(items, context.seen_at);
}

/// The wall clock in epoch seconds, which is the unit `source_state` stores.
fn nowSeconds(io: Io) u64 {
    return @intCast(Io.Clock.real.now(io).toSeconds());
}

fn sleep(io: Io, interval_seconds: u64) !void {
    const duration: Io.Clock.Duration = .{
        .raw = Io.Duration.fromSeconds(@intCast(interval_seconds)),
        .clock = .awake,
    };
    return duration.sleep(io);
}

/// The shape a test fetch uses to report how often a poll really went to the
/// network.
const FetchCalls = struct {
    calls: usize = 0,
};

/// A synop source whose fields are all static: the tests replace its fetch with
/// `countingFetch`, so no network is involved.
const test_source: Source(model.Observation) = .{
    .label = "synop",
    .fetch = &unreachableFetch,
    .deinit = &model.deinitObservations,
    .record = &recordObservations,
    .max_age_seconds = freshness.synop_seconds,
};

/// The default fetch of `test_source`. Every test passes its own counting fetch
/// instead, so reaching this one is a failed expectation.
fn unreachableFetch(allocator: std.mem.Allocator, io: Io) imgw.Error![]model.Observation {
    _ = allocator;
    _ = io;
    return error.NetworkUnavailable;
}

/// The fetch every test passes to `poll`: it counts its calls and answers with
/// one owned observation. The strings come from `allocator`, so the poll
/// releases them exactly like a decoded IMGW batch.
fn countingFetch(calls: *FetchCalls, allocator: std.mem.Allocator, io: Io) imgw.Error![]model.Observation {
    _ = io;
    calls.calls += 1;

    const items = allocator.alloc(model.Observation, 1) catch return error.OutOfMemory;
    errdefer allocator.free(items);
    items[0] = testObservation(allocator) catch |err| {
        model.deinitObservationItems(allocator, items[0..0]);
        return err;
    };
    return items;
}

/// One owned observation at the fixed timestamp the tests assert on.
fn testObservation(allocator: std.mem.Allocator) imgw.Error!model.Observation {
    const station_id = try allocator.dupe(u8, "12424");
    errdefer allocator.free(station_id);
    const station_name = try allocator.dupe(u8, "Wrocław");
    errdefer allocator.free(station_name);
    const observed_at = try allocator.dupe(u8, "2026-09-17T07:00:00Z");
    return .{
        .station_id = station_id,
        .station_name = station_name,
        .observed_at = observed_at,
        .temperature_c = 18.5,
        .wind_speed_m_s = null,
        .wind_direction_deg = null,
        .relative_humidity_percent = null,
        .precipitation_mm = null,
        .pressure_hpa = null,
    };
}

test "a fresh source is served from the store instead of IMGW" {
    const fetch = struct {
        fn call(allocator: std.mem.Allocator, io: Io) imgw.Error![]model.Observation {
            return countingFetch(&calls, allocator, io);
        }
        var calls: FetchCalls = .{};
    };

    var store = try storage.Store.initMemory(std.testing.allocator);
    defer store.deinit();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context: Context = .{ .store = &store, .label = test_source.label, .now_seconds = 1_000 };

    // Nothing is stored yet, so the very first poll always downloads.
    poll(model.Observation, test_source, &fetch.call, allocator, std.testing.io, context);
    try std.testing.expectEqual(@as(usize, 1), fetch.calls.calls);

    const observations = try store.history(std.testing.allocator, "12424", "2026-09-17T00:00:00Z");
    defer model.deinitObservations(std.testing.allocator, observations);
    try std.testing.expectEqual(@as(usize, 1), observations.len);

    // The successful poll is on record, so a second poll inside the window does
    // not touch the endpoint.
    poll(model.Observation, test_source, &fetch.call, allocator, std.testing.io, context);
    try std.testing.expectEqual(@as(usize, 1), fetch.calls.calls);

    // Once the window has passed the source is polled again.
    poll(model.Observation, test_source, &fetch.call, allocator, std.testing.io, .{
        .store = &store,
        .label = test_source.label,
        .now_seconds = context.now_seconds + test_source.max_age_seconds + 1,
    });
    try std.testing.expectEqual(@as(usize, 2), fetch.calls.calls);
}

test "a source is polled again in the next cycle" {
    const fetch = struct {
        fn call(allocator: std.mem.Allocator, io: Io) imgw.Error![]model.Observation {
            return countingFetch(&calls, allocator, io);
        }
        var calls: FetchCalls = .{};
    };

    var store = try storage.Store.initMemory(std.testing.allocator);
    defer store.deinit();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first: Context = .{ .store = &store, .label = test_source.label, .now_seconds = 10_000 };
    poll(model.Observation, test_source, &fetch.call, allocator, std.testing.io, first);
    try std.testing.expectEqual(@as(usize, 1), fetch.calls.calls);

    // Exactly the freshness window later the stored rows are still used.
    const still_fresh: Context = .{ .store = &store, .label = test_source.label, .now_seconds = first.now_seconds + test_source.max_age_seconds };
    poll(model.Observation, test_source, &fetch.call, allocator, std.testing.io, still_fresh);
    try std.testing.expectEqual(@as(usize, 1), fetch.calls.calls);

    // A poll outside the window downloads, which also refreshes the stamp.
    const stale: Context = .{ .store = &store, .label = test_source.label, .now_seconds = still_fresh.now_seconds + 1 };
    poll(model.Observation, test_source, &fetch.call, allocator, std.testing.io, stale);
    try std.testing.expectEqual(@as(usize, 2), fetch.calls.calls);
    try std.testing.expect(try store.isFresh(test_source.label, stale.now_seconds, test_source.max_age_seconds));
}

test "measurement source labels are known products" {
    // The label is written to every observation row and accepted as the
    // stations endpoints' `?source=` filter, so the polling table and the API
    // have to name the products the same way.
    for (measurement_sources) |source| {
        try std.testing.expect(model.isObservationSource(source.label));
    }
}
