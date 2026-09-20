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

/* A place that is a city of the list, so the page can offer to keep it as a
 * favourite. */
function namedPlace(city) {
  return { name: city.name, label: city.name, latitude: city.latitude, longitude: city.longitude, named: true };
}

/* Only a city the user picked by name is remembered: a position fix is never
 * written to storage. */
const last_place_key = "szklana.pogoda:last-place";

/* Keeps the address bar naming the city on show, so copying it shares that
 * city's forecast and the preview a messenger draws for it. Only a city picked
 * by name goes there; a position fix never does, and neither does the nearest
 * city it resolves to, so locating clears the name instead. */
function show_city_in_address(name) {
  try {
    const url = new URL(location.href);
    if (name) url.searchParams.set("city", name);
    else url.searchParams.delete("city");
    history.replaceState(history.state, "", url);
  } catch {
    /* The address is a convenience, like storage: a page that may not rewrite
     * it works the same. */
  }
}

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
    /* `{ name, label, latitude, longitude, named }` for the place on show; `named`
     * means `name` is a city of the list. */
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
    /* The cities this browser keeps, as `{ name, latitude, longitude }`. They
     * live on the server, behind a cookie the first save creates; a browser that
     * never saved one has none, and asking does not give it a cookie. */
    favorites: [],
    saving_favorite: false,

    init() {
      this.load_favorites();
      const named = new URLSearchParams(location.search).get("city");
      if (named) {
        this.open_named(named);
        return;
      }
      this.open_remembered();
    },

    open_remembered() {
      const remembered = this.recall();
      if (!remembered) return;
      this.query = remembered.name;
      this.show_place(remembered);
    },

    favorites_from(payload) {
      return (payload.favorites ?? []).map((city) => ({
        name: city.city_name,
        latitude: city.latitude,
        longitude: city.longitude,
      }));
    },

    /* Favourites are an extra: a list that cannot be fetched leaves the page as
     * it would be without any, and says nothing. */
    async load_favorites() {
      try {
        const response = await fetch("/api/me/favorites");
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        this.favorites = this.favorites_from(await response.json());
      } catch (err) {
        console.error("favourites request failed", err);
      }
    },

    /* Only a place with a city of the list behind it can be kept: the nearest
     * city to a position qualifies, coordinates alone do not. Both spellings are
     * folded, as the server folds them. */
    get is_favorite() {
      if (!this.place?.named) return false;
      const wanted = fold(this.place.name);
      return this.favorites.some((city) => fold(city.name) === wanted);
    },

    get favorite_label() {
      const strings = document.body.dataset;
      return this.is_favorite ? strings.favoriteRemove : strings.favoriteAdd;
    },

    async toggle_favorite() {
      const place = this.place;
      if (!place?.named || this.saving_favorite) return;
      const removing = this.is_favorite;
      this.saving_favorite = true;
      try {
        const response = await fetch(`/api/me/favorites?city=${encodeURIComponent(place.name)}`, {
          method: removing ? "DELETE" : "POST",
        });
        if (!response.ok) {
          this.status =
            response.status === 400 ? document.body.dataset.favoritesFull : document.body.dataset.favoritesUnavailable;
          return;
        }
        this.favorites = this.favorites_from(await response.json());
      } catch (err) {
        console.error("saving a favourite failed", err);
        this.status = document.body.dataset.favoritesUnavailable;
      } finally {
        this.saving_favorite = false;
      }
    },

    /* A link that names a city (`?city=`) opens on it: that is the address a
     * shared link preview points at, and the server has already drawn the
     * preview from the same name. A name the list does not hold, or a list
     * that cannot be fetched, leaves the page as it would be without one. The
     * city is not remembered: opening someone's link is not choosing a place. */
    async open_named(name) {
      const cities = await this.load_cities();
      const wanted = fold(name.trim());
      const city = cities?.find((candidate) => candidate.search === wanted);
      if (!city) {
        this.open_remembered();
        return;
      }
      this.query = city.name;
      this.show_place(namedPlace(city));
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
      const place = namedPlace(city);
      this.remember(place);
      show_city_in_address(city.name);
      this.show_place(place);
    },

    /* The position is asked for on every press. */
    async locate() {
      if (this.locating) return;

      this.locating = true;
      this.status = "";
      const fix = await locateUser();
      if (fix.error) {
        this.status = fix.error;
        this.locating = false;
        return;
      }

      const here = {
        latitude: Number(fix.position.latitude.toFixed(4)),
        longitude: Number(fix.position.longitude.toFixed(4)),
      };
      const cities = await this.load_cities();
      this.locating = false;

      const [nearest] = byDistance(here, cities ?? []);
      this.query = "";
      show_city_in_address(null);
      if (!nearest) {
        this.show_place({ name: `${here.latitude}, ${here.longitude}`, label: `${here.latitude}, ${here.longitude}`, ...here });
        return;
      }
      /* The nearest city is a city of the list like any other, so it can be
       * starred; the forecast still follows the position, and the label says how
       * far that city is. */
      this.show_place({
        ...namedPlace(nearest),
        label: `${document.body.dataset.forecastNearest}: ${nearest.name} (${formatDistance(nearest.distance_km)})`,
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
          return namedPlace(place);
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
