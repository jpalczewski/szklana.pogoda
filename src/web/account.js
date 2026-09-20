/* The account dialog. A browser has an account only once it has saved
 * something; this is where that account is carried to another browser (a
 * transfer code), made recoverable (a login code) or entered with a code. A
 * code is a secret: it is shown here and nowhere else, and it is dropped when
 * the dialog closes. */
function account() {
  const base = modal();
  return {
    ...base,
    session: false,
    has_recovery: false,
    /* How many favourites this browser holds, which signing in would join to
     * the account it signs in to: worth saying before it happens. */
    favorites_count: 0,
    /* The transfer code a sign-in link brought, while the person is asked
     * whether to use it. It is never used without that. */
    pending: "",
    /* `{ code, until }` with `until` in milliseconds. */
    transfer: null,
    /* The address that signs a browser in with the transfer code, and its QR
     * code as `{ side, view_box, path }`. Both are secrets exactly as the code
     * is, and go with it. */
    link: "",
    qr: null,
    recovery: "",
    remaining: 0,
    timer: null,
    code: "",
    busy: false,
    message: "",
    failed: false,
    clipboard: Boolean(navigator.clipboard?.writeText),

    init() {
      arrival_ready.then((code) => {
        if (code) this.arrive(code);
      });
    },

    /* A link pasted into a tab that already shows this page does not reload it:
     * the browser only changes the fragment and says `hashchange`. */
    arrive_from_address() {
      const code = take_arrival_code();
      if (code) this.arrive(code);
    },

    show() {
      base.show.call(this);
      this.message = "";
      this.load();
      if (this.pending) this.focus_cancel();
    },

    /* Asked whether to sign in, the safe answer has the focus. A browser that
     * follows a link to a fragment moves the focus to the page after the event
     * that opened the dialog, so it is set again a moment later. */
    focus_cancel() {
      const focus = () => {
        if (this.open && this.pending) this.$refs.cancel?.focus();
      };
      this.$nextTick(focus);
      setTimeout(focus, 100);
    },

    hide() {
      if (!this.open) return;
      base.hide.call(this);
      this.forget();
    },

    /* What is on screen only while the dialog is open. */
    forget() {
      this.drop_transfer();
      this.recovery = "";
      this.code = "";
      this.pending = "";
    },

    /* Someone opened a sign-in link. Nothing happens until they say so: a link
     * is easy to send, and one made from somebody else's code would put this
     * browser's favourites into that account. */
    arrive(code) {
      this.pending = code;
      this.show();
    },

    cancel_arrival() {
      this.hide();
    },

    confirm_arrival() {
      this.redeem(this.pending, true);
    },

    /* The transfer code and everything made from it leave the screen together. */
    drop_transfer() {
      this.transfer = null;
      this.link = "";
      this.qr = null;
      this.stop_timer();
    },

    async load() {
      try {
        const [me, favorites] = await Promise.all([fetch("/api/me"), fetch("/api/me/favorites")]);
        if (!me.ok || !favorites.ok) throw new Error(`HTTP ${me.status}/${favorites.status}`);
        const status = await me.json();
        this.session = status.session;
        this.has_recovery = status.has_recovery;
        this.favorites_count = (await favorites.json()).favorites.length;
      } catch (err) {
        console.error("account request failed", err);
        this.tell(document.body.dataset.accountUnavailable, true);
      }
    },

    tell(text, failed = false) {
      this.message = text;
      this.failed = failed;
    },

    /* Sends a request that changes state. The body, when there is one, is JSON:
     * the server refuses anything else. A code is only ever sent this way and
     * never in an address. */
    async send(method, path, body) {
      const options = { method };
      if (body !== undefined) {
        options.headers = { "Content-Type": "application/json" };
        options.body = JSON.stringify(body);
      }
      const response = await fetch(path, options);
      return { ok: response.ok, status: response.status, data: response.ok ? await response.json() : null };
    },

    failure(status) {
      const strings = document.body.dataset;
      if (status === 401) return strings.accountInvalid;
      if (status === 429) return strings.accountLimited;
      return strings.accountUnavailable;
    },

    async show_transfer() {
      if (this.busy) return;
      this.busy = true;
      this.message = "";
      try {
        const result = await this.send("POST", "/api/me/transfer-code");
        if (!result.ok) {
          this.tell(this.failure(result.status), true);
          return;
        }
        this.transfer = { code: result.data.code, until: Date.now() + result.data.expires_in_seconds * 1000 };
        this.link = sign_in_link(result.data.code);
        this.qr = qr_code(this.link);
        this.start_timer();
      } catch (err) {
        console.error("transfer code request failed", err);
        this.tell(document.body.dataset.accountUnavailable, true);
      } finally {
        this.busy = false;
      }
    },

    start_timer() {
      this.stop_timer();
      this.tick();
      this.timer = setInterval(() => this.tick(), 1000);
    },

    stop_timer() {
      if (this.timer !== null) clearInterval(this.timer);
      this.timer = null;
    },

    /* A code that has run out is taken off the screen, since it no longer works. */
    tick() {
      this.remaining = Math.max(0, Math.ceil(((this.transfer?.until ?? 0) - Date.now()) / 1000));
      if (this.remaining === 0) this.drop_transfer();
    },

    get remaining_text() {
      const minutes = Math.floor(this.remaining / 60);
      const seconds = String(this.remaining % 60).padStart(2, "0");
      return `${minutes}:${seconds}`;
    },

    async make_recovery() {
      if (this.busy) return;
      this.busy = true;
      this.message = "";
      try {
        const result = await this.send("POST", "/api/me/recovery-code");
        if (!result.ok) {
          this.tell(this.failure(result.status), true);
          return;
        }
        this.recovery = result.data.code;
        this.has_recovery = true;
      } catch (err) {
        console.error("login code request failed", err);
        this.tell(document.body.dataset.accountUnavailable, true);
      } finally {
        this.busy = false;
      }
    },

    /* The code typed into the field. */
    sign_in() {
      return this.redeem(this.code.trim(), false);
    },

    /* Signs in with `code`. A code that came from a link is dropped when the
     * server says it is no good: it cannot become good again, and the typed
     * form is what is left. */
    async redeem(code, from_link) {
      if (this.busy || code === "") return;
      this.busy = true;
      this.message = "";
      try {
        const result = await this.send("POST", "/api/me/login", { code });
        if (!result.ok) {
          if (from_link && result.status === 401) this.pending = "";
          this.tell(this.failure(result.status), true);
          return;
        }
        const strings = document.body.dataset;
        this.forget();
        await this.load();
        this.tell(result.data.merged ? strings.accountSigninDoneMerged : strings.accountSigninDone);
        window.dispatchEvent(new CustomEvent("account-changed"));
      } catch (err) {
        console.error("sign-in request failed", err);
        this.tell(document.body.dataset.accountUnavailable, true);
      } finally {
        this.busy = false;
      }
    },

    async sign_out() {
      if (this.busy) return;
      this.busy = true;
      this.message = "";
      try {
        const result = await this.send("DELETE", "/api/me/session");
        if (!result.ok) {
          this.tell(this.failure(result.status), true);
          return;
        }
        this.forget();
        await this.load();
        window.dispatchEvent(new CustomEvent("account-changed"));
      } catch (err) {
        console.error("sign-out request failed", err);
        this.tell(document.body.dataset.accountUnavailable, true);
      } finally {
        this.busy = false;
      }
    },

    /* A convenience: a code that cannot be copied is still on screen to read. */
    async copy(text) {
      try {
        await navigator.clipboard.writeText(text);
        this.tell(document.body.dataset.accountCopied);
      } catch {
        /* Clipboard access can be refused; the code stays visible. */
      }
    },
  };
}

/* The address another browser opens to sign in with a transfer code. The code
 * is in the fragment, which a browser never sends to the server, so it is in
 * neither the access log nor a `Referer`. The path keeps the page's language. */
function sign_in_link(code) {
  return `${location.origin}${location.pathname}#code=${code.replaceAll("-", "")}`;
}

/* A QR code for `text` as what an inline SVG needs: its side in modules, a
 * `viewBox` and one path of the dark modules, with the four-module quiet zone the
 * standard asks for. Runs of dark modules in a row are one segment, which keeps
 * the path short. Null when the library is not there or the text does not fit,
 * and the caller then shows the code as text alone. */
function qr_code(text) {
  if (typeof qrcodegen === "undefined") return null;
  let symbol;
  try {
    symbol = qrcodegen.QrCode.encodeText(text, qrcodegen.QrCode.Ecc.MEDIUM);
  } catch (err) {
    console.error("QR code failed", err);
    return null;
  }
  const border = 4;
  const segments = [];
  for (let y = 0; y < symbol.size; y++) {
    let x = 0;
    while (x < symbol.size) {
      if (!symbol.getModule(x, y)) {
        x++;
        continue;
      }
      const start = x;
      while (x < symbol.size && symbol.getModule(x, y)) x++;
      segments.push(`M${start + border} ${y + border}h${x - start}v1h-${x - start}z`);
    }
  }
  const side = symbol.size + 2 * border;
  return { side, view_box: `0 0 ${side} ${side}`, path: segments.join("") };
}
