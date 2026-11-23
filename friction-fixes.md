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
| class: check/emit gap | ✅ | yes — `tesl check` was clean on programs the Go emitter then refused | Two gates: frontend judged, emitter refused later. Go is the sole backend, so an emitter refusal is a property of the program | `check`, `--check-json`, `--check-batch`, `agent-context` now run the emitter for a program ENTRY (a module declaring `main() -> App` or any test block). Libraries are judged through their entries; migration/schema modules are skipped. Running this over the compiler's own tests surfaced ~20 emitter gaps, fixed below. OCaml: `test_check_backend_regressions` (check-emit-gap) | batch 1 |
| 33 | ✅ | yes — `Maybe[struct{}]` Go build error | Branch type merge took the first arm's (anonymous) reading; `let x: T =` annotation ignored | case/if merge anonymous type args across arms (`merge_anon`); `let` annotations lower to the binding type. `tests/api-boundary-regression-tests.tesl` (break-it verified on baseline) | batch 1 |
| 37 | ✅ | yes — `undefined: RunsServer` | api-test server name emitted unqualified | modules export their servers (`ex_servers`); api-test/load-test qualify by owner package. `tests/cross-module-api-test-{app,tests}.tesl` | batch 1 |
| 32 | ✅ | yes — also in the harness; `subscribe` silently "succeeded" on the JSON route | Router took first declared match | Most-specific route wins (literal segment beats `:capture`, any order); `subscribe` now refuses a non-`text/event-stream` answer. Go unit tests + Tesl test | batch 1 |
| 34 | ✅ | yes — headers parsed then dropped | emitter scanned only `cookie` for subscribe | `subscribe … headers {}` sends headers (shared renderer with request verbs). Go unit test + Tesl test | batch 1 |
| 43 | ✅ | yes | harness sent no Host | api-test request/subscribe with no Host is addressed to `publicOrigin`; explicit Host kept (421 still testable). lesson80 updated (no `onHost()` boilerplate, new 421 test) | batch 1 |
| 22.1 | ✅ | yes — second `auth` silently replaced first (security) | endpoint clauses are single slots, overwritten | duplicate `auth`/`body`/`response` clause is a parse error with a remedy | batch 1 |
| 36 | ✅ | yes | seed blocks were scope-checked, never type-checked (spec says typed) | seed inserts are type-inferred; Int-for-PosixMillis hint now says how to BUILD one (`addMs (Time.secondsToPosix 0) ms`). No new `millisToPosix` (avoid surface; spec documents the path) | batch 1 |
| 47 | ✅ | yes | multi-line `upsert` never merged; same family: multi-line `delete … \n where` orphaned its `where` (head line was already a complete delete-ALL query) | `Sql_query` joins multi-line upsert; delete head read back out of its node. Tesl test asserts rows | batch 1 |
| 20 | ✅ | partly live — server-only import, and `capture … using codec` | linter missed both references | W050 credits `api-test … for S` and inline capture codec/check | batch 1 |
| 21.5 | ✅ | yes | `(Maybe.withDefault E.null (Maybe.map f)) v` | `Maybe.withDefault E.null (Maybe.map f v)` | batch 1 |
| emitter gaps (from class fix) | ✅ | — | bare nullary fn/stdlib value (`pi`, `nowMillis`); zero-arg lambda `f()`; type var named like a param; irrefutable case over record/list; `import Tesl.X` (no list) qualified calls; local ctor shadowing unexposed builtin/imported ctor; `Something True` patterns; newtype path captures; tail `update … returning one` in Unit fn | `tests/go-emitter-gap-tests.tesl` runs each | batch 1 |
| 13 | ✅ | yes — runtime sent `{"tag":…}` for `Maybe` while OpenAPI/TS/Elm all declared `null`/value | Runtime vs every client artifact disagreed on one type's wire shape | DECISION: on the HTTP wire (bodies, SSE payloads, tool results, api-test templates) `Maybe T` is `null` or the bare value; stored JSON (JSONB, queue, cache) keeps the envelope; decoders accept both. `Maybe (Maybe T)` keeps the envelope at its outer level. Spec documents it. Go unit tests + Tesl probes | batch 2 |
| 56 | ✅ | yes — check now refused it (batch 1), runtime had no decoder | Derived decoder lacked `Maybe`; `with_codec Maybe` called an undefined `DecodeMaybeJSON` | Derived records decode `Maybe` (absent/null/value/envelope; absent keys allowed); `with_codec Maybe` reads/writes the wire shape | batch 2 |
| 39 / 21.8 | ✅ | yes | see 13; also `D.maybe` swallowed decode failures | runtime now sends `null`; Elm uses strict `D.nullable` | batch 2 |
| class: client/runtime wire drift | ✅ | Result/Either/Tuple: runtime `{"tag","fields":{…}}`, clients/OpenAPI flat `{"tag","value"}` and JSON arrays | three generators drifted from the runtime's documented ADT rule | Elm/TS/OpenAPI describe the runtime envelope (TS keeps tuple TYPES and transforms in zod; Elm decodes into native tuples/Result). Runtime unchanged (no storage impact) | batch 2 |
| class: Elm clients don't compile | ✅ | 71/76 corpus clients failed `elm make` (mostly gate setup; 6 real bugs) | nothing compiled generated Elm | new `tests/elm-client-compile.sh` + ci.sh phase 4a2; fixed: Int/newtype path segments (62), `.csv`-style route names (Elm+TS), duplicate functions across two `api`s, generic ADT params, fact field decoder reused at the wrong base type. All 76 compile | batch 2 |
| 62 | ✅ | yes | URL builder appended non-String captures | segments rendered via `String.fromInt`/`fromFloat` through newtype aliases | batch 2 |
| 59 | ✅ (partly by design) | yes | helper-calling checks always delegated to ApiHelpers | a helper whose body is translatable is read through (same smart constructor as inline). Non-translatable helpers still delegate — documented ApiHelpers design (#13) | batch 2 |
| 21.1 | 🟰 | module name is the Tesl module name, or inferred from `--out …/src/…` | user's module was literally `App` | — | — |
| 21.2 | ✅ | yes | — | `--out` creates its parent directory (elm/ts/ir) | batch 2 |
| api-test JSON vs Maybe/record | ✅ | `expect r.body.x == Nothing` refused; two copies of the comparison rule | — | one shared `api_json_comparand`; any wire-encodable value compares; `!=` too | batch 2 |

## Investigation: LEFT JOIN / LATERAL / `->>` (§2, §3, §53) — not built

What exists today: `innerJoin E on a.f E.g` lowers to an `EXISTS (select 1 from E where …)`
semi-join (`emit_go.ml` `sql_join_exists`). It filters the main entity's rows; it returns no
columns of the joined entity. A `select` always yields rows of ONE entity.

- **LEFT JOIN** as a filter is meaningless (it keeps every row). Its value is the joined
  columns, which needs a projection result type — e.g. `select (r, s) from Run leftJoin State
  on …` yielding `List (Tuple2 Run (Maybe State))`. That is new surface across the parser,
  checker (row typing, nullability of the joined side, FromDb provenance for TWO subjects), the
  memory store (a real join) and the SQL emitter, plus index lint and migrations' row-access
  rules. Large, and it touches the proof story (which facts does the joined row carry?).
- **LATERAL** ("the earliest `started` event per run") additionally needs ordering + limit
  inside a correlated subquery; strictly larger than LEFT JOIN.
- **`->>`** reads into a JSONB value the type system treats as an opaque string; typed access
  would need a JSON path type and a decision about which JSON shapes are trusted. Today a JSONB
  column holding a Tesl ADT is already typed — `->>` is only needed for foreign JSON.

Recommendation: keep these out for now. The two shapes the user actually needed are covered:
1. **Batching (no N+1):** `inList` with a runtime list now works (verified at HEAD), so a page
   is 1 query + 1 per related entity (`select s from State where inList s.runId runIds`) joined
   in memory with `Dict` — constant query count per page, no new surface.
2. **Database views** mapped by an entity remain the right tool when SQL already expresses the
   projection (only possible where the schema is managed outside Tesl; Tesl's own migrations
   do not create views).
If LEFT JOIN is wanted later, the minimal sound design is the tuple-projection select above,
with the joined side always `Maybe` and FromDb provenance attached only to the main entity.
| 15 | ✅ | yes | `limit`/`offset` only parsed integer literals | `sql_bound = BoundLiteral \| BoundExpr`; expression bound is a `$n` parameter via `teslrt.SqlBound` (negative → nothing, saturating); checker types it Int. Verified on real PostgreSQL (`limit $1 offset $2`) and memory store | batch 2 |
| 16 (OR of AND) | ✅ | yes | `SqlOr` held only atoms | new `SqlAnd` group under `SqlOr` handled at every clause site (checker, validation, capabilities provenance all-or-nothing, index lint, codec validation, Go predicate, SQL text); nested `\|\|` flattens. Verified on PostgreSQL | batch 2 |
| 16 (tuple sortBy) | ✅ | yes — Go refused at emit (no longer silent on Go) | sort key had to be a scalar | Tuple2/Tuple3 keys of ordered components sort lexicographically (keys computed once per comparison); `<` on tuples still refused | batch 2 |
| 61 | ✅ (scalar part) | yes | `go_backend_unavailable_exports` listed documented functions Go never implemented | implemented `Int.toFloat/fromFloat/digits/isZero/isPositive/isNegative`, `String.trimLeft/trimRight/words/lines/toFloat/fromFloat`. Still unavailable: Dict/Set/List higher-order helpers (`Dict.map`, `List.findIndex`, …), `int32Codec`, `uuidV4/V7Codec`, legacy `Email.send` | batch 2 |
| 22.2 | ✅ | yes | `tesl test`/`run` read `.env` (written once by `tesl init`) but not `tesl.toml [env]` | manifest [env] is the lowest-precedence source (process env > .env > [env]); `TESL_NO_DOTENV=1` disables both. Go CLI test | batch 2 |
| 58 | ✅ (hint, no new surface) | yes | — | `isNothing`/`isSomething`/`isJust`/`isNone`/`isSome` → targeted hint (`m == Nothing`) | batch 2 |
| 38 | ✅ | yes (path-length class) | sockets under `t.TempDir()` exceed sockaddr_un in nix sandbox | `shortSocketDir` test helper (prefers `/tmp`) in teslrt + tesl-debug-attach debug tests | batch 2 |
| 40 / 50 | ✅ | yes — darwin default failed to evaluate at baseline | CLI wrappers wrote `${pkgs.zap}`/`${pkgs.nuclei}` into their script, making DAST tools CLI runtime deps | removed from CLI preamble; scanners found next to the CLI in the profile bin (tesl-full ships them where available) or PATH; `TESL_ZAP/NUCLEI` still override. `nix eval .#packages.aarch64-darwin.{default,tesl-native-cli}` now evaluates | batch 2 |
| 44 | 🚫 by design | — | resolved-address SSRF containment with one dev escape and a ratchet against new ones (ensure_sso_works.md risks 5/30/47) | no private-range knob; supported topology is loopback + TLS | — |
| 2 / 3 / 53 | 🔍 | see investigation section | — | not built; batching via runtime `inList` covers the N+1 case | — |
| 51 | ✅ | yes — listener looped forever on a table from an older runtime | outbox bootstrap only `add column if not exists` for the dispatch columns; legacy `channel_name`/`channel_key` never renamed, so `column "channel" does not exist` looped while the app looked healthy | idempotent `do $$` rename guarded on pg_attribute (old present, new absent) before any read. Go test against real PostgreSQL (legacy table renamed; second boot no-op) | batch 3 |
| 48 | ✅ | yes (class: boot config read at the wrong time) | `publicOrigin fromEnv` read at package `init` (panic with stack trace before `main`, and in every test binary importing the module); missing `TESL_OIDC_*`/session key surfaced only at first sign-in | `SetPublicOriginEnv`/`SetPreviousSessionKeyEnv` read lazily; `Serve` preflights publicOrigin, previous session key and every `sso` connection/session-key thunk, exits 1 with `tesl: cannot start: <variable>` before listening. Go unit tests | batch 3 |
| 46 | ✅ | yes | issuer mismatch said only "issuer mismatch" | message names expected and received issuer (both public). Go test | batch 3 |
| 43 | ✅ | yes | failed `expect a == b` printed only "Tesl expectation failed" | prints both values: Int/Float via `teslrt.DescribeValue`, String `%q`, Bool `%t` (no runtime pulled into runtime-free modules), records/ADTs as their JSON (names the constructor); any type that can hold a `secret` prints nothing (storage JSON would show plaintext). OCaml emission test + end-to-end run; 149 snapshots regenerated | batch 3 |
| 52 | ✅ | yes — backend parity: a `String @db(jsonb)` column read back verbatim from the memory store but re-rendered by PostgreSQL, so a text assertion passed in `tesl test` and failed in production | memory store kept the written bytes | `teslrt.JsonbText` reproduces `jsonb::text` (key order by length then bytes, last duplicate wins, `": "`/`", "`, NUMERIC number form, PG string escaping; invalid JSON / `\u0000` refused like PG). Compared with PostgreSQL 17 on 348 inputs (edge cases + random documents): 0 mismatches. Emitter gives such tables `NewTableNormalized`; every memory write path (insert/insertMany/keyed/update/updateAndReturnOne/upsert) stores the PG form; insert still answers its argument, updateAndReturnOne the stored row — as on PG. Go tests + tests/memory-store-parity-tests.tesl | batch 4 |
| 4 | ✅ (docs) | compile error already gone; spec was wrong | spec said `Int32 → INTEGER`; the Go backend deliberately keeps `NUMERIC` (migration storage contract, dev-docs/migration-planning.md) | LANGUAGE-SPEC column table + prose corrected: NUMERIC by default, `@db(integer)`/`@db(bigint)` for int4/int8. `varchar` part was already fixed upstream | batch 4 |
| 35 | ✅ | yes | compiled binary had no CLI, so a distroless image could not health-check itself | `app healthcheck [PORT]` in emitted `main.go` when the served server declares `healthProbePath`: probes mount+path on loopback/listenAddress at the literal App port, exit 0 on 2xx; dispatched before `Main()` (no DB, no migrations). Go tests, OCaml emission test, end-to-end binary run (down → 1, up → 0). Documented in LANGUAGE-SPEC | batch 4 |
| 55 | ✅ (mutation part) | yes — `tesl test` passed while `--mutate` refused the same file | the mutation runner emitted the target with the single-module `Emit_go.compile_module`, so any local import was "no wiring for the module" | baseline and each mutant now go through `local_dependency_modules` + `compile_project`, the path `tesl test` uses (graph re-lowered per mutant, so cycles work too). Note: mutation targets only `check`/`establish` bodies by design, so a module of plain `fn`s scores n/a. Coverage reporting not built (new tooling surface). OCaml test: check importing a local bound, 8/8 killed | batch 4 |
| 23.4 | ✅ (no new surface) | partly — asserting a refused subscription was already possible on Go with a plain `get` (real HTTP status); but a plain `get` to an ACCEPTING `sse` route hung the test forever | api-test requests ran `ServeHTTP` to completion, and an open stream never completes | requests stop once the response starts as `text/event-stream` (context cancelled, like a client hanging up): status + headers, empty body. Two api-tests (401 refused, 200 + content-type accepted) in api-boundary-regression-tests; documented in manual/best-practices | batch 5 |
| 23.3 | 🚫 out of scope (maintainer decision 2026-11-21) | — | `publish` inside a test body would be new statement surface | publishing through the endpoint under test stays the supported path (and is what the test should exercise) | — |
| 30 | ✅ | yes on Go too (Linux) — `tesl run` SIGKILLed left the compiled server serving and holding its port | children were started in their own process group with no parent-death signal; SIGTERM was already forwarded | `Pdeathsig = SIGTERM` for CLI children on Linux (graceful shutdown); no-op elsewhere. Go test kills the owner with SIGKILL and asserts the child stops (fails without the fix). Verified by hand with `tesl run` | batch 5 |
| 25 | ✅ (docs) | yes | `EventSource` cannot send headers, so a header-auth `sse` route always refuses a browser | LANGUAGE-SPEC SSE client section: use cookie-reading auth (`withCredentials` cross-origin) or a proxy-injected header; never a query-string key | batch 5 |
| 61 (higher-order part) | ✅ | yes | 29 documented functions (List zipWith/unzip/partition/groupBy/findIndex/dedupe/intersperse/intercalate/nth, Dict map/mapWithKey/filter/filterWithKey/foldl/foldr/insertWith/unionWith/update/difference/intersection, Set map/filter/foldl/all/any/partition, ListPrim head/tail/append) had no Go lowering. Same family found on the way: (a) `Dict.map`/`mapWithKey`/`foldl`/`foldr` checker signatures left the key/value variables unquantified (rigid), so NO call type-checked on any backend; (b) `Tesl.Net` constructors passed `tesl check` and failed the Go build (runtime file gate missed `teslrt.HostClass`), and a bare `exposing [Loopback]` was refused — the "unavailable" entry for them was stale | runtime helpers (collections_hof.go) with the callback passed as a Go func value, typed per call site (`type_of_callback_leaf`), equality/key ordering appended as for other Dict/Set leaves; lambda emission honours an expected result type; quantifiers fixed (scan: no other row has the gap); url_net gate + bare constructors. tests/collection-callback-tests.tesl (lambdas + named fns), tests/host-class-values-tests.tesl, seam/completion tests repointed to still-unavailable exports | batch 6 |
| 28 / 1 | 🚫 out of scope (maintainer decision 2026-11-21) | — | SSE replay / subscriber cap / named events / heartbeat knob, and a raw-JSON column type, are all new language/runtime surface | not built in this branch | — |
| 6 | 🟰 | yes — same findings as §16 | keyset tuple comparison | resolved by the §16 rows: OR of AND and tuple sort keys fixed; String `<` is deliberately absent | — |
| 19 | 🟰 | yes — not reproducible on Go | Tesl has no bracket indexing: `xs[0]` parses as applying `xs` to the list `[0]`, which the Go backend rejects at compile time (T001), so a value can no longer leak into a later dot access | indexing a JSON array in api-test is `arrayAt i value` (manual/best-practices) | — |
| 17 | ✅ | yes — only Signature values had base64/hex forms | no general reversible string encoding | maintainer decision 2026-11-23: proof-carrying encodings in Tesl.String. `String.toBase64Url`/`toHex` return `String ? IsBase64Url`/`? IsHex`; `String.parseBase64Url`/`parseHex` turn untrusted input into `Maybe` the proven value (canonical only: URL-safe alphabet without padding or stray bits, lowercase hex, UTF-8 text); `String.fromBase64Url`/`fromHex` are total on proven input. Only the stdlib mints the facts. tests/string-encoding-tests.tesl, Go runtime tests, compiler/test/test_string_encoding_surface.ml (decode without the fact, fact confusion and user minting are refused); LANGUAGE-SPEC §10.5/§10.6 | friction-remaining |
| 41 | ✅ | yes for the nix flake — native installers already shipped an offline module proxy and forced `CGO_ENABLED=0`, but the flake's `tesl` wrapper set neither, so generated programs fetched `pgx` from proxy.golang.org | the flake closure had the Go SDK but no module proxy | new fixed-output `tesl-go-module-proxy` (exactly the versions locked in runtime/go/go.sum, in Go's download layout, reproducible under `nix build --rebuild`); the CLI wrappers set `GOPROXY=file://…`, `GOSUMDB=off`, `GOTOOLCHAIN=local`, `GOFLAGS=-mod=mod`, `CGO_ENABLED=0`. Verified with networking disabled and empty caches: `tesl init` + `tesl build` succeed; the main-branch CLI fails on `proxy.golang.org`. A go.sum change now requires updating the derivation's hash (nix reports the mismatch) | friction-remaining |
| 31 | 🚫 out of scope | — | grouped with §28 (SSE replay / ready frame / subscriber cap / named events / heartbeat knob) | maintainer decision 2026-11-21: new runtime surface | — |
| 9 / 10 / 29 | — | — | project-specific notes and positives, not product issues | not actionable | — |

Environment notes (not caused by this branch): `test_emit_go` "fresh module passes Go gates" now fails locally because the nix `govulncheck` sees Go 1.26.4 stdlib and the vulnerability DB published new advisories; `test_migration_row_{forward,contract_abi}` trip on a stray local `example/result` nix symlink. CI "Native portability" failed once on a DNS error downloading the Go source tarball; it passed on the next run.
