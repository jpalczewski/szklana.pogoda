document.addEventListener("alpine:init", () => {
  Alpine.data("main_window", main_window);
  Alpine.data("forecast", forecast);

  /* The about dialog owns the process figures it shows: opening it reads them
   * again, and a dialog left closed never asks the backend for them. */
  Alpine.data("about", () => {
    const base = modal();
    return {
      ...base,
      ...process_memory(),
      show() {
        base.show.call(this);
        this.load();
      },
    };
  });

  Alpine.data("imgw", () => {
    const base = modal();
    return {
      ...base,
      tab: "synop",
      query: { synop: "", hydro: "", meteo: "", warnings: "", storm: "" },
      /* The active warnings can be narrowed to one IMGW product; `""` keeps
       * both meteorological and hydrological warnings in the list. */
      source_filter: "",
      /* The browser position is asked for once and then reused by every tab:
       * `nearby` only decides whether the active list is narrowed to the
       * closest stations, and it survives switching tabs and closing the
       * dialog. */
      location: null,
      locating: false,
      location_error: "",
      nearby: false,
      tabs: {
        synop: {
          endpoint: "/api/weather/stations?source=synop",
          kind: "weather",
          items: null,
          loading: false,
          error: "",
          selected: null,
          detail: null,
          detail_loading: false,
          detail_error: "",
        },
        hydro: {
          endpoint: "/api/hydro/stations",
          kind: "hydro",
          items: null,
          loading: false,
          error: "",
          selected: null,
          detail: null,
          detail_loading: false,
          detail_error: "",
        },
        meteo: {
          endpoint: "/api/weather/stations?source=meteo",
          kind: "weather",
          items: null,
          loading: false,
          error: "",
          selected: null,
          detail: null,
          detail_loading: false,
          detail_error: "",
        },
        /* Warnings carry their whole record in the listing, so the tab needs
         * no history request of its own. */
        warnings: {
          endpoint: "/api/warnings",
          kind: "warnings",
          items: null,
          loading: false,
          error: "",
          selected: null,
          detail: null,
          detail_loading: false,
          detail_error: "",
        },
        /* The storm tab lists cities, not stations, and its reading is fetched
         * from Antistorm only when the user asks for it: the selection alone
         * changes nothing on the wire. */
        storm: {
          endpoint: "/api/storm/cities",
          kind: "storm",
          items: null,
          loading: false,
          error: "",
          selected: null,
          detail: null,
          detail_loading: false,
          detail_error: "",
        },
      },

      get active() {
        return this.tabs[this.tab];
      },

      get search_placeholder() {
        if (this.tab === "warnings") return document.body.dataset.imgwWarningSearchPlaceholder;
        if (this.tab === "storm") return document.body.dataset.imgwStormSearchPlaceholder;
        return document.body.dataset.imgwSearchPlaceholder;
      },

      /* Only the products that publish a station position can be narrowed by
       * distance; IMGW's synoptic readings carry none. */
      get nearby_supported() {
        return (this.active.items ?? []).some(
          (station) => station.longitude != null && station.latitude != null,
        );
      },

      /* The typed filter narrows first; "nearest" then keeps the closest
       * stations of whatever is left, and stays out of the way on a list that
       * has no position to measure. */
      get filtered() {
        const items = this.active.items ?? [];
        const needle = fold(this.query[this.tab]);
        if (this.active.kind === "warnings") return this.filtered_warnings(items, needle);

        const matching =
          needle.length === 0 ? items : items.filter((item) => item.search.includes(needle));
        if (this.active.kind === "storm" || !this.nearby) return matching;

        const located = matching
          .map((station) => ({ ...station, distance_km: distanceKm(this.location, station) }))
          .filter((station) => station.distance_km != null);
        if (located.length === 0) return matching;
        return located.sort((a, b) => a.distance_km - b.distance_km).slice(0, nearby_limit);
      },

      /* Warnings are narrowed by product and by text, then ordered by the
       * moment they stop applying: the long-lived warnings that expire on
       * 9999-12-31 sink below the ones that are about to end. */
      filtered_warnings(items, needle) {
        const by_source =
          this.source_filter === "" ? items : items.filter((warning) => warning.source === this.source_filter);
        const matching =
          needle.length === 0 ? by_source : by_source.filter((warning) => warning.search.includes(needle));
        return [...matching].sort(
          (a, b) => a.effective_to.localeCompare(b.effective_to) || a.event.localeCompare(b.event, "pl"),
        );
      },

      show() {
        base.show.call(this);
        this.load(this.tab);
        this.$nextTick(() => this.$refs.search.focus());
      },

      select(name) {
        this.tab = name;
        this.load(name);
        this.$nextTick(() => this.$root.querySelector(`[data-tab="${name}"]`)?.focus());
      },

      /* The clear button sits to the right of the field, so the focus returns
       * there to keep typing right after the filter is dropped. */
      clear_search() {
        this.query[this.tab] = "";
        this.$nextTick(() => this.$refs.search.focus());
      },

      /* The first activation asks the browser where the user is; a later one
       * reuses that fix, so toggling the filter never prompts twice. A refused
       * or unavailable position is reported under the button and leaves every
       * list complete. */
      toggle_nearby() {
        if (this.nearby) {
          this.nearby = false;
          return;
        }
        if (this.location) {
          this.nearby = true;
          return;
        }
        if (!navigator.geolocation) {
          this.location_error = document.body.dataset.locationUnavailable;
          return;
        }

        this.locating = true;
        this.location_error = "";
        navigator.geolocation.getCurrentPosition(
          (position) => {
            this.location = {
              latitude: position.coords.latitude,
              longitude: position.coords.longitude,
            };
            this.nearby = true;
            this.locating = false;
          },
          (error) => {
            this.location_error =
              error.code === permission_denied
                ? document.body.dataset.locationDenied
                : document.body.dataset.locationUnavailable;
            this.locating = false;
          },
          { enableHighAccuracy: false, timeout: 10000, maximumAge: 600000 },
        );
      },

      step(delta) {
        const order = ["synop", "hydro", "meteo", "warnings", "storm"];
        const index = order.indexOf(this.tab);
        this.select(order[(index + delta + order.length) % order.length]);
      },

      /* Station tabs load once and keep their rows, so switching back and forth
       * neither re-fetches nor loses the filter the user typed. Warnings are
       * time-sensitive, so that tab reloads on every visit. A failed tab stays
       * empty and is retried the next time it is shown. */
      async load(name) {
        const tab = this.tabs[name];
        if (tab.loading) return;
        if (tab.items && tab.kind !== "warnings") return;
        tab.loading = true;
        tab.error = "";
        try {
          const response = await fetch(tab.endpoint);
          if (!response.ok) {
            tab.error = `${document.body.dataset.httpError}${response.status}`;
            return;
          }
          const payload = await response.json();
          const rows = payload.warnings ?? payload.stations ?? payload.cities ?? [];
          tab.items = rows.map((row) => this.describe_row(tab, row));
          if (tab.selected && !tab.items.some((item) => item.key === tab.selected.key)) {
            tab.selected = null;
            tab.detail = null;
          }
        } catch (err) {
          console.error("imgw request failed", err);
          tab.error = document.body.dataset.imgwUnavailable;
        } finally {
          tab.loading = false;
        }
      },

      /* Every row gets one key the list box and the selection share, and one
       * folded string the search box compares against. The warning key names
       * the product too, because IMGW's two warning products number their
       * warnings independently. */
      describe_row(tab, row) {
        if (tab.kind === "warnings") {
          return {
            ...row,
            kind: "warnings",
            key: `${row.source}:${row.warning_id}`,
            search: fold(
              `${row.event} ${row.office} ${row.content} ${row.comment ?? ""} ${row.warning_id} ${row.source} ${this.warning_areas(row).join(" ")}`,
            ),
          };
        }
        if (tab.kind === "storm") {
          return {
            ...row,
            kind: "storm",
            key: `${row.city_id}`,
            search: fold(`${row.city_name} ${row.city_id}`),
          };
        }
        return {
          ...row,
          kind: tab.kind,
          key: row.station_id,
          search: fold(`${row.station_name} ${row.station_id} ${row.river ?? ""} ${row.voivodeship ?? ""}`),
        };
      },

      /* A click on a list box row shows that record below the list. Gauge and
       * warning rows already carry every stored column; a measurement row is
       * only a summary, so its newest observation is read back from the store.
       * A city is listed without a reading: Antistorm is asked for it only when
       * the user presses the fetch button.
       */
      pick(event) {
        const tab = this.active;
        const item = (tab.items ?? []).find((row) => row.key === event.target.value) ?? null;
        tab.selected = item;
        tab.detail = item && (item.kind === "hydro" || item.kind === "warnings") ? item : null;
        tab.detail_error = "";
        tab.detail_loading = false;
        if (item && item.kind === "weather") this.load_detail(tab, item);
      },

      async load_detail(tab, station) {
        tab.detail = null;
        tab.detail_loading = true;
        try {
          const station_id = encodeURIComponent(station.station_id);
          const since = encodeURIComponent(station.last_observed_at);
          const response = await fetch(`/api/weather/history?station_id=${station_id}&since=${since}`);
          if (!response.ok) {
            tab.detail_error = `${document.body.dataset.httpError}${response.status}`;
            return;
          }
          const payload = await response.json();
          tab.detail = payload.observations?.[0] ?? null;
        } catch (err) {
          console.error("imgw detail request failed", err);
          tab.detail_error = document.body.dataset.imgwUnavailable;
        } finally {
          tab.detail_loading = false;
        }
      },

      /* Reads the selected city's current storm and rain probabilities. The
       * client caches one reading per city for a few minutes, so pressing the
       * button again inside that window answers from memory.
       */
      async load_storm() {
        const tab = this.tabs.storm;
        const city = tab.selected;
        if (!city) return;

        tab.detail = null;
        tab.detail_error = "";
        tab.detail_loading = true;
        try {
          const city_id = encodeURIComponent(city.city_id);
          const response = await fetch(`/api/storm/city?city=${city_id}`);
          if (!response.ok) {
            tab.detail_error = `${document.body.dataset.httpError}${response.status}`;
            return;
          }
          const payload = await response.json();
          tab.detail = payload.storm ?? null;
        } catch (err) {
          console.error("storm request failed", err);
          tab.detail_error = document.body.dataset.imgwStormUnavailable;
        } finally {
          tab.detail_loading = false;
        }
      },

      format_value(value, unit) {
        if (value === null || value === undefined || value === "") return "—";
        return unit ? `${value} ${unit}` : `${value}`;
      },

      /* Antistorm caps a countdown at 255 and documents that as "unknown", so
       * the cap is shown as a missing value rather than two hours short. */
      format_storm_minutes(minutes) {
        if (minutes === null || minutes === undefined) return "—";
        if (minutes >= storm_minutes_unknown) return "—";
        return `${minutes} min`;
      },

      format_flag(value) {
        if (value === null || value === undefined) return "—";
        return value ? document.body.dataset.imgwStormYes : document.body.dataset.imgwStormNo;
      },

      /* A cached reading is a few minutes old at most; the age is reported so
       * a repeated press does not look like a stale answer. */
      describe_age(detail) {
        if (!detail) return "—";
        const age = detail.fetched_age_seconds ?? 0;
        if (age < 60) return document.body.dataset.imgwStormJustNow;
        return `${format_value(Math.round(age / 60))} min`;
      },
      coordinates(place) {
        if (place?.latitude == null || place?.longitude == null) return "—";
        return `${place.latitude}, ${place.longitude}`;
      },

      /* Reaches the list box as one line: an event, its product, its degree
       * when IMGW publishes one, and the moment it stops applying. A city has
       * no reading yet, so its row is only the name and the id the request
       * needs. */
      describe(item) {
        if (item.kind === "storm") return `${item.city_name} (${item.city_id})`;
        if (item.kind === "warnings") {
          const degree =
            item.severity == null ? "" : ` — ${document.body.dataset.imgwWarningSeverity} ${item.severity}`;
          return `${item.event} — ${this.source_label(item)}${degree} — ${item.effective_to}`;
        }
        const name = `${item.station_name} (${item.station_id})`;
        const distance = item.distance_km == null ? "" : ` — ${formatDistance(item.distance_km)}`;
        if (item.kind !== "hydro") return `${name} — ${item.last_observed_at}${distance}`;
        const river = item.river ? `${item.river}: ` : "";
        const level = item.water_level_cm == null ? "—" : `${item.water_level_cm} cm`;
        return `${name} — ${river}${level}${distance}`;
      },

      source_label(item) {
        if (item?.source === "meteo") return document.body.dataset.imgwWarningSourceMeteo;
        if (item?.source === "hydro") return document.body.dataset.imgwWarningSourceHydro;
        return item?.source ?? "—";
      },

      severity_label(item) {
        return item?.severity == null ? "—" : `${item.severity}`;
      },

      /* IMGW degrees run 1 to 3; hydrological warnings also use 0 and negative
       * values for a long-term drought, which share a calmer colour. */
      severity_class(item) {
        const severity = item?.severity;
        if (severity == null) return "severity-none";
        if (severity >= 3) return "severity-3";
        if (severity === 2) return "severity-2";
        if (severity === 1) return "severity-1";
        return "severity-low";
      },

      /* One line per warned area, so the meteo county codes and the hydro
       * voivodeship/basin pairs read the same way. */
      warning_areas(item) {
        if (!item) return [];
        const areas = [];
        const seen = new Set();
        for (const area of item.areas ?? []) {
          const parts = [
            area.teryt ? `TERYT ${area.teryt}` : "",
            area.voivodeship ?? "",
            area.description ?? "",
            area.basin_code ?? "",
          ].filter(Boolean);
          if (parts.length === 0) continue;
          const text = parts.join(" — ");
          if (seen.has(text)) continue;
          seen.add(text);
          areas.push(text);
        }
        return areas;
      },
    };
  });
});

/* The about dialog reports how much memory the process holds. The figures are
 * read from the backend on demand and shown in mebibytes. */
function process_memory() {
  return {
    loading: false,
    usage: null,
    error: "",

    async load() {
      this.loading = true;
      this.error = "";
      try {
        const response = await fetch("/api/memory");
        if (!response.ok) {
          this.error = `${document.body.dataset.httpError}${response.status}`;
          return;
        }
        this.usage = await response.json();
      } catch (err) {
        console.error("memory request failed", err);
        this.error = document.body.dataset.memoryUnavailable;
      } finally {
        this.loading = false;
      }
    },

    format_bytes(bytes) {
      if (typeof bytes !== "number") return "";
      return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
    },
  };
}

/* The main window starts centred in normal document flow. The first drag lifts
 * it out of flow at its current on-screen spot (no jump) and pins it with
 * `left`/`top`, which it keeps afterwards; unlike the dialogs below it is not
 * re-centred on every open, since it never closes. `left`/`top` are used
 * instead of a transform so the window never becomes the containing block for
 * its own nested dialogs' `position: fixed` backdrops. */
function main_window() {
  return {
    position: null,
    drag: null,

    start_drag(event) {
      if (event.button !== 0 || event.target.closest("button")) return;
      event.preventDefault();
      event.currentTarget.setPointerCapture(event.pointerId);

      const rect = this.$refs.mainWindow.getBoundingClientRect();
      if (!this.position) this.position = { left: rect.left, top: rect.top };
      this.drag = {
        pointer: event.pointerId,
        grab: { x: event.clientX - this.position.left, y: event.clientY - this.position.top },
        width: rect.width,
      };
    },

    move_drag(event) {
      if (event.pointerId !== this.drag?.pointer) return;
      const { grab, width } = this.drag;
      const edge = 24;
      this.position = {
        left: clamp(event.clientX - grab.x, edge - width, window.innerWidth - edge),
        top: clamp(event.clientY - grab.y, 0, window.innerHeight - edge),
      };
    },

    end_drag(event) {
      if (event.pointerId !== this.drag?.pointer) return;
      this.drag = null;
    },
  };
}

/* Every dialog on the page opens the same way: a full-screen backdrop, a window
 * dragged by its title bar and a close button. The behaviour lives here once so
 * a new dialog only supplies its own body. */
function modal() {
  return {
    open: false,
    offset: { x: 0, y: 0 },
    drag: null,
    pressed_backdrop: false,

    show() {
      this.offset = { x: 0, y: 0 };
      this.pressed_backdrop = false;
      this.open = true;
      this.$nextTick(() => this.$refs.closeButton.focus());
    },

    hide() {
      if (!this.open) return;
      this.open = false;
      this.drag = null;
      this.$refs.launcher.focus();
    },

    /* Only a press that also started on the backdrop may dismiss the dialog;
     * a run that began inside the window and ended over the backdrop must
     * leave it open. */
    press_backdrop() {
      this.pressed_backdrop = true;
    },

    release_backdrop() {
      if (!this.pressed_backdrop) return;
      this.pressed_backdrop = false;
      this.hide();
    },

    start_drag(event) {
      if (event.button !== 0 || event.target.closest("button")) return;
      event.preventDefault();
      event.currentTarget.setPointerCapture(event.pointerId);

      const rect = this.$refs.dialog.getBoundingClientRect();
      this.drag = {
        pointer: event.pointerId,
        grab: { x: event.clientX - this.offset.x, y: event.clientY - this.offset.y },
        origin: { x: rect.left - this.offset.x, y: rect.top - this.offset.y },
        width: rect.width,
      };
    },

    move_drag(event) {
      if (event.pointerId !== this.drag?.pointer) return;
      const { grab, origin, width } = this.drag;
      const edge = 24;
      this.offset = {
        x: clamp(event.clientX - grab.x, edge - origin.x - width, window.innerWidth - edge - origin.x),
        y: clamp(event.clientY - grab.y, -origin.y, window.innerHeight - edge - origin.y),
      };
    },

    end_drag(event) {
      if (event.pointerId !== this.drag?.pointer) return;
      this.drag = null;
    },
  };
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

/* How many stations the nearest list keeps. The list box shows twelve rows, so
 * ten of them fit with room for the heading. */
const nearby_limit = 10;

/* Antistorm publishes its countdowns as 0-255 and uses 255 for "no estimate". */
const storm_minutes_unknown = 255;

/* `PositionError.PERMISSION_DENIED`: an explicitly refused position deserves a
 * different message from one the browser could not determine. */
const permission_denied = 1;

/* The great-circle distance between the user and a station, in kilometres, or
 * null when either side has no position. The mean Earth radius is accurate to
 * well under a kilometre over the distances a station list spans. */
function distanceKm(from, place) {
  if (from?.latitude == null || from?.longitude == null) return null;
  if (place?.latitude == null || place?.longitude == null) return null;

  const to_radians = (degrees) => (degrees * Math.PI) / 180;
  const delta_latitude = to_radians(place.latitude - from.latitude);
  const delta_longitude = to_radians(place.longitude - from.longitude);
  const a =
    Math.sin(delta_latitude / 2) ** 2 +
    Math.cos(to_radians(from.latitude)) *
      Math.cos(to_radians(place.latitude)) *
      Math.sin(delta_longitude / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.min(1, Math.sqrt(a)));
}

/* A tenth of a kilometre matters while walking to the nearest station and
 * becomes noise once the station is tens of kilometres away. */
function formatDistance(km) {
  return `${km < 10 ? km.toFixed(1) : Math.round(km)} km`;
}

/* Folds a station search term to a comparable form: case, diacritics and the
 * stroked l, so "lodz" matches "Łódź" and "wroclaw" matches "Wrocław". */
function fold(value) {
  return value
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/ł/g, "l");
}

/* WMO weather interpretation codes, folded into the few groups the page has a
 * word and a picture for. `label` names the `data-wmo-*` attribute that carries
 * the word, so the wording stays in the locale files; `icon` names a symbol of
 * the icon sprite. */
function weather_group(code) {
  if (code === 0) return { label: "wmoClear", icon: "clear" };
  if (code === 1 || code === 2) return { label: "wmoPartly", icon: "partly" };
  if (code === 3) return { label: "wmoCloudy", icon: "cloudy" };
  if (code === 45 || code === 48) return { label: "wmoFog", icon: "fog" };
  if (code >= 51 && code <= 57) return { label: "wmoDrizzle", icon: "drizzle" };
  if (code >= 61 && code <= 67) return { label: "wmoRain", icon: "rain" };
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return { label: "wmoSnow", icon: "snow" };
  if (code >= 80 && code <= 82) return { label: "wmoShowers", icon: "showers" };
  if (code >= 95 && code <= 99) return { label: "wmoThunderstorm", icon: "thunderstorm" };
  return { label: null, icon: null };
}

/* The icons are symbols in the SVG sprite the server draws from
 * `src/web/weather_icons.txt`; the page names its versioned URL in
 * `data-weather-icons`. The markup contains only that URL and a name from
 * `weather_group`, never anything from the forecast, so it is safe to insert
 * as HTML. CSS scales the icon by a whole number (see `app.css`), which keeps
 * the pixels crisp. */
function weather_icon(name) {
  if (!name) return "";
  return `<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false"><use href="${document.body.dataset.weatherIcons}#${name}"/></svg>`;
}

const compass_points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];

/* Where a wind blows from, as the nearest of eight compass points. */
function compassPoint(degrees) {
  if (degrees == null) return "";
  return compass_points[Math.round((((degrees % 360) + 360) % 360) / 45) % 8];
}

const suggestion_limit = 8;

/* Only a city the user picked by name is remembered: a position fix is never
 * written to storage. */
const last_place_key = "szklana.pogoda:last-place";

/* The forecast panel on the main window. A city is found in the Antistorm list
 * the storm tab already uses, or as the closest entry of that list to the
 * browser's position; either way the forecast itself is requested by
 * coordinates, because the backend does not decode a percent-encoded city name.
 */
function forecast() {
  return {
    cities: null,
    cities_request: null,
    query: "",
    suggestions_open: false,
    active_index: -1,
    /* `{ name, label, latitude, longitude }` for the place on show. */
    place: null,
    locating: false,
    loading: false,
    status: "",
    data: null,
    /* A slow answer for an earlier place must not replace a newer one. */
    request_id: 0,
    /* The tab on show. It belongs to the panel, not to a place, so it survives
     * picking another city. */
    view: "now",

    init() {
      const remembered = this.recall();
      if (!remembered) return;
      this.query = remembered.name;
      this.show_place(remembered);
    },

    get needle() {
      return fold(this.query.trim());
    },

    /* Names that start with the typed text come before names that merely
     * contain it. */
    get suggestions() {
      if (!this.cities || this.needle.length === 0) return [];
      const leading = [];
      const inside = [];
      for (const city of this.cities) {
        const at = city.search.indexOf(this.needle);
        if (at === 0) leading.push(city);
        else if (at > 0) inside.push(city);
      }
      return leading.concat(inside).slice(0, suggestion_limit);
    },

    get list_visible() {
      return this.suggestions_open && this.suggestions.length > 0;
    },

    get no_results() {
      return this.suggestions_open && this.cities !== null && this.needle.length > 0 && this.suggestions.length === 0;
    },

    get active_option() {
      return this.list_visible && this.active_index >= 0 ? `forecast-option-${this.active_index}` : "";
    },

    load_cities() {
      this.cities_request ??= fetch("/api/storm/cities")
        .then((response) => {
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          return response.json();
        })
        .then((payload) => {
          this.cities = (payload.cities ?? [])
            .filter((city) => city.latitude != null && city.longitude != null)
            .map((city) => ({
              name: city.city_name,
              latitude: city.latitude,
              longitude: city.longitude,
              search: fold(city.city_name),
            }));
          return this.cities;
        })
        .catch((err) => {
          console.error("city list request failed", err);
          this.cities_request = null;
          this.status = document.body.dataset.forecastCitiesUnavailable;
          return null;
        });
      return this.cities_request;
    },

    focus_search() {
      this.load_cities();
      this.suggestions_open = true;
    },

    on_input() {
      this.suggestions_open = true;
      this.active_index = 0;
      this.load_cities();
    },

    /* Focus that stays inside the combobox (the option list is not focusable,
     * but the locate button is) keeps the suggestions open. */
    leave(event) {
      if (this.$refs.combo.contains(event.relatedTarget)) return;
      this.suggestions_open = false;
    },

    keydown(event) {
      const count = this.suggestions.length;
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        this.suggestions_open = true;
        if (count === 0) return;
        const step = event.key === "ArrowDown" ? 1 : -1;
        this.active_index = (this.active_index + step + count) % count;
      } else if (event.key === "Enter") {
        if (!this.list_visible) return;
        event.preventDefault();
        this.pick(this.suggestions[Math.max(this.active_index, 0)]);
      } else if (event.key === "Escape" && this.suggestions_open) {
        event.stopPropagation();
        this.suggestions_open = false;
      }
    },

    pick(city) {
      this.query = city.name;
      this.suggestions_open = false;
      const place = { name: city.name, label: city.name, latitude: city.latitude, longitude: city.longitude };
      this.remember(place);
      this.show_place(place);
    },

    /* The position is asked for on every press; the browser's own cache
     * (`maximumAge`) keeps that from prompting or waiting each time. */
    async locate() {
      if (this.locating) return;
      if (!navigator.geolocation) {
        this.status = document.body.dataset.locationUnavailable;
        return;
      }

      this.locating = true;
      this.status = "";
      let position;
      try {
        position = await new Promise((resolve, reject) =>
          navigator.geolocation.getCurrentPosition(resolve, reject, {
            enableHighAccuracy: false,
            timeout: 10000,
            maximumAge: 600000,
          }),
        );
      } catch (error) {
        this.status =
          error.code === permission_denied
            ? document.body.dataset.locationDenied
            : document.body.dataset.locationUnavailable;
        this.locating = false;
        return;
      }

      const here = {
        latitude: Number(position.coords.latitude.toFixed(4)),
        longitude: Number(position.coords.longitude.toFixed(4)),
      };
      const cities = await this.load_cities();
      this.locating = false;

      let nearest = null;
      for (const city of cities ?? []) {
        const km = distanceKm(here, city);
        if (km != null && (nearest === null || km < nearest.km)) nearest = { name: city.name, km };
      }
      this.query = "";
      this.show_place({
        name: nearest?.name ?? `${here.latitude}, ${here.longitude}`,
        label: nearest
          ? `${document.body.dataset.forecastNearest}: ${nearest.name} (${formatDistance(nearest.km)})`
          : `${here.latitude}, ${here.longitude}`,
        ...here,
      });
    },

    select_view(name) {
      this.view = name;
      this.$nextTick(() => this.$root.querySelector(`[data-view="${name}"]`)?.focus());
    },

    step_view(delta) {
      const order = ["now", "days", "hours"];
      const index = order.indexOf(this.view);
      this.select_view(order[(index + delta + order.length) % order.length]);
    },

    async show_place(place) {
      const id = ++this.request_id;
      this.place = place;
      this.data = null;
      this.status = "";
      this.loading = true;
      try {
        const response = await fetch(`/api/forecast?lat=${place.latitude}&lon=${place.longitude}`);
        if (id !== this.request_id) return;
        if (!response.ok) {
          this.status =
            response.status === 502
              ? document.body.dataset.forecastUnavailable
              : `${document.body.dataset.httpError}${response.status}`;
          return;
        }
        const payload = await response.json();
        if (id !== this.request_id) return;
        this.data = payload.forecast;
      } catch (err) {
        if (id !== this.request_id) return;
        console.error("forecast request failed", err);
        this.status = document.body.dataset.forecastUnavailable;
      } finally {
        if (id === this.request_id) this.loading = false;
      }
    },

    recall() {
      try {
        const place = JSON.parse(localStorage.getItem(last_place_key));
        if (typeof place?.name === "string" && Number.isFinite(place.latitude) && Number.isFinite(place.longitude)) {
          return { name: place.name, label: place.name, latitude: place.latitude, longitude: place.longitude };
        }
      } catch {
        /* Storage is a convenience: blocked or corrupt data means no memory. */
      }
      return null;
    },

    remember(place) {
      try {
        localStorage.setItem(
          last_place_key,
          JSON.stringify({ name: place.name, latitude: place.latitude, longitude: place.longitude }),
        );
      } catch {
        /* See recall. */
      }
    },

    get number_format() {
      return new Intl.NumberFormat(document.documentElement.lang, { maximumFractionDigits: 0 });
    },

    number(value, unit = "") {
      return value == null ? "—" : `${this.number_format.format(value)}${unit}`;
    },

    describe(code) {
      const group = weather_group(code);
      return { icon: weather_icon(group.icon), text: group.label ? document.body.dataset[group.label] : "—" };
    },

    get now() {
      const current = this.data?.current;
      if (!current) return null;
      return {
        ...this.describe(current.weather_code),
        temperature: this.number(current.temperature_c, "°C"),
        apparent: this.number(current.apparent_temperature_c, "°C"),
        humidity: this.number(current.relative_humidity_percent, "%"),
        wind: `${this.number(current.wind_speed_kmh, " km/h")} ${compassPoint(current.wind_direction_deg)}`.trim(),
        precipitation: current.precipitation_mm == null ? "—" : `${current.precipitation_mm} mm`,
      };
    },

    get days() {
      const day_format = new Intl.DateTimeFormat(document.documentElement.lang, {
        weekday: "short",
        day: "numeric",
        month: "numeric",
      });
      return (this.data?.daily ?? []).map((day) => ({
        date: day.date,
        // Noon keeps the calendar day whatever timezone the browser is in.
        label: day_format.format(new Date(`${day.date}T12:00:00`)),
        ...this.describe(day.weather_code),
        range: `${this.number(day.temperature_min_c, "°")} / ${this.number(day.temperature_max_c, "°")}`,
        chance: this.number(day.precipitation_chance_percent, "%"),
      }));
    },

    /* The next 24 hours, starting with the current one. `time` is the place's
     * local wall clock, so the hour is read off the text instead of going
     * through a `Date`, which would shift it into the browser's timezone. An
     * hour that opens a new calendar day also carries that day's name. */
    get hours() {
      const day_format = new Intl.DateTimeFormat(document.documentElement.lang, {
        weekday: "short",
        day: "numeric",
        month: "numeric",
      });
      return (this.data?.hourly ?? []).map((hour, index) => {
        const label = hour.time.slice(11, 16);
        const opens_day = index > 0 && label === "00:00";
        const chance = hour.precipitation_chance_percent;
        return {
          time: hour.time,
          label,
          day: opens_day ? day_format.format(new Date(`${hour.time.slice(0, 10)}T12:00:00`)) : "",
          ...this.describe(hour.weather_code),
          temperature: this.number(hour.temperature_c, "°"),
          rain: `${this.number(chance, "%")} · ${hour.precipitation_mm} mm`,
          wind: `${this.number(hour.wind_speed_kmh, " km/h")} ${compassPoint(hour.wind_direction_deg)}`.trim(),
        };
      });
    },
  };
}
