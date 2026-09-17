document.addEventListener("alpine:init", () => {
  Alpine.data("memory", () => ({
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
  }));

  Alpine.data("about", () => ({ ...modal() }));

  Alpine.data("imgw", () => {
    const base = modal();
    return {
      ...base,
      tab: "synop",
      query: { synop: "", hydro: "", meteo: "" },
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
      },

      get active() {
        return this.tabs[this.tab];
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
        const matching =
          needle.length === 0 ? items : items.filter((station) => station.search.includes(needle));
        if (!this.nearby) return matching;

        const located = matching
          .map((station) => ({ ...station, distance_km: distanceKm(this.location, station) }))
          .filter((station) => station.distance_km != null);
        if (located.length === 0) return matching;
        return located.sort((a, b) => a.distance_km - b.distance_km).slice(0, nearby_limit);
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
        const order = ["synop", "hydro", "meteo"];
        const index = order.indexOf(this.tab);
        this.select(order[(index + delta + order.length) % order.length]);
      },

      /* Each tab loads once and keeps its rows, so switching back and forth
       * neither re-fetches nor loses the filter the user typed. A failed tab
       * stays empty and is retried the next time it is shown. */
      async load(name) {
        const tab = this.tabs[name];
        if (tab.items || tab.loading) return;
        tab.loading = true;
        tab.error = "";
        try {
          const response = await fetch(tab.endpoint);
          if (!response.ok) {
            tab.error = `${document.body.dataset.httpError}${response.status}`;
            return;
          }
          const payload = await response.json();
          tab.items = (payload.stations ?? []).map((station) => ({
            ...station,
            kind: tab.kind,
            search: fold(
              `${station.station_name} ${station.station_id} ${station.river ?? ""} ${station.voivodeship ?? ""}`,
            ),
          }));
        } catch (err) {
          console.error("imgw request failed", err);
          tab.error = document.body.dataset.imgwUnavailable;
        } finally {
          tab.loading = false;
        }
      },

      /* A click on a list box row shows that record below the list. The gauge
       * rows already carry every stored column; a measurement row is only a
       * summary, so its newest observation is read back from the store. */
      pick(event) {
        const tab = this.active;
        const id = event.target.value;
        const station = (tab.items ?? []).find((item) => item.station_id === id) ?? null;
        tab.selected = station;
        tab.detail = station?.kind === "hydro" ? station : null;
        tab.detail_error = "";
        tab.detail_loading = false;
        if (station && station.kind !== "hydro") this.load_detail(tab, station);
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

      format_value(value, unit) {
        if (value === null || value === undefined || value === "") return "—";
        return unit ? `${value} ${unit}` : `${value}`;
      },

      coordinates(place) {
        if (place?.latitude == null || place?.longitude == null) return "—";
        return `${place.latitude}, ${place.longitude}`;
      },

      describe(station) {
        const name = `${station.station_name} (${station.station_id})`;
        const distance = station.distance_km == null ? "" : ` — ${formatDistance(station.distance_km)}`;
        if (station.kind !== "hydro") return `${name} — ${station.last_observed_at}${distance}`;
        const river = station.river ? `${station.river}: ` : "";
        const level = station.water_level_cm == null ? "—" : `${station.water_level_cm} cm`;
        return `${name} — ${river}${level}${distance}`;
      },
    };
  });
});

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

const button = document.getElementById("ping-button");
const pong = document.getElementById("pong");
const messages = document.body.dataset;

button.addEventListener("click", async () => {
  pong.textContent = messages.loading;
  try {
    const response = await fetch("/api/ping", { method: "POST" });
    if (!response.ok) {
      pong.textContent = `${messages.httpError}${response.status}`;
      return;
    }
    const payload = await response.json();
    pong.textContent = payload.status;
  } catch (err) {
    console.error("ping failed", err);
    pong.textContent = messages.connectionError;
  }
});
