/* Registers the Alpine components. Each one is a function in its own file,
 * loaded before this one (see the script tags in `index.html.in`); Alpine
 * itself loads last and fires `alpine:init` once all of them are defined. */
document.addEventListener("alpine:init", () => {
  Alpine.data("main_window", main_window);
  Alpine.data("about", about);
  Alpine.data("account", account);
  Alpine.data("imgw", imgw);
  Alpine.data("forecast", forecast);
});
