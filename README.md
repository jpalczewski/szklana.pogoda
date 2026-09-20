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
| `ACCOUNTS_DATABASE_PATH` | `accounts.db` | SQLite file of anonymous users and their sessions; unlike the weather file it cannot be rebuilt from upstream, so back it up |
| `NEW_SESSIONS_PER_HOUR` | `30` | how many anonymous accounts one client address may make in an hour (an address is shared by a whole carrier or office, so the default is not small) |
| `PUBLIC_ORIGIN` | empty | the origin the site is served from, e.g. `https://szklana.pogoda` (scheme, host, optional port; no path). An `https` origin makes the session cookie `__Host-` and `Secure`, and a request that changes state must name this origin in `Origin`. Empty (development) gives a plain cookie and compares `Origin` with `Host`; the server warns at startup |
| `MAX_BODY_BYTES` | `16384` | request body limit |
| `MAX_CONNECTIONS_PER_CPU` | `4` | connection limit |
| `TRUSTED_PROXIES` | empty | comma-separated IPs or CIDR blocks (`172.18.0.0/16`) of the proxies whose `CF-Connecting-IP` / `X-Forwarded-For` / `X-Real-IP` headers set the access log's `client_ip`; a request from any other peer is logged under its own address |
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
| `GET /api/me` | whether the request carries a live session and whether its account has a login code: `{"session": true\|false, "has_recovery": true\|false}`; never a 401 |
| `POST /api/me/transfer-code` | a code to sign another browser in with, `{"code": "ABCDE-FGHJK", "expires_in_seconds": 600}`; needs a session, replaces the previous one |
| `POST /api/me/recovery-code` | a longer login code that signs in again and again, `{"code": "XXXX-XXXX-XXXX-XXXX-XXXX"}`, shown once; needs a session, replaces the previous one |
| `POST /api/me/login` | `{"code": "..."}` in a JSON body: signs the browser in to the account the code belongs to with a new cookie and joins in the account it held, `{"session": true, "merged": true\|false}`; 401 for a wrong, spent or expired code, 429 past 10 attempts in 10 minutes |
| `DELETE /api/me/session` | ends the caller's session and clears the cookie; 401 without one |
| `GET /api/me/favorites` | the caller's favourite cities, `{"favorites": [{city_name, latitude, longitude}]}`; empty without a session, and asking does not create one |
| `POST /api/me/favorites?city=` | adds a city and answers with the list; the first one from a browser with no session creates it. 404 for a city outside the table, 400 past 50 favourites, 429 when the address made too many accounts |
| `DELETE /api/me/favorites?city=` | removes a city and answers with the list |
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

## Sessions

A visitor is an anonymous user: a row in `accounts.db` and a cookie that names
it, created by the first request that has something to keep (saving a favourite
city) and never by a visit. The cookie holds 256 random bits; the database keeps only
their SHA-256, so a copy of it is not a copy of anyone's session. The cookie is
`__Host-sid` with `HttpOnly`, `Secure` and `SameSite=Lax` when `PUBLIC_ORIGIN`
is `https`, and a plain `sid` otherwise. A session lasts a year of disuse and
is extended at most once an hour. Every `/api/me/*` answer is
`Cache-Control: private, no-store`, and the rest of the API stays cookie-free
and cacheable.

### Signing in with a code

There is no e-mail and no password. A browser with an account asks for a
**transfer code** (10 characters, valid for 10 minutes, one at a time, used once)
and its person types it into another browser; or makes a **login code** (20
characters, shown once, valid until replaced) and keeps it for the day every
browser is lost. Both are typed into one field, and their length says which they
are. Case, spaces and dashes do not matter, and `I`, `L` and `O` are read as `1`,
`1` and `0`.

Signing in gives the browser a new session cookie for that account. If the
browser already held an account of its own, the two are **joined**: their
favourites are added together (up to 50, oldest first), the other browsers of the
joined account come along, and a login code it had goes to an account that has
none. A wrong, spent or expired code is one and the same 401. The database keeps
only the SHA-256 of a code, and a code is never written to a log, an error or a
metric. It travels only in a request or response body, never in the path or the
query of a URL, which the access log records. The one place it is in an address
is a sign-in link's fragment (below), which a browser never sends.

### Sign-in links and QR codes

Under a transfer code the Account dialog draws a **QR code** and offers **Copy
link**. Both stand for `https://<site>/#code=ABCDE12345` (the page's own address,
keeping `/en/`), so a phone's camera or a link pasted on another computer opens
the site with the code in the **fragment**, which a browser does not send to the
server: it is in neither the access log nor a `Referer`. The QR is drawn in the
browser (a vendored, MIT-licensed generator, see `AGENTS.md`) as an inline SVG,
black on white, and goes away with the code: when the ten minutes run out, on
**Hide** and when the dialog closes.

Opening a link **signs nothing in.** The page takes the code out of the address
at once and keeps it in memory, then opens the Account dialog and asks. Anyone can
send a link made from their own code, and using it would put this browser's
favourites into their account, so the dialog says how many favourites would be
joined, tells the person to cancel if someone sent them the link, and puts the
focus on **Cancel**. Only a code of exactly ten characters works as a link, so a
login code never can. This confirmation lowers the risk and does not remove it: a
convincing pretext can still get the click. The stronger design is the reverse,
where the new browser shows a request and the signed-in one approves it, which
needs state on the server and is not built.

What to know when using it:

- The fragment is in browser history and its sync until the page clears it (at
  once), and in the clipboard after **Copy link**, which some systems sync and a
  chat remembers. The code works once and for ten minutes, which bounds this.
- QR scanner apps keep a history of what they read and some send it to a cloud
  safety check.
- A scanner that runs the page but does not click uses nothing up, because
  nothing signs in on its own. One that clicks (rare) uses the code up, and the
  person asks for a new one.
- On iOS a camera opens the link in Safari, not in an installed home-screen web
  app, whose cookies are separate, so the account lands in Safari. Type the code
  into the web app.
- The link uses the address of the browser that shows it. If that is not
  `PUBLIC_ORIGIN`, signing in answers 403.

A limit per client address (an IPv6 client by its /64) caps asking for a code (20
an hour) and trying one (10 in 10 minutes). Anyone who holds the cookie can make
a new login code and so lock the owner's old one out; a stolen cookie is the
account.

A request that is not a `GET` or `HEAD` must carry an `Origin` equal to
`PUBLIC_ORIGIN` (or, with none configured, to its own `Host`), else it is a 403.
A favourite is stored under the spelling of the city table (`gorzow+wielkopolski`
and `Gorz%C3%B3w%20Wielkopolski` are one), never by its id, which shifts when the
table is regenerated. The main page shows a star beside a city picked by name (or
found as the nearest to the position) and a list of the favourites; bare
coordinates cannot be starred.
Never put a secret in a URL: the access log records the target, query string
included.

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
| `szklana_pogoda_session_lookups_total` | `result` | session cookies read by the account routes: `valid`, `missing`, `invalid` (not a token this server issued), `unknown` or `expired` |
| `szklana_pogoda_sessions_created_total` | | anonymous users and sessions created |
| `szklana_pogoda_login_attempts_total` | `kind`, `result` | attempts to sign in with a code: `kind` is `transfer`, `recovery` or `unknown` (refused before the code was read), `result` is `succeeded`, `invalid` or `limited` |
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
owns the on-demand Open-Meteo forecast client, `src/accounts/` owns the
anonymous users and their sessions, `src/warnings.zig` owns the
warning model, and `src/timestamps.zig` owns the clock. `AGENTS.md` describes
the module boundaries in detail.
