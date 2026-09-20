function imgw() {
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

      const closest = byDistance(this.location, matching);
      return closest.length === 0 ? matching : closest.slice(0, nearby_limit);
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
    async toggle_nearby() {
      if (this.nearby) {
        this.nearby = false;
        return;
      }
      if (!this.location) {
        this.locating = true;
        this.location_error = "";
        const fix = await locateUser();
        this.locating = false;
        if (fix.error) {
          this.location_error = fix.error;
          return;
        }
        this.location = fix.position;
      }
      this.nearby = true;
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
}

/* How many stations the nearest list keeps. The list box shows twelve rows, so
 * ten of them fit with room for the heading. */
const nearby_limit = 10;

/* Antistorm publishes its countdowns as 0-255 and uses 255 for "no estimate". */
const storm_minutes_unknown = 255;
