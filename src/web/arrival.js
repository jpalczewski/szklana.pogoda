/* A sign-in link (`/#code=ABCDE12345`, made by `sign_in_link`) carries a transfer
 * code in its fragment. It is taken out of the address the moment this script
 * runs (or, in a tab that already shows the page, the moment the fragment
 * changes), before anything can read, copy or share the address, and it is kept
 * in memory only. Only the ten characters of a transfer code count: a login code is
 * permanent and must never work as a link. A page that is only being prerendered
 * is not being looked at, so it waits until it is shown. */
const arrival_ready = document.prerendering
  ? new Promise((resolve) => document.addEventListener("prerenderingchange", resolve, { once: true })).then(take_arrival_code)
  : Promise.resolve(take_arrival_code());

function take_arrival_code() {
  const fragment = location.hash;
  if (!fragment.startsWith("#code=")) return null;
  try {
    history.replaceState(history.state, "", location.pathname + location.search);
  } catch {
    /* The address is a convenience; the code is used all the same. */
  }
  return /^#code=([0-9A-Za-z]{10})$/.exec(fragment)?.[1] ?? null;
}
