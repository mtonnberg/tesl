# Changelog

## Unreleased — 2026-09-02 security and correctness pass (post Go migration)

Findings and evidence: `language-review.md`, `language-review-executive.md`. Every item below
has a regression test.

### Breaking / behaviour changes a program can observe
- **`inList` / `notInList` require a list literal.** A variable, `let` or call as the member
  list is now a compile error (V001, operand named). It used to compile to a constant
  `where false` / `where true` — an exclusion filter returned every row.
- **`updateAndReturnOne` refuses an ambiguous predicate.** When the `where` clause matches
  more than one row, both backends now trap before changing anything ("the predicate matched
  more than one row"). Memory used to update the first match; Postgres updated all of them.
- **Route shadowing is a compile error.** A `:param` route declared before a literal route it
  subsumes (`get "/tasks/:id"` then `get "/tasks/new"`) is refused; the literal one was
  unreachable.
- **`Int.pow` is bounded.** A result over 2^20 bits traps (`Int.pow: … too large`) instead
  of pinning a CPU. `String.repeat` over 64 MiB traps; `List.repeat`/`List.range` cap at
  2^26 elements.
- **Non-finite floats never reach the wire.** Encoding `NaN`/`±Inf` into JSON traps
  (sanitized 500) instead of emitting invalid JSON with a 200.
- **`ParseJSON` rejects trailing content**; decode errors report the JSON type, not the value.
- **Test blocks:** a trap inside a test body fails that block (`Tesl test trapped: …`) instead
  of aborting the whole test binary; `test … with database D` truncates D's tables on the
  server before the block. A failing `expect` is now reported at its own line.
- **Durable, multi-instance stores on Postgres.** `queue` (`tesl_jobs`, SKIP LOCKED claim,
  backoff, stale-claim reclaim), `email` outbox (`tesl_email_outbox`), `cache` (`tesl_cache`,
  UNLOGGED) and SSE pub/sub (`tesl_pubsub_outbox` + LISTEN/NOTIFY fan-out) now live on the
  declared Postgres database and are shared by every server instance; `enqueue`, `Email.send`
  and `publish` join the surrounding `transaction { }`. Workers are woken by `NOTIFY tesl_queue`
  from any instance (one shared LISTEN connection per process, 5 s fallback poll); the stale-job
  sweep runs once a minute per process, off the claim's hot path; queue metrics
  (`tesl.queue.enqueued/completed/failed`, `tesl.queue.job.duration`) are recorded on both
  backends. A Memory-backed database keeps the stores in process (dev/test). New env knob:
  `TESL_QUEUE_VISIBILITY_TIMEOUT_MS` (default 600000). A store failure inside a worker (database
  unreachable, lease timeout) no longer unwinds the goroutine — which, as an unrecovered panic,
  took the whole process down — the worker reports, backs off (1 s … 30 s) and resumes. The same
  guard now covers the hourly outbox pruner, the pub/sub LISTEN loop and the telemetry exporter.

### Runtime hardening
- SSE streams are no longer cut at 60 s by the server's `WriteTimeout` (rolling 30 s per-write
  deadline instead).
- SSO callback: the `state` parameter is required and compared unconditionally; the in-flight
  cookie opens under the current **and previous** session key.
- Outbound HTTP: redirects capped at 5, https→http refused, redirects that change host with a
  secret header present refused; SSO legs follow no redirects.
- Static files: dotfiles refused, symlinks resolved and re-checked against the root, mounted-API
  misses answer the JSON 404 rather than `index.html`.
- CSRF: `Origin`/`Referer` host is checked against the configured public origin when
  `Sec-Fetch-Site` is absent.
- Email worker: id-based status writes (no stale index), SMTP connect/read deadlines
  (`TESL_SMTP_CONNECT_TIMEOUT_MS`, `TESL_SMTP_TIMEOUT_MS`), recovers instead of crashing.
- Debugger (`--debug` builds only): TCP control requires a per-launch token
  (`.tesl-stuff/debug.token`); sessions survive client churn; locals are cleared on `continue`.
- Postgres: NULL in a non-`Maybe` numeric column traps instead of decoding as 0; pool lease
  bounded by `TESL_PG_POOL_LEASE_TIMEOUT_MS` (default 10 s) and answers 503; `transaction {}`
  rolls back on the Memory backend too; Memory backend no longer deadlocks on same-table
  subqueries; `like` honours `\` escapes.
- Agent: per-step tool-call cap, tool-result truncation, per-turn byte/time budget
  (`TESL_AI_TURN_TIMEOUT_MS`), provider deadline `TESL_AI_TIMEOUT_MS`, bounded retry on
  429/5xx, persisted transcripts validated on load, duplicate tool names refused.
- Bounded stores: metric attribute sets (2000 + overflow series), telemetry events drained on
  export, regex compile cache, cache entries, in-memory queue.
- `Secret` redacts under every `fmt` verb; JWT/JWS base64url is strict; Argon2 stored
  parameters are capped; `Http.setSessionCookie` Max-Age follows `sessionPolicy`; SSRF
  classifier covers NAT64/6to4 and the IETF reserved IPv4 blocks.

### Whitebox attack campaign (same day) — issues found and closed
- **`via` coverage compared proof predicates by NAME only.** A `check`/`auth` establishing
  `Role u "guest"` satisfied a codec field, route capture or route auth declared
  `Role user "admin"`, and the boundary credited the declared proof to the value. Arguments are
  now compared (only the subject binder may differ). The capturer's abbreviated binder heuristic
  also no longer picks a literal (`"admin"`) as the binder.
- **`==`/`!=` on a `Maybe` column** renders as `is [not] distinct from`: `= NULL` is never true in
  SQL, so `where s.revokedAt == none` matched everything on Memory and nothing on Postgres.
- **A query binder that shadows a parameter/local/function is refused** (`select r from Row
  where r.n == r.small` with an outer `r` read the row on Memory and the outer `r` on SQL).
- **Two module names folding to one Go package** (`FooBar`/`Foobar`/`Foo_bar` →
  `teslmodfoobar`) are refused; one module's code silently replaced the other's.
- **`updateAndReturnOne` selects its row `for update`** so a concurrent writer cannot make the
  ctid lookup miss (spurious "no row matched" under contention).
- **Decimal digit cap moved to `ParseDecimal`**: path captures (`intCodec`) and `String.toInt`
  were still quadratic on a 900 000-digit input (1.7 s CPU per unauthenticated request); the
  400 body no longer echoes the whole segment.
- **Agent turn budget is checked before every tool dispatch**, not once per iteration (a
  32-tool step could overshoot the budget six-fold).
- **`secret` columns bind through `teslrt.PgSecret`** (a `driver.Valuer` that renders redacted): the
  `--debug` SQL capture's `Params`/`Preview` showed a secret column's plaintext.
- **`bench/*.tesl` compile again**: they still used the `with database { }` block removed in #82.
- `_`-leading record fields become exported Go fields (`X_hidden`); `fn testMain` no longer
  collides with the emitted test harness.
- Documented, not changed: the Memory store's `transaction {}` rollback restores whole tables
  (a concurrent request's committed rows on the same table are undone too) and `selectOne`
  without `order` is insertion-ordered on Memory and heap-ordered on Postgres. Both are reasons
  the Memory store is a dev/test store. The SSO `state` single-use check is per process (the
  sealed `__Host-oauth` cookie still binds the flow to the browser).

### Process
- CI fails when `compiler/lib/go_runtime/embedded/embedded_go_runtime.ml` is stale; a seam test compares the
  embedded runtime to `runtime/go/teslrt` byte for byte and checks every file is embedded.
- Fuzz gates run through `scripts/go-fuzz-target.sh`, which retries only the Go fuzz engine's
  own `-fuzztime` deadline race ("context deadline exceeded" with no crasher written; twice
  on the 4-core runner). A real finding still fails the first run.
- The embedded Go runtime is a dune virtual library (`compiler/lib/go_runtime`): the CLI and
  tests link the snapshot by default, the browser playground links the empty implementation.
  #82 had pushed the playground bundle from 1.13 MB to 2.37 MB (its ceiling is 2 MB).
- Test-drop ledger for the migration: `roadmap/completed/go_migration_test_drop_ledger.md`.
- Outbound TLS verification tests restored (`httpclient_tls_test.go`).

## 2026-09-02 — Go migration (#82)

- The Racket runtime and emitter are replaced by a Go runtime (`runtime/go/teslrt`) and a Go
  emitter. `tesl <file> --out <dir>` emits a self-contained Go module; test blocks compile to
  `go test` functions.
- Removed: the `with database X { … }` body block (bind a database in `main`'s `App` or a
  `test … with database X` header instead).
- Changed: existential returns take exactly one unannotated witness; nested/multi-witness
  returns and `:::` on the witness binder are rejected; forwarding is narrowed to the same
  single binder and a ground witness type.
- Changed: `selectMax` / `selectMin` return `Maybe T` (no row → `Nothing`).
- Changed: `--debug` output lives under `.tesl-stuff/go-debug/`; the source map sidecar uses
  `go_line`; the DAP server is `runtime/go/cmd/tesl-dap`.
