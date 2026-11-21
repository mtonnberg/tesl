# friction-fixes.md — working log for the FRICTION.md pass

Source: `FRICTION.md` (a downstream Tesl user's spike log, sections §1–§62,
written against pin `7dc0379`, 12 perf-only commits behind `main` at the start
of this branch). Branch: `friction-fixes`.

Rules for this pass (from the maintainer):

- Re-verify every item against HEAD before touching it; confirm it should be
  fixed; look for the bug *class* and fix the class where one exists.
- Write tests continuously (Tesl `test`/`api-test`, OCaml should-not-compile,
  Go runtime tests).
- Keep the language's integrity; avoid new language surface unless strictly
  necessary.
- §49 (one-module floor): maintainer disputes it — entities can (must, due to
  migrations) live elsewhere. Not worked as a bug; re-checked only.
- §57 (`let` body on next line): deferred — parser can of worms.
- §2/§3/§53 (LEFT JOIN / LATERAL / `->>`): investigate only, carefully.
- By design / won't fix: Tesl owns its database (§7, §45, §14 for foreign
  indexes, §42/§26 external writers, §27/§8 memory backend has no outbox).

Sizes: S < 1 day, M = days, L = week+.

## Triage table (initial, before re-verification)

### 1. `tesl check` passes, then the Go build fails (one root class)

| § | Issue | Relevance | Size |
|---|---|---|---|
| 56 | `Maybe` field in a request body: check clean, Go build fails `undefined: DecodeMaybeJSON`; compiler's own hint (`with_codec Maybe`) is the broken spelling | High | S–M |
| 60 | Nested record / `List Record` in request body: `undefined: Decode<Record>JSON` | High | S–M |
| 33 | `Maybe` from `case`/`if` takes Go type from first branch (`Maybe[struct{}]`); `let` annotation ignored | High | S–M |
| 37 | `api-test … for Server` in another module: `undefined: RunsServer` | High | M |
| 36 | `PosixMillis` field from `Int` literal in seed: "unsupported value type"; no usable ctor / `millisToPosix` | Med | S |
| 61 | `Int.toFloat` in spec but not on Go backend | Med | S |
| — | Class fix: Go emission/type-check reachable from `check`/CI so these cannot pass `check` again | High | M |

### 2. Generated Elm client (`tesl generate elm`)

| § | Issue | Relevance | Size |
|---|---|---|---|
| 39 / 21.8 | Elm decoders expect bare `null`; runtime sends `{"tag":…}`. `D.maybe` silently drops populated values | High | S (tied to §13) |
| 21.5 | `Maybe` field encoder mis-parenthesized (Elm type error) | High | S |
| 62 | `Int` path capture appended without `String.fromInt` | Med | S |
| 59 | `check` calling a named predicate makes client import never-generated `ApiHelpers.elm` | Med | M |
| 21.1 | `module App` hardcoded, no `--module` | Med | S |
| 21.2 | `--out` dir not created | Low | S |
| 21.6 | No SSE fns, no auth/header param on request fns | Med | M–L |
| 21.3 / 21.4 | `elm/json` + `refinement-proofs` must be direct deps (docs) | Low | S |
| — | Class fix: CI `elm make` on generated clients from a corpus | High | M |

### 3. Wire format / JSON

| § | Issue | Relevance | Size |
|---|---|---|---|
| 13 | `Maybe` always serializes as ADT envelope, never `null`/value; no `maybeCodec`, no `codec (Maybe X)` | High | M–L (breaking wire change) |
| 1 | jsonb: crash fixed on Go. Remaining: no raw-JSON passthrough, no flat-tag codec | Med | M |
| 52 | Memory backend returns jsonb verbatim, Postgres normalizes — `api-test` byte comparisons lie | Low–Med | S |
| 17 | No base64/hex encode/decode for arbitrary `String`/`Bytes` | Med | S |

### 4. SQL / `select` expressiveness

| § | Issue | Relevance | Size |
|---|---|---|---|
| 16 | `List.sortBy` with `Tuple2` key is a silent no-op (re-verify on Go) | High | S |
| 16 | `A \|\| (B && C)` in `where` doesn't lower | Med–High | M |
| 15 / 5 | `limit` only accepts a literal | Med–High | S–M |
| 54 | `inList` needs a literal list (#114) | Med–High | M |
| 2 / 3 / 53 | No `LEFT JOIN`, `LATERAL`, `->>` (investigate only) | Med | L |
| 16 | No `<`/`>` on `String` though `sortBy` orders strings | Low–Med (design) | S |
| 47 | Multi-line `upsert` (spec's own example) rejected; misleading cascaded capability error | Med | S–M |
| 4 | `Int32` needs explicit `@db(integer)` despite spec table | Low–Med | S |

### 5. Routing / auth / SSE

| § | Issue | Relevance | Size |
|---|---|---|---|
| 22.1 | Second `auth` line on an endpoint silently ignored (security) | High | S |
| 32 | `get "/runs/:id"` shadows `sse "/runs/stream"` even when declared first | High | S–M |
| 23.1 | Zero-binding `sseChannel` compiles but never delivers | Med | S |
| 24 | No constant-time string/bytes equality in stdlib | Med (security) | S |
| 28 / 31 | SSE: no replay, no `ready` frame, no 503 subscriber cap, no named `event:` frames, heartbeat not configurable | Med | M–L |
| 48 | `sso` config read lazily: missing var at boot = panic not diagnostic; env needed by `tesl test` depends on import graph | Med | S–M |
| 46 | OIDC issuer: slash stripped for URL, not for comparison; error hides both values | Low | S |
| 44 | SSRF guard has no knob for private-network egress | Med (security design) | S–M |
| 25 | Browser `EventSource` can't send headers (docs) | Low | S |

### 6. Test harness (`api-test` / `tesl test`)

| § | Issue | Relevance | Size |
|---|---|---|---|
| 43 | `publicOrigin` → every `api-test` 421s on Host validation | High | S |
| 43 | Failed expectation message lacks actual status | Med | S |
| 34 | `subscribe … headers {}` parses, headers silently dropped | Med | S |
| 22.2 | `tesl test` ignores `tesl.toml` `[env]` | Med | S |
| 23.4 | `subscribe` auth failure aborts test, no expect-error | Med | M |
| 23.3 | `publish` not callable in test body | Low–Med | S–M |
| 19 | `x[0].field` leaks into next dot-access (re-verify on Go) | Med | S |
| 12 | Populated `Maybe <newtype>` read crash (re-verify on Go) | High if live | S |
| 55 | No coverage; `--mutate` lacks wiring for local module | Med | M |

### 7. Language ergonomics

| § | Issue | Relevance | Size |
|---|---|---|---|
| 57 | `let` body can't start on next line (DEFERRED) | Med–High | M |
| 49 | One-module floor (DISPUTED by maintainer) | — | — |
| 58 | No `isNothing`/`isSomething` | Low | S |
| 20 | W050 flags import used only by `api-test … for Server` | Low–Med | S |

### 8. Packaging / toolchain / CLI

| § | Issue | Relevance | Size |
|---|---|---|---|
| 40 / 50 | CLI closure pulls ~950 MiB DAST; `zap` Linux-only → no Apple Silicon install | High | M |
| 41 | Flake has no offline Go module cache; cgo default on | Med–High | M |
| 38 | Nix sandbox: test unix socket path > 108 bytes | Med | S |
| 11 | `tesl init /abs/path` creates `./abs/path`, false success | Med | S |
| 35 | Compiled binary has no healthcheck subcommand (distroless) | Med | S–M |
| 51 | Tesl's own `tesl_pubsub_outbox` not migrated across versions | Med–High | S–M |
| 30 | Orphaned `racket` on kill (Racket-only, likely obsolete) | Low | — |

### 9. By design / won't fix

| § | Issue | Note |
|---|---|---|
| 7 / 45 | `existing` mode creates tables / shadow schema / `tesl_*`; `tesl db start` ignores mode | By design (Tesl owns its DB) |
| 14 | W092 blind to foreign indexes | By design |
| 42 / 26 | Outbox columns/payload changed under external C# writer | Internal table, not public contract |
| 27 / 8 | Memory backend has no outbox / LISTEN | By design |
| 4 (varchar), 18 | — | Already fixed upstream |

### 10. Project-specific / not actionable

§9, §29, most of §30, Aspire half of §44, §10/§20 positives.

## Progress log

Status legend: ✅ fixed · 🟰 already fixed / not reproducible at HEAD ·
🚫 won't fix (reason) · ⏸ deferred · 🔍 investigated.

| § | Status | Verified at HEAD? | Class / root cause | Fix + tests | Commit |
|---|---|---|---|---|---|
| 60 | 🟰 | yes — nested record / `List Record` body decodes and runs | — | probe passes at HEAD | — |
| 54 | 🟰 | yes — `where inList t.id ids` with a variable list runs correctly | (#114 landed) | — | — |
| 16 (String `<` in `where`) | 🟰 | yes — `where t.id < c` compiles and filters | — | — | — |
| 16 (String `<` in values) | 🚫 | — | deliberate: lesson43 "String has no total order in Tesl" | — | — |
| 12 | 🟰 | yes — populated `Maybe PosixMillis` entity field reads back | Racket-only | — | — |
| 23.1 | 🟰 | yes — zero-binding `sseChannel` delivers on Go | Racket-only (user's repro was also hit by §32) | — | — |
| 20 | 🟰 | yes — W050 no longer flags the server import | — | — | — |
| 11 | 🟰 | yes — absolute path works; missing parent is a clear error | — | — | — |
| 24 | 🟰 | yes — `Secret` `==` is constant-time (`requireSecret` + `Secret header`); `Tesl.Proxy.verifyBinding` too | docs only | — | — |
| 18, 4 (varchar) | 🟰 | upstream already | — | — | — |
| class: check/emit gap | ✅ | yes — `tesl check` was clean on programs the Go emitter then refused | Two gates: frontend judged, emitter refused later. Go is the sole backend, so an emitter refusal is a property of the program | `check`, `--check-json`, `--check-batch`, `agent-context` now run the emitter for a program ENTRY (a module declaring `main() -> App` or any test block). Libraries are judged through their entries; migration/schema modules are skipped. Running this over the compiler's own tests surfaced ~20 emitter gaps, fixed below. OCaml: `test_friction_fixes` (check-emit-gap) | batch 1 |
| 33 | ✅ | yes — `Maybe[struct{}]` Go build error | Branch type merge took the first arm's (anonymous) reading; `let x: T =` annotation ignored | case/if merge anonymous type args across arms (`merge_anon`); `let` annotations lower to the binding type. `tests/friction-fixes-tests.tesl` (break-it verified on baseline) | batch 1 |
| 37 | ✅ | yes — `undefined: RunsServer` | api-test server name emitted unqualified | modules export their servers (`ex_servers`); api-test/load-test qualify by owner package. `tests/friction-cross-module-{app,tests}.tesl` | batch 1 |
| 32 | ✅ | yes — also in the harness; `subscribe` silently "succeeded" on the JSON route | Router took first declared match | Most-specific route wins (literal segment beats `:capture`, any order); `subscribe` now refuses a non-`text/event-stream` answer. Go unit tests + Tesl test | batch 1 |
| 34 | ✅ | yes — headers parsed then dropped | emitter scanned only `cookie` for subscribe | `subscribe … headers {}` sends headers (shared renderer with request verbs). Go unit test + Tesl test | batch 1 |
| 43 | ✅ | yes | harness sent no Host | api-test request/subscribe with no Host is addressed to `publicOrigin`; explicit Host kept (421 still testable). lesson80 updated (no `onHost()` boilerplate, new 421 test) | batch 1 |
| 22.1 | ✅ | yes — second `auth` silently replaced first (security) | endpoint clauses are single slots, overwritten | duplicate `auth`/`body`/`response` clause is a parse error with a remedy | batch 1 |
| 36 | ✅ | yes | seed blocks were scope-checked, never type-checked (spec says typed) | seed inserts are type-inferred; Int-for-PosixMillis hint now says how to BUILD one (`addMs (Time.secondsToPosix 0) ms`). No new `millisToPosix` (avoid surface; spec documents the path) | batch 1 |
| 47 | ✅ | yes | multi-line `upsert` never merged; same family: multi-line `delete … \n where` orphaned its `where` (head line was already a complete delete-ALL query) | `Sql_query` joins multi-line upsert; delete head read back out of its node. Tesl test asserts rows | batch 1 |
| 20 | ✅ | partly live — server-only import, and `capture … using codec` | linter missed both references | W050 credits `api-test … for S` and inline capture codec/check | batch 1 |
| 21.5 | ✅ | yes | `(Maybe.withDefault E.null (Maybe.map f)) v` | `Maybe.withDefault E.null (Maybe.map f v)` | batch 1 |
| emitter gaps (from class fix) | ✅ | — | bare nullary fn/stdlib value (`pi`, `nowMillis`); zero-arg lambda `f()`; type var named like a param; irrefutable case over record/list; `import Tesl.X` (no list) qualified calls; local ctor shadowing unexposed builtin/imported ctor; `Something True` patterns; newtype path captures; tail `update … returning one` in Unit fn | `tests/friction-emitter-gaps-tests.tesl` runs each | batch 1 |
