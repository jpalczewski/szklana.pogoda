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
});

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
