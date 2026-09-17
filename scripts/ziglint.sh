#!/usr/bin/env bash
set -euo pipefail

# Runs ziglint (https://github.com/rockorager/ziglint) with this project's
# rule exceptions, so a local run matches CI exactly. `ziglint` itself is not
# installed by this script; see .github/workflows/ci.yml for the pinned
# download this repository builds against.
#
# Ignored rules, and why:
#   Z024 - line length (120 bytes). zig fmt does not wrap lines, and this
#          codebase deliberately keeps long, single-line SQL statements and
#          route tables intact rather than reflowing them across lines.
#   Z023 - parameter order (comptime/Allocator before other parameters).
#          Purely cosmetic; reordering would ripple into every call site for
#          no behavioral gain.
#   Z015/Z012 - "public function exposes private error set/type". False
#          positive on this codebase's `pub const Error = A.Error || error{...}`
#          merged error sets: every flagged set (router.AppError,
#          antistorm.Client.Error, imgw.value.Error, ...) is already `pub`.
#   Z006 - requires snake_case for function-typed `const` bindings such as
#          `routes/api.zig`'s `pub const weatherHistory = ...`. This conflicts
#          directly with zlinter's `declaration_naming` (`decl_that_is_fn`),
#          which this project wires into `zig build lint` and requires
#          camelCase for the same declarations. zlinter's rule wins since it
#          is the one enforced by the build.
#   Z017 - "avoid try in return". `return try expr;` is the idiom Zig's own
#          standard library uses throughout; there is no payload-coercion
#          hazard in the flagged call sites (all return an owned slice as-is).
#   Z026 - "empty catch block suppresses errors", for
#          src/app_log.zig's `writeLine`. That catch guards the logger's own
#          stdout write: `std_options.logFn` routes every `std.log` call back
#          into this file, so logging the failure here would recurse. There is
#          nowhere else to report it, so the line is dropped instead.
exec ziglint \
  --ignore Z024 \
  --ignore Z023 \
  --ignore Z015 \
  --ignore Z012 \
  --ignore Z006 \
  --ignore Z017 \
  --ignore Z026 \
  "$@"
