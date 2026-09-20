/* The about dialog owns the process figures it shows: opening it reads them
 * again, and a dialog left closed never asks the backend for them. */
function about() {
  const base = modal();
  return {
    ...base,
    ...process_memory(),
    show() {
      base.show.call(this);
      this.load();
    },
  };
}

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
