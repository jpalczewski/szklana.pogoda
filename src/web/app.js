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

  Alpine.data("about", () => ({
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
  }));
});

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
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
