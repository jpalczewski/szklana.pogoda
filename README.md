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
zig build test           # unit tests
zig fmt src              # format
```

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

## Data

| Product | Endpoint | Cadence |
| --- | --- | --- |
| synop | `/api/data/synop` | hourly |
| meteo | `/api/data/meteo/` | ~10 minutes |
| hydro | `/api/data/hydro/` | 10–30 minutes |
| warnings | `/api/data/warningsmeteo`, `/api/data/warningshydro` | on publication |

All timestamps are stored in the UTC-suffixed form `YYYY-MM-DDTHH:MM:SSZ`.

## API

| Route | Description |
| --- | --- |
| `GET /api/weather/stations` | stations with their newest reading time |
| `GET /api/weather/history?station_id=&since=` | observations of one station |
| `GET /api/hydro/stations` | gauges with their newest reading |
| `GET /api/hydro/history?station_id=&since=` | readings of one gauge |
| `GET /api/warnings` | warnings that are still valid |
| `GET /api/warnings/history?since=` | every stored warning revision |
| `GET /api/warnings/revisions?source=&id=` | revisions of one warning |
| `GET /api/memory` | process memory |
| `GET /metrics` | Prometheus metrics (second listener) |

The warning routes all accept `source` (`meteo` or `hydro`) and `teryt` (a
four-digit county code); `since` is an IMGW-style `YYYY-MM-DD HH:MM:SS`
timestamp.

## Layout

`src/imgw/` owns the endpoints and the mapping of IMGW records into the domain
model, `src/weather/` owns the model, the SQLite store and the polling loop,
`src/warnings.zig` owns the warning model, and `src/timestamps.zig` owns the
clock. `AGENTS.md` describes the module boundaries in detail.
