# Builds a statically-linked musl binary, then ships it on Alpine rather than
# `scratch`: unlike a stateless relay, this server needs `zoneinfo` for exact
# Europe/Warsaw DST handling (see AGENTS.md; without it the clock falls back to
# a built-in fixed rule, so this stays a correctness nicety, not a hard
# requirement) and a writable path for its SQLite database.
FROM alpine:3.24 AS builder

RUN apk add --no-cache curl xz ca-certificates

ARG ZIG_VERSION=0.16.0
# Pin + verify against https://ziglang.org/download/index.json — check
# before bumping ZIG_VERSION.
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
COPY tools ./tools
# `zig build` fetches zig-sqlite's own dependency, the sqlite.org amalgamation
# zip, as a nested fetch; from a cold cache that fetch fails with "failed to
# create temporary zip file: FileNotFound" because Zig 0.16 doesn't create the
# global cache's tmp/ directory before writing into it. Pre-creating it works
# around the bug (upstream: https://github.com/ziglang/zig, zip fetch path).
RUN mkdir -p /root/.cache/zig/tmp && /opt/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

FROM alpine:3.24
RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S szklana-pogoda \
    && adduser -S -G szklana-pogoda -H -D szklana-pogoda \
    && mkdir -p /data \
    && chown szklana-pogoda:szklana-pogoda /data
COPY --from=builder /src/zig-out/bin/szklana-pogoda /usr/local/bin/szklana-pogoda

USER szklana-pogoda
WORKDIR /data
ENV DATABASE_PATH=/data/weather.db
VOLUME ["/data"]

EXPOSE 8080
# Deliberately no `EXPOSE 9090`: that's the metrics port (see main.zig's
# Config.metrics_port), kept off the published application port so exposing
# 8080 to the internet doesn't also expose request counters and forward
# latency data. Reach it via the container network (e.g. a Prometheus scrape
# target of `<container>:9090`), not a published port.
#
# /api/memory needs no database or network access, so it exercises the HTTP
# server and router without depending on either.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${PORT:-8080}/api/memory" || exit 1

ENTRYPOINT ["/usr/local/bin/szklana-pogoda"]
