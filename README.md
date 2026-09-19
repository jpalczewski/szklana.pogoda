# szklana.pogoda

A small Zig server that mirrors IMGW's public weather data: synoptic and
meteorological measurements, hydrological gauges and meteorological and
hydrological warnings. It polls the IMGW endpoints, stores every reading in
SQLite and serves it as JSON.

## Requirements

- Zig 0.16
- The system timezone database (`zoneinfo`), including `Europe/Warsaw`

IMGW publishes every timestamp as Europe/Warsaw wall clock. The server converts
those readings to UTC before storing them, using
[zeit](https://github.com/rockorager/zeit), which reads `/usr/share/zoneinfo`
(or another of the well-known `zoneinfo` locations, or `TZDIR` when set). **A
deployment without tzdata still starts**: it logs

```
no timezone database (FileNotFound), using the fixed Warsaw rule
```

and falls back to the built-in Polish rule (CET/CEST, switching at 01:00 UTC on
the last Sunday of March and October, valid since 1996). The fallback names the
same instants as tzdata for every reading except one ambiguous hour a year, so
install `tzdata` in the image when the exact handling of that hour matters.

## Build and run

```sh
zig build                # executable into zig-out/bin/
zig build run            # start the server on 0.0.0.0:8080
zig build run-release    # the same, built with the release profile a deployment uses
zig build test           # unit tests
zig build cities         # regenerate src/antistorm/cities.json (needs the network)
zig fmt src              # format
```

`zig build` builds a debug executable, which is what development wants: it
keeps `DebugAllocator`'s leak checking, at the price of a much larger image.
Deployments build `zig build -Doptimize=ReleaseSafe` (or inspect the deployed
behaviour locally with `zig build run-release`), because a debug executable keeps
several megabytes of its own code and data resident, and `/api/memory` reports
that as if the server held it.

Environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `HOST` | `0.0.0.0` | IPv4 address to listen on |
| `PORT` | `8080` | application listener |
| `METRICS_PORT` | `9090` | metrics listener |
| `DATABASE_PATH` | `weather.db` | SQLite file |
| `MAX_BODY_BYTES` | `16384` | request body limit |
| `MAX_CONNECTIONS_PER_CPU` | `4` | connection limit |
| `TRUST_PROXY` | `false` | read the client address from `X-Forwarded-For` |
| `IMGW_INTERVAL_SECONDS` | `600` | measurement poll interval |
| `IMGW_WARNINGS_INTERVAL_SECONDS` | `300` | warning poll interval |
| `STORM_CACHE_SECONDS` | `300` | how long one Antistorm city reading is reused |
| `FORECAST_CACHE_SECONDS` | `900` | how long one Open-Meteo grid cell's forecast is reused |

## Data

| Product | Endpoint | Cadence |
| --- | --- | --- |
| synop | `/api/data/synop` | hourly |
| meteo | `/api/data/meteo/` | ~10 minutes |
| hydro | `/api/data/hydro/` | 10–30 minutes |
| warnings | `/api/data/warningsmeteo`, `/api/data/warningshydro` | on publication |
| storm | `antistorm.eu/webservice.php?id=` | ~15 minutes, fetched on demand |
| forecast | `api.open-meteo.com/v1/forecast` | ~hourly model update, fetched on demand |

All timestamps are stored in the UTC-suffixed form `YYYY-MM-DDTHH:MM:SSZ`.

## API

| Route | Description |
| --- | --- |
| `GET /api/weather/stations?source=` | stations with their newest reading time |
| `GET /api/weather/history?station_id=&since=` | observations of one station |
| `GET /api/hydro/stations` | gauges with their newest reading |
| `GET /api/hydro/history?station_id=&since=` | readings of one gauge |
| `GET /api/warnings` | warnings that are still valid |
| `GET /api/warnings/history?since=` | every stored warning revision |
| `GET /api/warnings/revisions?source=&id=` | revisions of one warning |
| `GET /api/storm/cities?q=` | the Antistorm city table with ids |
| `GET /api/storm/city?city=` or `?id=` | one city's newest reading |
| `GET /api/forecast?lat=&lon=` or `?city=` | Open-Meteo forecast (current + 7-day daily + next 24 hours) for one location |
| `GET /api/memory` | process memory |
| `GET /healthz` | liveness probe (`ok`); the container's `HEALTHCHECK` |
| `GET /metrics` | Prometheus metrics (second listener) |

`/api/memory` answers `own_bytes` (the memory the process owns: private
anonymous pages on Linux, the physical footprint on macOS), `rss_bytes` (the
resident size) and `virtual_memory_bytes`. The resident size also counts the
clean, file-backed pages of the executable and of the system libraries, which no
part of the process can free; on a small server that is most of it, so the about
dialog shows `own_bytes` and `rss_bytes` and leaves the address space out.

Both pollers decode each IMGW response in an arena over `std.heap.page_allocator`
and release it before the poll ends, so a poll that decodes a few megabytes does
not leave those pages mapped in the process for the rest of its life. A cold
start that downloads every product holds about 5 MiB of its own memory and 14 MiB
resident in the release profile on macOS; the debug build reports about 8 MiB and
25 MiB for the same work.

The weather stations route keeps synoptic and meteorological readings in one
table, so its `source` (`synop` or `meteo`) narrows the listing to a single
measurement product; omitted, it lists both.

The station listings report the position each product publishes as `longitude`
and `latitude`. IMGW's meteo and hydro products publish one, the synoptic
product does not, so a synoptic station reports `null` for both; the browser
uses them for the dialog's "show nearest" filter.

The warning routes all accept `source` (`meteo` or `hydro`) and `teryt` (a
four-digit county code); `since` is an IMGW-style `YYYY-MM-DD HH:MM:SS`
timestamp.

The storm routes address cities the way Antistorm does: by name or by the id its
webservice expects. The city table (439 entries, name and coordinates) is the
committed data file `src/antistorm/cities.json`, where the position of a city
**is** its id. It is included at compile time and decoded there, so nothing is
downloaded just to resolve a name or to list the cities, and a malformed file
stops the build instead of breaking a lookup. `?city=` ignores case and Polish
diacritics, so `gorzow` finds Gorzów Wielkopolski. A city outside the table is a
`404`, an unreachable Antistorm is a `502`, and a reading that is younger than
`STORM_CACHE_SECONDS` is served from memory instead of being fetched again.

The forecast route takes any `lat`/`lon` (Open-Meteo needs no city table) or,
for convenience, a `city` resolved the same way the storm route resolves one,
through the same embedded Antistorm table. An invalid coordinate is a `400`, an
unreachable Open-Meteo is a `502`, and a grid cell younger than
`FORECAST_CACHE_SECONDS` is served from memory instead of being fetched again.
`forecast.hourly` lists the 24 hours from the current one, in the location's
local time; an hour Open-Meteo has no rain probability for reports
`precipitation_chance_percent: null`. The main page shows the forecast in three
tabs: now, the seven days and those 24 hours.

## Link previews

A messenger draws a preview of a shared link from the page's `<meta>` tags, and
its crawler does not run the page's script. `/` and `/en/` therefore answer a
link that names a city, such as `/?city=Zakopane` (percent-encoded, `+` for a
space and a lazy spelling like `lodz` all work), with that city's current
weather in the tags: `og:title` reads `Zakopane: 18°C, pochmurno` and
`og:description` the felt temperature, wind, chance of rain and the day's range.
A city the table does not know, or a forecast that cannot be fetched, serves the
page with its generic tags (or, for a known city without a forecast, its name);
a link preview never makes the page fail. The page rewrites its own address to
`?city=` when a city is picked by name, so copying the address shares that
city; a position fix is never put there.

The preview is text only, with no `og:image` (messengers do not draw SVG, and
the server has no raster renderer yet).

## Metrics

`GET /metrics` on `METRICS_PORT` answers in the Prometheus text format. Neither
the scrape nor `/healthz` is counted in the request series or written to the
access log (a failed one is still logged), so a dashboard of requests shows
visitors and not probes.

| Series | Labels | Meaning |
| --- | --- | --- |
| `szklana_pogoda_http_requests_total` | `method`, `route`, `status` | completed requests of the application listener; `route` is the registered path or `unmatched` |
| `szklana_pogoda_http_in_flight_requests` | `method`, `route` | requests being handled now |
| `szklana_pogoda_http_request_duration_seconds` | `method`, `route`, `status` | histogram, timed from the moment the request head is read |
| `szklana_pogoda_http_head_errors_total` | `reason` | connections whose request head could not be read |
| `szklana_pogoda_poll_total` | `source`, `result` | IMGW polls; `result` is `saved`, `empty` (the product answered with no records, as IMGW does for warnings while none is active), `fresh` (served from the store) or the stage that failed |
| `szklana_pogoda_poll_duration_seconds` | `source` | histogram of the polls that went to the network |
| `szklana_pogoda_poll_records_saved_total` | `source` | rows a poll wrote to the store |
| `szklana_pogoda_poll_last_success_timestamp_seconds` | `source` | Unix time the last successful poll started |
| `szklana_pogoda_cache_lookups_total` | `cache`, `result` | Antistorm (`storm`) and Open-Meteo (`forecast`) cache `hit` or `miss` |
| `szklana_pogoda_upstream_requests_total` | `upstream`, `result` | downloads from Antistorm and Open-Meteo: `succeeded`, `network_error` or `invalid_data` |
| `szklana_pogoda_upstream_request_duration_seconds` | `upstream` | histogram of those downloads |
| `process_resident_memory_bytes`, `process_virtual_memory_bytes`, `szklana_pogoda_process_own_memory_bytes` | | the figures `/api/memory` reports, read at scrape time |

`source` is the product label of the updater's source table: `synop`, `meteo`,
`hydro`, `meteo warning` or `hydro warning`. A poll that failed reports the
stage it failed at (`fetch_failed`, `convert_failed`, `save_failed` or
`record_failed`). `saved` and `empty` both date the last success, so an alert on
a source that stopped updating can use
`time() - szklana_pogoda_poll_last_success_timestamp_seconds`; a source that
answers `empty` on every poll for days is worth a panel of its own, because
that is also what a dead endpoint that mimics IMGW's empty answer would look like.

Every series with a known set of labels (each source's poll counters, the caches,
the upstreams and the head errors) exists from startup at 0, and a source's last
success is 0 until its first success. A source that never succeeds therefore
alerts on that age (about the epoch) and a first error changes a series instead
of creating one, which `rate()` and `increase()` would miss. Labels are bounded:
a value comes from a route table, an enum or a source table, never from a
request, so add no label taken from input.

## Layout

`src/imgw/` owns the endpoints and the mapping of IMGW records into the domain
model, `src/weather/` owns the model, the SQLite store and the polling loop,
`src/antistorm/` owns the embedded city table (`cities.json`, generated by
`tools/antistorm_gen.zig`) and the on-demand Antistorm client, `src/openmeteo/`
owns the on-demand Open-Meteo forecast client, `src/warnings.zig` owns the
warning model, and `src/timestamps.zig` owns the clock. `AGENTS.md` describes
the module boundaries in detail.
