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

/* The places that have a position, each with its `distance_km` from the user,
 * nearest first. */
function byDistance(from, places) {
  return places
    .map((place) => ({ ...place, distance_km: distanceKm(from, place) }))
    .filter((place) => place.distance_km != null)
    .sort((a, b) => a.distance_km - b.distance_km);
}

/* Asks the browser where the user is: `{ position }` on success, or `{ error }`
 * with the message to show. An explicitly refused position deserves a different
 * message from one the browser could not determine. The browser's own cache
 * (`maximumAge`) keeps repeated asks from prompting or waiting each time. */
async function locateUser() {
  const strings = document.body.dataset;
  if (!navigator.geolocation) return { error: strings.locationUnavailable };
  try {
    const position = await new Promise((resolve, reject) =>
      navigator.geolocation.getCurrentPosition(resolve, reject, {
        enableHighAccuracy: false,
        timeout: 10000,
        maximumAge: 600000,
      }),
    );
    return { position: { latitude: position.coords.latitude, longitude: position.coords.longitude } };
  } catch (error) {
    return { error: error.code === permission_denied ? strings.locationDenied : strings.locationUnavailable };
  }
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
