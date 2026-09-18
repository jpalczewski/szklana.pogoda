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
| `GET /api/forecast?lat=&lon=` or `?city=` | Open-Meteo forecast (current + 7-day daily) for one location |
| `GET /api/memory` | process memory |
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

## Layout

`src/imgw/` owns the endpoints and the mapping of IMGW records into the domain
model, `src/weather/` owns the model, the SQLite store and the polling loop,
`src/antistorm/` owns the embedded city table (`cities.json`, generated by
`tools/antistorm_gen.zig`) and the on-demand Antistorm client, `src/openmeteo/`
owns the on-demand Open-Meteo forecast client, `src/warnings.zig` owns the
warning model, and `src/timestamps.zig` owns the clock. `AGENTS.md` describes
the module boundaries in detail.
