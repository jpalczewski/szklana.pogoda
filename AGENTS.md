# Repository Guidelines

## Project Structure & Module Organization

This is a small Zig HTTP server. Application startup, environment-based configuration, listener setup, and the route table live in `src/main.zig`. Keep HTTP transport concerns in `src/server.zig`; it converts `std.http` requests into application-level request contexts and writes responses.

Routing primitives (`Route`, `RequestContext`, `Response`, errors, and bounded request bodies) belong in `src/router.zig`. Put endpoint handlers in `src/routes/`: use `api.zig` for `/api/*` handlers and `pages.zig` for HTML or static assets. Browser assets are embedded at build time from `src/web/`.

Add a route by creating a handler with the `router.Handler` signature and registering it in the `routes` array in `src/main.zig`. Keep route matching exact; do not introduce path parameters or wildcard routing without a concrete use case.

## Build, Test, and Development Commands

- `zig build` — compile the `szklana-pogoda` executable into `zig-out/bin/`.
- `zig build test` — run unit tests, including router and request-body behavior.
- `zig build run` — build and start the server on `0.0.0.0:8080`.
- `PORT=18080 zig build run` — run on an alternate local port.
- `zig fmt src` — format all Zig sources after edits.

The server accepts `HOST`, `PORT`, `MAX_BODY_BYTES`, and `MAX_CONNECTIONS_PER_CPU` environment variables. `HOST` currently expects an IPv4 address.

## Coding Style & Naming Conventions

Use `zig fmt`; do not hand-maintain formatting. Follow Zig conventions: four-space indentation, `snake_case` for functions and local variables, `PascalCase` for types, and lowercase filenames such as `routes/api.zig`.

Keep handlers small and return `router.Response` instead of writing directly to `std.http`. API responses and API errors use JSON; non-API missing routes use `text/plain`. Request body reads must go through `RequestContext.body` so `MAX_BODY_BYTES` remains enforced.

## Design Preference

Favor elegant, extensible designs: make the next endpoint or service easy to add through a clear interface, a small module, and explicit wiring. Prefer simple, composable abstractions over one-off conditionals, while avoiding speculative frameworks or features that no current requirement needs.

## Testing Guidelines

Place focused Zig `test "description"` blocks near the router or behavior they cover. Cover successful routing, query-string handling, method mismatches (`405` plus `Allow`), API error formats, and body-limit failures. Run `zig build test` before handing off a change. For route-contract changes, also smoke-test with `curl` against `zig build run`.

## Commit & Pull Request Guidelines

Use concise imperative commit subjects, matching existing history: `Add weather endpoint`, `Handle malformed requests`, or `Restyle with 98.css`. Keep each commit scoped to one coherent change.

Pull requests should explain the behavioral change, list test commands run, and call out API contract or environment-variable changes. Include a screenshot for visible frontend changes and link the relevant issue when one exists.
