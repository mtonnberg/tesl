# Tesl Go-runtime migration: formal review

**Subject:** commit `286e2ed` "Go migration (#82)", 2026-09-02. Racket runtime and emitter replaced by a Go runtime (`runtime/go/teslrt`, ~16.5k non-test lines, ~10.7k test lines) and a Go emitter (`compiler/lib/emit_go.ml`, 15.9k lines; `sql_query.ml`, 616 lines). 996 files changed.

**Reviewer stance:** senior language designer / runtime security reviewer. The question asked was whether the generated code and the runtime it links are safe, correct, performant and secure, and whether a Tesl author can be confident their app is secure. Nothing was taken on trust: every finding below marked CONFIRMED was reproduced by running code (Go tests against a copy of the runtime, or `.tesl` programs compiled with the freshly built compiler and executed) or by quoting the exact source. SUSPECTED means judged from source only.

**Method.** Compiler rebuilt from the commit. Six parallel deep-dives (HTTP surface; auth/crypto/SSO/outbound; database; runtime core incl. debugger and numerics; the `Tesl.Agent` LLM surface; migration parity and CI), each writing Go probe tests and Tesl probe programs, plus a direct review of the emitter with eight probe programs. Every High and the key Medium findings were independently re-run by the lead reviewer. All probes live under the session scratchpad (`scratchpad/agent-*/`, `scratchpad/mine/`); paths are listed in the appendix. No tracked file was modified.

---

## 1. Verdict

The migration is a real improvement in the places that matter most, and it is not yet a runtime a Tesl author can call secure without qualification.

**What is genuinely strong.** SQL injection is closed by construction: statement text is compile time, every runtime operand is a `$n` parameter, identifiers are quote-escaped, LIMIT/OFFSET/ORDER are grammar-literal. The authentication core is well built: Argon2id at sane parameters with a timing equaliser, HS256 sessions whose header is never parsed (no `alg` confusion), a JWS verifier that refuses every dangerous header, OIDC claim validation done properly, `__Host-`/HttpOnly/Secure/SameSite=Lax cookies written only on 2xx, `crypto/rand` everywhere, an SSRF guard that fires in the dialer on the resolved peer and on every redirect hop. Handler panics become sanitized 500s. Request bodies are capped. The header floor (nosniff, Referrer-Policy, X-Frame-Options, HSTS rule, CSP precedence) is present. `Int` is arbitrary precision with a checked fast path and every emitted `+ - *` routes through it. Division requires an `IsNonZero` proof at compile time. The emitted module vendors the runtime and pins and checksums its two external dependencies. The debugger is compiled only into `--debug` builds. `go vet`, `go test -race` and the fuzz targets are clean on the runtime.

**What is not.** Nine High findings, none of them in the cryptography, all of them in the seams:

1. Two SQL emission bugs produce **silently wrong results**: `inList`/`notInList` with a non-literal list compiles to `where true`/`where false` (an access-control filter written as `notInList t.id blocked` returns the blocked rows), and `updateAndReturnOne` updates one row on the Memory backend but every matching row on Postgres. Both are invisible to `tesl test`, which runs on Memory.
2. **Every SSE stream is cut by the server at exactly 60 s** (the `http.Server` WriteTimeout is never cleared for streams). The test harness uses `httptest.Server`, which has no timeouts, so the whole corpus is blind to it.
3. A `queue`, `cache` or `email` declared against a `Postgres` database is **emitted as in-process memory with no diagnostic**; jobs and outbox mail are lost on restart, replicas have disjoint queues, and `retry: backoff` is a no-op. The spec promises `tesl_jobs`, SKIP LOCKED and a transactional outbox.
4. The **email worker can crash the process** (stale slice index after the lock is released mid-SMTP) and has **no SMTP deadline**.
5. `Int.pow` with a client-controlled exponent is an **unbounded CPU/memory sink** (3^2e8 = 38 s on one core, no proof required).
6. In a `--debug` build the **TCP debug fallback has no authentication**: any local user can pause the world and read every local, including session cookies.
7. Two process gaps: the **embedded runtime copy has no drift gate** (four runtime files are not even dune deps, so an edit to `workers.go` can ship stale), and **~60% of the hand-written test estate was deleted with no drop ledger**, leaving outbound TLS verification with zero tests.

Below those sit two Medium auth findings (SSO callback skips the `state` check when the parameter is absent; outbound redirects forward custom secret headers cross-host and follow https→http), invalid JSON on the wire for non-finite floats, silent route shadowing, static-file symlink/dotfile exposure, a positional handler-to-route pairing that silently swaps same-shape handlers, and unbounded growth in metrics, telemetry, regex and cache stores.

**Design-level assessment.** Erasing proofs, facts and capabilities to nothing at runtime (Rust-style) is the right call for performance and for the "eject to plain Go" story, and the checker side held against every forgery attempt made here. But it moves the entire soundness burden onto the compiler and onto Memory-versus-Postgres parity, and the review found that parity is where the bugs now live. The Memory backend is the semantics a Tesl author tests against; when it disagrees with Postgres on `updateAndReturnOne`, `transaction {}` rollback, deadlocks, `like` escaping and NULL decoding, the language's central promise (tests mean something) is weakened. Closing the Memory/Postgres gap, and making the checker refuse what the emitter cannot render, are the two structural fixes.

**Recommendation.** Do not describe the runtime as production-secure until the nine High items and the two Medium auth items are closed. All are bounded, well-located fixes (section 7 gives an order); none requires redesign.

---

## 2. Severity scale

- **Critical**: remote compromise or proof-system bypass. None found.
- **High**: silently wrong results in a security-relevant path, process crash from ordinary input, remote DoS, or a process gap that lets any of those ship unnoticed.
- **Medium**: exploitable under a plausible configuration, or a correctness/parity defect that tests cannot see.
- **Low / Info**: hardening, hygiene, drift.

---

## 3. High findings

### H1. `inList` / `notInList` with a non-literal list silently emits a constant predicate
- **Status:** CONFIRMED (both backends; reproduced twice, independently).
- **Where:** `compiler/lib/sql_query.ml:136-149` and `:408-419` (`let values = match list_expr with EList { elems; _ } -> elems | _ -> []`); `compiler/lib/emit_go.ml:8217-8226` (Memory predicate `[] -> "false"` / `"true"`), `:8581-8588` (SQL text, same).
- **What happens:** `select p from Post where notInList p.author blocked` where `blocked` is a parameter (or any non-literal) type-checks and compiles. The clause is recovered with zero members and both renderers turn that into a constant. Emitted Go for the probe: `teslrt.TableSelect(PostTable, func(p Post) bool { return true })`; emitted SQL for the Postgres path: `... where true` (`inList` gives `where false`).
- **Evidence:** `scratchpad/mine/p7-inlist.tesl`: two rows (`alice`, `mallory`), `blockedOut ["mallory"]` returns 2, literal form returns 1. DB agent probe on Postgres 17: `notInList variable mem=[2] pg=[2]` (expected 1). No validator names `inList`/`notInList`.
- **Impact:** an authorization filter written with a runtime list is silently inverted or emptied. `notInList` is the dangerous direction (returns everything, including what was meant to be excluded). Memory and Postgres agree, so no test catches it.
- **Fix:** in `sql_query.ml` return `None` for a non-`EList` operand so the query falls into the existing "cannot render this query" error; better, support runtime lists by binding one `= any($n)` array parameter on Postgres and `slices.Contains` on Memory. Add a validation rule with a clear message.

### H2. `updateAndReturnOne` updates one row on Memory, all matching rows on Postgres
- **Status:** CONFIRMED (Postgres 17.10 + Memory side by side).
- **Where:** `runtime/go/teslrt/table.go:375-389` (`TableUpdateReturnOne` returns after the first match); `compiler/lib/emit_go.ml:9301` emits `update ... set ... where ... returning ...` with no row cap; `dbquery.go:368-379` takes `updated[0]`.
- **Evidence:** three rows, two match `active == True`: `mem=[returned=a sum=149] pg=[returned=a sum=228]`. The Postgres return row is also planner-order dependent.
- **Impact:** a predicate that is not unique (or stops being unique later) mutates extra rows only in production. The dev/test store hides it.
- **Fix:** pick one semantics and enforce it on both backends. Either require the predicate to cover the primary key or a declared `unique index` at check time (the `upsert onConflict` validator is the precedent, `validation_structural.ml`), or emit `where ctid = (select ctid from T where ... limit 1)` and make Memory trap when more than one row matches.

### H3. Every SSE stream is terminated by the server at 60 s
- **Status:** CONFIRMED with the production `http.Server` configuration (EOF at 1m0s) and with a 2 s WriteTimeout (EOF at the first heartbeat, 10 s); re-run by the lead reviewer.
- **Where:** `runtime/go/teslrt/serve.go:63-66` (`WriteTimeout: 60 * time.Second`); `sse_http.go:146-194` (`SseStream` never clears the deadline); `serve.go` `hardenedWriter` has no `Unwrap()`, so `http.NewResponseController(w).SetWriteDeadline` could not reach the connection even if called.
- **What happens:** Go's WriteTimeout sets one write deadline for the whole response. An `sse` route writes for the life of the connection; the first heartbeat after 60 s fails, the handler returns, the connection closes. Browsers reconnect every minute (default retry 3 s); events published in the gap are lost (no `Last-Event-ID`); every reconnect re-runs `auth` and re-registers a listener.
- **Why tests miss it:** `api-test subscribe` uses `httptest.NewServer` (no timeouts). "Passes test, fails live" is structural here.
- **Fix:** in `SseStream`, before the first write, clear the deadline via `http.NewResponseController(writer).SetWriteDeadline(time.Time{})` (or a rolling per-write deadline) and add `Unwrap() http.ResponseWriter` to `hardenedWriter`. Add a serve-level test that runs a subscription under the production server config with an injected short WriteTimeout.

### H4. Postgres-declared `queue` / `cache` / `email` are emitted as in-process memory, silently
- **Status:** CONFIRMED (emitted lesson70, which declares `backend: Postgres` at line 108 and `queue ReportQueue`, yields `var ReportQueueQueue = teslrt.NewQueue("ReportQueue", 1)`; no `tesl_jobs`, `SKIP LOCKED`, outbox table or backoff code exists anywhere in `runtime/go/teslrt`).
- **Where:** `compiler/lib/emit_go.ml:10490-10532` (no branch on the database backend); `runtime/go/teslrt/queue.go:9` ("the `backend: Memory` counterpart"); `workers.go:339-355` (no delay between retries).
- **Spec says otherwise:** `LANGUAGE-SPEC.md:1040-1066` (`tesl_jobs` table, enqueue within the current transaction), `:3469` (SKIP LOCKED, multi-process, exponential/fixed backoff), `:3588` (cache as UNLOGGED table), `:3702/:3789` (transactional outbox). `roadmap/completed/migrate_to_golang.md:1175` marks Postgres queues "Deferred", while `:1192` states `transaction {}` "is refused against a Postgres-backed database rather than emitted as something weaker than it claims". The queue is emitted as something weaker than it claims.
- **Impact:** `enqueue` inside a request is not atomic with the surrounding writes; every pending/dead job and every unsent email is lost on restart or deploy; two replicas have disjoint queues; `retry: backoff: Exponential` retries `maxAttempts` times back-to-back in microseconds. The Memory queue has no size bound and `dequeue` is O(n) per claim (`queue.go:86-110`), so an enqueueing endpoint is an unbounded-memory, quadratic-CPU sink.
- **Fix:** until the Postgres stores exist, refuse `queue`/`cache`/`email` on a `Postgres` database at compile time, exactly as `transaction {}` is refused, and say so in the spec. Implement backoff delays in `startWorkers` regardless.

### H5. Email worker: unrecovered panic crashes the process; no SMTP deadline
- **Status:** CONFIRMED (both, with a stub SMTP server).
- **Where:** `runtime/go/teslrt/email.go:162-209` (`deliverPending` records slice indices under the lock, releases it for the whole `DeliverEmail`, then writes `&outbox.messages[index]` after relocking); `PruneSentEmail` (`:280-293`, hourly) and `ResetOutbox` (`:309`) rebuild the slice; `StartEmailWorker` goroutines (`:145-156`) have no `recover`; `DeliverEmail` (`:227`, `smtp.Dial`) sets no dial or read deadline.
- **Evidence:** `SMTP dial still blocked after 3s with no greeting (no deadline)`; after a reset and a `500` reply: `runtime error: index out of range [0] with length 0` in a goroutine with no recover, which is fatal for the process. With a prune instead of a reset the status write lands on the wrong message.
- **Impact:** a stalled SMTP server halts all mail forever (single poller); a prune racing a delivery corrupts status or kills the server.
- **Fix:** identify messages by id, not index; `net.DialTimeout` plus `conn.SetDeadline` (the spec promises every outbound call has a deadline); `recover` in the worker loop.

### H6. `Int.pow` is an unbounded CPU/memory sink with no proof requirement
- **Status:** CONFIRMED (`Pow(3, 200_000_000)` = 38.5 s on one core, 37 MB result, re-run by the lead reviewer).
- **Where:** `runtime/go/teslrt/int.go:233-238` (only a negative exponent is rejected); emitter binding `emit_go.ml:13444` (`Int.pow: [Int; Int] -> Int`, no check).
- **Impact:** any endpoint that passes request-derived (or attacker-writable DB) data to `Int.pow` is a trivial remote DoS. The request goroutine is not cancelled by the server's timeouts. Related SUSPECTED (not executed, would OOM the host): `String.repeat` (`string.go:166-172`) and `List.repeat`/`List.range` (`list.go:253`, cap `1<<31` elements) with large counts produce an uncatchable `fatal: out of memory` rather than a recoverable trap.
- **Fix:** bound the result (e.g. `bitlen(base) * exp <= 1<<20` bits) and trap with a typed `RequestRejection`; or require a proof, as `/` and `%` already do. Cap `String.repeat`/`List.repeat` element counts at a size that is a recoverable panic.

### H7. Debug control over TCP has no authentication (debug builds only)
- **Status:** CONFIRMED. Preconditions: binary built with `--debug` and launched with `TESL_DEBUG_PORT=<n>` (the documented loopback fallback for platforms without Unix sockets; `tesl-debug-attach`/DAP discover it via `.tesl-stuff/debug.port`).
- **Where:** `runtime/go/teslrt/debug_control.go:124-133` (listen on 127.0.0.1, no credential); `:251-318` (`pause`, `snapshot`, `set-breakpoints`, `continue` accepted with no handshake); `debug.go:331-380` (Checkpoint blocks every application goroutine while paused); `debug.go:464-473` (snapshot includes locals and full domain state).
- **Evidence:** connect, send `{"command":"pause"}` with no handshake, hold a checkpoint carrying `sessionCookie="sid=abc123"`; both the stopped event and `snapshot` contain the value; after `continue` the snapshot still returns the stale locals.
- **Verified safe by default:** the plain emission contains zero `Checkpoint`/`DebugEnter` calls and no `debug*.go`; `StartDebugControlFromEnvironment` is emitted only when `mode = Debug` (`emit_go.ml:12409-12413`, `15659-15661`). The Unix-socket path is 0600 in a 0700 directory and refuses non-socket or symlink paths.
- **Impact:** on a shared host (CI runner, dev box, the Windows fallback) any unprivileged local process can stop-the-world and exfiltrate request state from a debug-built service. `SecretString` values are redacted; everything else is not.
- **Fix:** require a per-launch token for TCP (write it beside `debug.port` with 0600; demand it in a `handshake` before any other command); clear `lastFrame` on `continue`/`detach`. See also M17.

### H8. Process: the embedded runtime has no drift gate; four runtime files are not dune deps
- **Status:** CONFIRMED by reading (`grep -c` of each file in `compiler/lib/dune` = 0), content byte-identical today (63/63 files decoded from the OCaml literal and diffed).
- **Where:** `compiler/lib/dune:36-42` lists 59 deps for the `embedded_go_runtime.ml` rule; `compiler/gen/gen_go_runtime.ml:23` reads 63 files. Missing: `debug_sql.go`, `debug_state.go`, `debug_value.go`, `workers.go`. `ci.sh:704-714` diffs only `embedded_docs.ml`.
- **Impact:** `workers.go` is the queue worker loop. A fix there does not invalidate the dune rule; CI phase 2a tests the source tree, not the embedded copy, so the fix passes CI and does not ship in emitted programs. The gate tests a different artefact than users receive.
- **Fix:** add the four files (or a `source_tree` dep); add `git diff --quiet -- compiler/lib/embedded_go_runtime.ml` to the sync phase; add a seam test comparing `Embedded_go_runtime.files` to disk.

### H9. Process: the hand-written test estate shrank ~60% with no drop ledger; outbound TLS verification is untested
- **Status:** CONFIRMED.
- **Numbers:** 75 hand-written Racket suites (26,854 LOC) deleted at `286e2ed~1` with no `.tesl` sibling; 51 Go `_test.go` files (10,725 LOC) now. `roadmap/completed/migrate_to_golang.md:868` required "each drop is recorded with its justification"; the tracker has no ledger.
- **No Go counterpart found:** `http-tls-tests.rkt` (refuses self-signed even on loopback, refuses wrong-host chain-trusted cert, dev escape loopback-only and env-gated; `httpclient_test.go` has zero occurrences of `tls`, so `outboundTLSConfig`/`tlsInsecureDevEscape` at `httpclient.go:361-390` are untested); `pg-pool-tests.rkt` 503 semantics; `session-cookie-tool-confinement-test.rkt` (a tool cannot write the outer request's session cookie); `sse-capabilities-test.rkt` cookie/ACAO cases; `security-test.rkt` F4 (JSON depth).
- **With Go homes (verified):** response headers, client address/XFF, SSO adversarial, JWT policy, SSRF, mount path (1:1), email/httpclient integration, generated-id entropy.
- **Fix:** write the drop ledger; add TLS tests (`httptest.NewTLSServer` with a wrong-host cert must be refused; the escape requires loopback + env + not `TESL_DEPLOYED`); add pool-timeout and agent cookie-confinement tests.

---

## 4. Medium findings

### Authentication and outbound

**M1. SSO callback skips the `state` check when the `state` query parameter is absent.** CONFIRMED. `sso_flow.go:232-234`: `if presentedState != "" && presentedState != state.State`; `sso_route.go:159-171` passes `Query().Get("state")`, which is `""` when absent. Probe: victim cookie plus attacker `code`, no `state`, accepted with the attacker's identity. For `oidc` connections the id_token `nonce` check still rescues the flow; for plain `oauth2` (GitHub, Discord defaults) only PKCE remains, and it is effective only where the provider enforces it. Fix: `if presentedState == "" || subtle.ConstantTimeCompare(...) != 1 { return ssoFail("state mismatch") }`. RFC 6749 §10.12 requires the check to be unconditional.

**M2. Outbound HTTP follows redirects: custom secret headers travel to a different host; https→http downgrade is followed.** CONFIRMED. `httpclient.go:234-242` builds `http.Client` with no `CheckRedirect`; `outboundHeaders` (`:210-218`) reveals `HttpClient.secretHeader` handles into the request before `client.Do`. Go strips `Authorization`/`Cookie` on a domain change but forwards every other header, and never refuses a scheme downgrade. Probe: `X-Api-Key="sk-live-apikey"` observed at a second host after a 302; https→http followed. `sso_flow.go:17` claims "does not follow redirects" and `:36-44` checks HTTPS on the first URL only. The SSRF egress check does fire on each hop (verified). Fix: install `CheckRedirect`; for SSO legs return `http.ErrUseLastResponse`; for `HttpClient` refuse scheme/host changes when any secret header is present and refuse https→http.

### HTTP surface

**M3. Non-finite floats are encoded as `NaN`/`+Inf`/`-Inf` inside a `200 application/json` body.** CONFIRMED end to end from a `.tesl` program (`Float.exp 1000.0` answers `{"label":...,"value":+Inf}`), re-run by the lead reviewer. `json.go:216-217` reuses the display formatter `FormatFloat` (`float.go:21-29`). `Float.div` and `Float.sqrt` are proof-guarded; `exp`/`mul`/`pow` overflow and `pow`'s deliberate NaN are not. SSE `data:` frames use the same encoder. The program's own api-test fails opaquely because `JsonParseBody` (`apitest_json.go:119-129`) degrades an unparseable body to a string. Fix: trap (sanitized 500, matching Racket's `jsexpr->string` behaviour) or encode `null`, documented; make `JsonParseBody` fail loudly.

**M4. `:param` routes silently shadow later literal routes.** CONFIRMED. `server.go:117-139` matches first in declaration order; the emitter preserves that order; no checker or linter rule exists. `get "/tasks/:id"` before `get "/tasks/new"` compiles clean and `/tasks/new` is unreachable (or answers 400 when `:id` is an `intCodec` capture). If the shadowing route has weaker auth, the weaker auth runs. Fix: checker error when an earlier same-method pattern subsumes a later one, or rank literal segments above params and document it.

**M5. Static surface: symlinks escape the root, dotfiles are served, mounted-API misses fall back to `index.html`.** CONFIRMED, re-run by the lead reviewer. `serve.go:176-199` (`serveStatic`) does a lexical prefix check only; the comment claims the resolved path is checked but nothing calls `EvalSymlinks`. `GET /.env` → `200 DB_PASSWORD=hunter2`; `/.git/config` → 200; `/link.txt` (symlink out of root) → `SECRET OUTSIDE ROOT`; with `mountPath "/api"`, `GET /api/nothing` and `GET /api` → `200 text/html` index rather than the JSON 404 envelope. `..` and `%2e%2e` are correctly blocked. Fix: refuse segments starting with `.`; `EvalSymlinks` and re-check the prefix (or `os.OpenRoot`); under a non-empty mount prefix never fall through to static.

**M6. CSRF guard is `Sec-Fetch-Site: cross-site` only.** CONFIRMED. `serve.go` `requestRefusal`: POST with `Origin: https://evil.example` and no `Sec-Fetch-Site` → 200; `Sec-Fetch-Site: same-site` → 200. The runtime's own `__Host-session` cookie is protected by `SameSite=Lax; Secure; HttpOnly`, which covers browsers that lack Fetch Metadata. Program-defined cookies read in `auth` blocks (lesson16 `user`, chat-backend `chatUserId`) have no SameSite guarantee and rely on this guard alone. Fix: when `Sec-Fetch-Site` is absent and `Origin` (else `Referer`) is present, refuse if its host differs from `PublicOrigin()` when one is configured; consider refusing `same-site` behind a server clause.

### Emitter and language

**M7. Handler-to-route pairing is positional; same-shape handlers swap silently.** CONFIRMED (`scratchpad/mine/p4c-swap.tesl`). An api declaring `DELETE /mine` then `DELETE /admin/everything` (both with the same auth) paired with a server block listing `deleteEverything, deleteMine` emits `{Path: "/mine", Endpoint: "deleteEverything"}`; the api-test asserting `/mine` answers "deleted-mine" fails. Compilation is clean because the shapes match; the arity/auth validator (`validation_structural.ml:1710`, whose message still says "would fail `define-server` at startup") catches only shape mismatches. A reorder of a list is an authorization change with no diagnostic. Fix: bind by name (`delete "/mine" -> deleteMine`, or `via`), or at minimum warn when adjacent handlers in a server block are shape-compatible with each other's endpoints.

**M8. The Go backend is a strict subset of what the checker accepts.** CONFIRMED. 589 `unsupported` sites in `emit_go.ml`, including "does not support function `%s` as a value", "supports calls to named functions only", "recursive record/entity not supported", "ordering supports Int, String and scalar newtypes only", "String path captures only", "interpolation supports String/Int/Float/Bool only". `--check` (and therefore the LSP) reports green and the build then fails (`countNotes == 1` with a zero-arg fn; an `Int` capture under `serverTools`). No soundness issue, but the language's diagnostic contract is split across two components. Fix: move each restriction into the checker so `--check` agrees with the build, or implement the missing shapes.

### Database

**M9. `transaction { }` performs no rollback on the Memory backend.** CONFIRMED. `database.go:137-142`: `if connection == nil { body(); return }`. After a trap on the second insert the first survives on Memory and is rolled back on Postgres. `LANGUAGE-SPEC.md:2542` says "On any exception, the transaction rolls back". Fix: snapshot and restore the touched `Table.rows` under the write locks, or document the exception.

**M10. `test ... with database D` blocks are not isolated on Postgres; a trap aborts the whole test binary.** CONFIRMED. Only `teslrt.TableTruncate` (Memory) is emitted (`emit_go.ml:11653`, `:12385-12390`), and before `WithDatabase`; `DbTruncate` exists (`dbquery.go:392`) but is never emitted. Two tests inserting the same id: `panic: ... duplicate key value violates unique constraint ... [recovered, repanicked]` and the remaining tests never run; rows persist between `go test` invocations. Fix: emit `DbTruncate` per entity inside the `WithDatabase` closure; wrap test bodies in a `recover` that becomes `teslT.Fatal`.

**M11. Memory backend deadlocks on a same-table query inside `set` or `where`.** CONFIRMED (both shapes). `table.go:347-360` and `:375-389` call `apply(row)` under `mutex.Lock()`; `:133-143` calls `match(row)` under `RLock` and `TableCount` (`:150`) takes `RLock` again. `update ... set i.price = (selectCount x from Item)` never completes on Memory (completes on Postgres); a `where` operand containing a query wedges under a concurrent writer (goroutine dump confirms). No timeout, no diagnostic. Fix: evaluate `set` values and `where` operands before taking the lock (the Postgres path already evaluates the args thunk first), or refuse subqueries in those positions at check time.

**M12. A NULL in a NUMERIC column decodes silently as `0` into a non-`Maybe Int`.** CONFIRMED. `postgres.go:481-484`: `if !value.Valid || value.Int == nil { return FromInt64(0) }`, used by every Int column scan. TEXT NULL traps correctly; fractional NUMERIC traps correctly. Schema drift or a row written by another tool becomes a fabricated balance/quantity of 0. This is the one place the row-decoding backstop is fail-open. Fix: trap on `!Valid` for non-`Maybe` columns.

**M13. Pool exhaustion waits 30 s (queries) / 5 min (`transaction` BEGIN) and answers 500; the spec promises a 10 s lease and 503.** CONFIRMED. `postgres.go:305,349,368,392,419` (`context.WithTimeout(context.Background(), 30*time.Second)`), `database.go:144` (`5*time.Minute`), `server.go:76-93` (any panic → 500). `LANGUAGE-SPEC.md:1954` and `manual/tour.md:381` document `TESL_PG_POOL_LEASE_TIMEOUT_MS`, which is read nowhere. Blocking lease itself works (11th query waited 2.5 s). Fix: read the knob (default 10 s) into the acquire context; map acquire deadline to `RequestRejection{503}`; one timeout for BEGIN. Also: queries never observe the request context (no cancellation on client disconnect, no `statement_timeout`).

### LLM agent surface

**M14. Model-driven resource amplification.** CONFIRMED. Only iterations are bounded (`maxAgentIterations = 16`, `agent.go:410-412`). Tool calls per step, tool-result bytes and total tokens per run/conversation are unbounded: one provider step with 2000 tool calls dispatched all 2000 and fed 2000 MiB of `tool_result` back to the provider (`agent.go:441-443`). The 1 MiB HTTP body cap does not apply to endpoint tools (10 MiB provider-response cap does). Fix: cap `len(ToolCalls)` per step, truncate tool results with a marker, add a cumulative usage/wall budget on `runLoop` that ends with a distinguishable stop reason.

**M15. Persisted transcript is trusted verbatim.** CONFIRMED. `ConversationFrom` (`agent.go:622-633`) accepts any role/kind, no version, no size cap. A stored `{"role":"system",...}` becomes a second system message on OpenAI/Mistral/local wire; an unknown block kind panics in the Anthropic renderer on every later turn (`agent_provider.go:212`, per-conversation DoS); a 50 MiB transcript is accepted. Exploitability depends on who can write the transcript row. Fix: whitelist roles and kinds on decode, bound bytes and message count, add a version envelope, fail as a `Check` rather than a panic.

**M16. LLM calls inherit the generic 30 s / 10 MiB HttpClient limits; overflow and timeout discard the turn.** CONFIRMED by code (`agent_provider.go:113` → `httpclient.go:69`). A long generation traps; the 16-iteration overflow panics; in both cases tools that already ran (including `serverTools` writes) keep their side effects while the transcript for the turn is lost. Fix: a provider-specific deadline, return the partial transcript with an `aborted` stop reason, bounded retry on 429/5xx.

### Runtime growth and debugger hygiene

**M17. Unbounded stores.** All CONFIRMED with probes: metric attribute sets (50,000 series; `LANGUAGE-SPEC.md:182` promises a 2000-series cap with an overflow series; `telemetry.go:167-193`); telemetry events never drained and re-exported every interval (`telemetry.go:117-136`, `:323-345`; 100,000 retained); regex compile cache (`regex.go:224-246`; 20,000 patterns); cache entries reclaimed only on read and never bounded (`cache.go:51-63`, `:79-88`; 100,000 expired entries resident); Memory queue unbounded (H4). Any of these keyed on request data is a memory sink. Fix: implement the documented metric cap; drain events on export; bounded LRU for regex and cache; sweeper.

**M18. Debugger: the first client disconnect permanently disables breakpoints; the operator's socket directory is chmod'ed 0700.** Both CONFIRMED (debug builds only). `debug_control.go:182` attaches once; `:218-227` detaches on any connection close and nothing re-attaches (the comment claims otherwise); any port scan disables the operator's session, and every concurrent client receives every stop event. `debug_control.go:89-99` unconditionally `chmod 0700`s the parent of whatever socket path was given (`TESL_DEBUG_SOCKET=/srv/app/run/debug.sock` revokes group access to `/srv/app/run`). Fix: attach per connection; create and chmod only a private subdirectory.

### Process

**M19. No differential or output oracle.** CONFIRMED. 185 byte-exact `.go.snap` files regenerable by `scripts/regen-go-snapshots.sh`; the roadmap (`:886-888`) admits the "oracle" was both-backends-green and it was removed with Racket rather than upgraded; three hand-pinned Racket fixtures remain (JWT token, clear-cookie, SSE wire). Corpus test blocks run under Go only and without `-race`. The Memory/Postgres drift in this report is exactly the class an oracle would have caught.

**M20. Emitted code is only built in CI, never vetted or linted.** CONFIRMED. `run-go-corpus-build.sh` runs `go test -run "^$"`; vet/staticcheck/golangci-lint/gosec/govulncheck/nilaway run in `runtime/go` only (`ci.sh:626-660`). The `.golangci.yml` the emitter writes into every module is referenced in CI only as a snapshot exclusion. The roadmap (`:908-925`) claims "every emitted app passes the full static-analysis stack, always".

**M21. Documentation drift and undocumented breaking changes.** CONFIRMED. 217 stale Racket references (LANGUAGE-SPEC 46, dev-docs 164, AGENTS.md 4, INSTALL.md 2, CONTRIBUTING.md 1; `manual/` and README clean). Operationally wrong: `AGENTS.md:171-172` MCP recipe points at the deleted `editor/tesl-mcp/tesl-mcp.rkt`; `INSTALL.md:109,138`; `CONTRIBUTING.md:22` ("pins Racket 9.2"). `LANGUAGE-SPEC.md:51` still claims a runtime "Missing capabilities" check and a runtime witness-escape check exist as core semantics; neither exists in Go (grep: no matches), by design. Dead env knobs still documented: `TESL_PG_POOL_LEASE_TIMEOUT_MS`, `TESL_HTTP_STREAM_IDLE_TIMEOUT_MS`, `TESL_LIBSODIUM`, `TESL_TRACE_DB_STATEMENT`. Breaking changes shipped with no CHANGELOG/migration note: `with database X {}` removed; existential returns limited to one unannotated witness and forwarding narrowed; `selectMax`/`selectMin` → `Maybe`; test blocks → Go tests; debug output directory and sidecar keys changed.

---

## 5. Low and informational findings

**Auth/crypto.** SSRF classifier treats NAT64 (`64:ff9b::7f00:1`, `64:ff9b::a9fe:a9fe`), 6to4 (`2002:7f00:1::`), `192.0.0.0/24`, `198.18.0.0/15` and the TEST-NETs as public (`hostclass.go:87-127`). `fmt` with a non-string verb prints a Secret (`%d` → `{%!d(string=hunter2-plain)}`; `secret.go:29-38` implements `String`/`GoString`/`MarshalJSON` only; implement `fmt.Formatter`). `Http.setSessionCookie` hard-codes `Max-Age=3600` (`request.go:284`) while the SSO route honours `sessionPolicySeconds()`; under `ShortSession` the cookie outlives the 900 s token. Email recipient is not validated beyond CRLF (`victim@x>,<attacker@y`, empty, garbage all reach the outbox; CRLF is a panic → 500 rather than a 400). JWT/JWS base64url decoders are non-Strict (two token strings, one session; use `.Strict()`). SSO callback opens the in-flight cookie with the current key only (`sso_route.go:171`), so logins in flight during key rotation fail. Argon2 parameters are trusted from the stored PHC string (a poisoned row with `m=4 GiB` is a verify-time memory DoS; add a ceiling). `SmtpSettings.Password` is a plain `string`. Rate limiting on auth endpoints is absent (acknowledged in `roadmap/later/rate_limiting_revived.md`); `Crypto.checkPassword` at 64 MiB × t=2 per attempt with no throttle is a CPU/memory amplifier behind any login handler.

**HTTP.** `ParseJSON` accepts trailing garbage and concatenated documents (`json.go:29-37`). Explicit `codec ... fromJson` accepts unknown fields while derived decoders reject them; duplicate keys last-wins. Single-alternative record decoders swallow the field-level error (`"no decode alternative matched"` for a missing field). Decode errors reflect the whole submitted value in Go `%v` syntax (JSON-escaped, nosniff, not XSS). A 1 MiB digit string costs ~2 s CPU per request (`big.Int.SetString`; cap digit length). 405 lacks `Allow`. `%2F` is decoded before routing. SSE auth failures use `http.Error` text/plain rather than the JSON envelope; stream panics bypass `callHandler` (recovered by net/http, no disclosure). `api-test` drives `Server.ServeHTTP` directly: no `hardenedWriter`, no mount path, no timeouts, and a computed path containing a space panics `httptest.NewRequest` and kills the test binary. `clientAddressOf` panics (→ 500) when `trustedProxies` is declared and the whole chain is trusted (a proxy health check without XFF).

**Emitter.** Compiler crash on a non-ASCII JSON key in a codec: `name -> "nämé"` → `error: Invalid_argument("Bytes.create")` (`aligned_map_entries`, `emit_go.ml:10295-10303`, computes padding from the raw key length but renders with OCaml `%S`). Class: 34 sites still use OCaml `%S` (decimal `\ddd` escapes) where Go needs `\xhh`/octal; `go_quote` (`emit_go.ml:352`) is correct but not used at routes (`:11145`), JSON keys (`:10938-10957`), SSO segment (`:11484`), api-test path (`:5602`), debug names. A non-ASCII route or key produces a Go literal that fails to compile; for bytes whose decimal digits are all octal (0x0B → `\011` → TAB in Go) the value would change silently. `//line` directives are placed before the `if`, so an `expect` failure on line N is reported as N+1. Test blocks whose entities are not named in any `database` declaration share one Memory store across all test functions (deliberate, `emit_go.ml:11640-11655`; spec does not say so). Diagnostics still carry Racket-era wording ("would fail `define-server` at startup"). Unknown api verb (`head "/x"`) is a compile error but the message is misleading ("clauses must come before the `->`").

**Database.** `like` backslash escaping and `ilike` non-ASCII folding differ between Memory and Postgres (`table.go:278-309`). `--debug` SQL capture displays `secret` column plaintext (`emit_go.ml:8311-8316` binds `.Reveal()`). Unique/PK violation is a sanitized 500 on both backends (consistent, uncatchable, not 409). CI/dev cluster is `SQL_ASCII` (`scripts/postgres-init.sh:17`, no `-E UTF8`), so string comparison results obtained in CI do not transfer to a UTF8 production database. NUL bytes: Postgres rejects (clean trap), Memory accepts. Schema bootstrap runs `create ... if not exists` on every `OpenPostgres`; no drift detection (documented as not a migration tool).

**Runtime.** One NaN metric sample silently empties the entire metrics export (`telemetry.go:400-406`, `mustJSON` returns nil). `Requeue` of an in-flight dead job runs it twice (`queue.go:309-322`). Cache TTL is second-granular. `Money.add`/`subtract`/`compare` on mismatched currencies is a runtime trap, not a static error (`money.go:141-146`). `Int → Float` is lossy above 2^53 by design and undocumented at call sites. `TESL_DEBUG_SOCKET`/`TESL_DEBUG_PORT` alone enable the control server in a debug build (no `TESL_DEBUG=1` needed). `TESL_HTTP_ALLOW_LOOPBACK_EGRESS` and `TESL_HTTP_TLS_INSECURE_DEV` disable the SSRF loopback guard and TLS verification respectively; both are correctly refused when `TESL_DEPLOYED` is set, and no environment variable disables a proof, check or auth.

**Agent.** Duplicate tool names compile clean, both are sent to the provider, the first silently wins. Full upstream error body (up to 10 MiB) is copied into the trap message. The step stream publishes the model-chosen tool name before validation (JSON framing holds). OpenAI-wire tool calls with `type≠function` or empty `id` are dispatched anyway. Nested agents are 16^depth. Human-action "resume" is plain user text the model cannot authenticate.

**Process.** `ci.yml` has no `permissions:` block (default token scope); `actions/checkout@v4` floats (first-party); the one third-party action is SHA-pinned; Go 1.26.6 is pinned by sha256 in `flake.nix`. `test_go_discover.ml` is a stub (`ignore tesl_files`). JSON nesting cap moved from 64 (Racket, `TESL_MAX_JSON_DEPTH`) to encoding/json's 10,000 (bounded, memory bounded by the 413 cap). SSE `Access-Control-Allow-Origin: *` for non-session streams was dropped entirely (stricter, undocumented). The roadmap links `go_review01.md`, which is not in the tree.

---

## 6. What holds up (attacked and not broken)

- **SQL injection:** every `Sprintf`/concat site in `dbquery.go`/`postgres.go`/`table.go` read; `sql_ident` doubles quotes; LIKE/ILIKE patterns, IN members, time-zone names are `$n`; `date_trunc` unit whitelisted; LIMIT/OFFSET int-literal and ORDER `asc|desc` by grammar; emitted SQL for lesson-21-shaped queries contains no runtime value; NUL bytes and 39-digit Ints round-trip or trap cleanly; no request can trigger DDL.
- **Proof/capability forgery through the compiler:** all six `aiProvider` indirections (direct, lambda, transitive, partial application, `converse`, undeclared host agent) refused; `asTool` refuses proof-carrying parameters; `serverTools` refuses `let`/lambda/`case` shadowing and cross-api auth weakening ("privilege-escalation risk"); division and modulo require `IsNonZero`; `Float.sqrt` requires `FloatNonNegative`; literal patterns are now typed against the scrutinee. The proof-validation diff in this commit tightens rather than weakens (interpolation, `fail` messages and constructor args are now walked; existential forwarding fails closed).
- **Password hashing:** Argon2id v19, m=64 MiB, t=2, p=1, 16-byte `crypto/rand` salt, 32-byte tag pinned, `subtle.ConstantTimeCompare`, 1024-byte input cap → 400, timing equaliser for unknown accounts with an identical 401 message, `NeedsRehash` on weaker encodings, libsodium vector test.
- **Signatures and tokens:** `hmac.Equal`/`subtle` everywhere (no `==` on tags found). JWT header never parsed so `alg:none`/RSA-as-HMAC is impossible by construction; malformed tokens → 401 not 500; renewal needs a usable `iat` within +60 s and a 12 h/8 h absolute cap; revocation hook fails closed on panic. JWS refuses JWE, `alg` absent/none/HS*, `jwk`/`jku`/`x5u`/`x5c`/`crit`, alg outside discovery ∩ {RS256, ES256}, kty/alg mismatch, unknown `kid`, RSA < 2048 bits, malformed ES256 signatures; JWKS cache bounded.
- **OIDC:** sub/iss required; exact issuer or tenant template with `tid` allow-list; `aud` contains client id; `azp` checked; nonce constant-time; exp/iat with 60 s leeway; `iat` ≥ flow start; `email_verified` must be JSON `true`; identity key is an injective hash of (iss, sub); domain allow-lists require a verified address. state/nonce/verifier 256-bit `crypto/rand`, sealed in `__Host-oauth` under a KDF-derived HMAC subkey, segment-bound, 10-minute Max-Age, single-use state, PKCE S256 mandatory, `redirect_uri` from `publicOrigin` never Host, `AfterLogin` a fixed path (no open redirect), provider errors never reflected.
- **Sessions:** `__Host-session=<jwt>; Path=/; HttpOnly; Secure; SameSite=Lax`, fixed name, `SetSessionCookie` refuses non-JWT-shaped values, cookies attached only to 2xx so set-then-fail mints nothing.
- **Randomness:** no `math/rand` in the runtime; ids, salts, nonces, UUID v4/v7 all `crypto/rand`.
- **Secret redaction:** `%v %+v %#v %s %q %x`, `json.Marshal`, `EncodeJSONValue`, `DebugValueOf` (nested in records), and the `callHandler` stderr trap all redact `SecretString`.
- **Outbound HTTP:** egress verdict in `net.Dialer.Control` on the resolved peer (no resolve/connect TOCTOU), confirmed on redirect hops; mapped/compatible IPv4-in-IPv6 folded; 10 MiB response cap; connect/read deadlines; TLS ≥ 1.2 with chain and hostname verification; CR/LF refused in header names and values; `Proxy` unset so `HTTP_PROXY` cannot bypass the egress check.
- **Request path:** 1 MiB body cap applied by every emitted handler (no other `io.ReadAll` in the emitter), 413 on overflow; `auth` runs before captures and body decoding; `Int` decoding rejects `1e400`, `1.0`, `"1"`, `null`, `NaN`, `01`, `0x10`; 1,000,000 nested `[` rejected in 1.4 ms; output escapes `<>&`, invalid UTF-8 → U+FFFD, U+2028; Host spoofs (`a@b`, trailing dot, `:80:81`, IPv6, tab, `%2e`) all 421; `..`/`%2e%2e` traversal blocked; header floor on JSON/HTML/SSE/static/error/301; HSTS only from a configured https non-loopback origin; sanitized 500 with stack on stderr only.
- **Emitter hygiene:** Go keyword/predeclared/emitter-namespace identifiers are renamed correctly (fn `len`, `nil`, `teslrt`, `teslScrut1`, `fmt`; fields `func`/`range`/`string` all compile and run); `$` interpolation emits `+` concatenation, never a format string; shell-outs use `Filename.quote`; every emitted `+ - *` on `Int` goes through checked helpers and `Int` is non-comparable so raw `==` is a compile error; ADT switches carry `default: panic("unreachable")` plus the `exhaustive` lint config.
- **Numerics:** int64 fast path with exact `big.Int` spill (MinInt64/-1 handled); Racket `quotient/remainder/modulo` sign matrix reproduced; `Money` arithmetic exact with half-even rounding; NaN/±0 ordering deliberate; regex is RE2 with a 1 MiB input cap; `String.length`/slicing rune-based and clamped.
- **Supply chain:** emitted modules vendor the runtime; `require` and a complete `go.sum` are emitted only when password or Postgres runtime is pulled (`emit_go.ml:962-995`), pins match `runtime/go/go.mod`; `GOPROXY=off GOFLAGS=-mod=readonly go build && go mod verify && go vet` pass on emitted lesson18 and lesson64. Runtime CI runs `-race`, vet, staticcheck, golangci-lint, gosec, govulncheck, nilaway with an empty waiver list, and hard-fails on missing tools.
- **Concurrency:** `go test -race` clean on the full runtime suite and on all probes (HTTP, SSE, Memory tables, agent with 50 goroutines); `Publish` is non-blocking with a drop counter; listeners unregistered on context cancel; queue worker traps are failed attempts, not crashes.
- **Debugger default posture:** not compiled into non-debug builds; Unix socket 0600 in 0700 dir; refuses non-socket and symlink paths.

---

## 7. Language-design observations

1. **Erasure is right; parity is now the soundness boundary.** With proofs, facts and capabilities erased, the Go output is exactly as trustworthy as the checker plus the equivalence of the two storage backends. The checker held. The backends did not (H1, H2, M9, M11, M12, and the `like`/`ilike`/NUL drift). Treat Memory-versus-Postgres agreement as a first-class invariant with its own differential suite, not as a set of parity comments in the Go source.

2. **Two components decide what compiles.** 589 emitter refusals mean `--check` and the LSP are green for programs the build rejects. In a language whose pitch is "the compiler tells you exactly what is wrong", the emitter should never be the first to say no. Either lift each restriction into the checker or implement it.

3. **Positional binding of handlers to routes is a footgun.** The server block is an ordered list whose order is an authorization decision; the validator catches only shape mismatches. Name-based binding removes the class.

4. **The spec has drifted from the runtime in security-relevant places.** Runtime capability check (line 51), `tesl_jobs`/SKIP LOCKED/backoff, cache as UNLOGGED table, transactional outbox, pool lease 503, metric cardinality cap, `transaction` rollback. A Tesl author reading the spec today believes guarantees the Go runtime does not provide. Where the runtime is deliberately narrower, the compiler should refuse the declaration (as it does for `transaction {}` on Postgres) and the spec should say so.

5. **The test story has a structural blind spot.** api-tests run against `httptest.Server` (no timeouts, no `hardenedWriter`, no mount path), test blocks run on Memory, and the emitted test binary is never run under `-race` or vetted. H3, M5, M9 and M10 are each "passes test, fails live". Routing api-tests through `handlerWith` with the production server options, and adding one integration run that boots the real `Serve`, would have caught the most visible bug in this report.

6. **Good calls worth keeping:** proof-gated division; `Check[T]` as the only way a validation result enters value position; the request scope passed explicitly instead of goroutine-local state; the SSRF verdict in the dialer; `Int` as a non-comparable struct; vendoring the runtime into every module; `--debug` as the only way the debugger enters a binary.

---

## 8. Recommended remediation order

**Week one (exploitable or silently wrong):**
1. H1 `inList`/`notInList`: refuse non-literal operands in `sql_query.ml`, or bind `= any($n)`. One-line fix, one validator message.
2. H2 `updateAndReturnOne`: enforce a unique predicate at check time or emit the `ctid` form; make Memory trap on >1 match.
3. H3 SSE: clear the write deadline in `SseStream`; add `Unwrap()`; add a real-server test.
4. H6 `Int.pow` (and `String.repeat`/`List.repeat`): bound the result size with a typed trap.
5. H5 email worker: id-based status writes, dial/read deadlines, `recover`.
6. M1 SSO `state`: make the check unconditional.
7. M2 redirects: `CheckRedirect` (ErrUseLastResponse for SSO; refuse scheme/host change with secret headers).
8. M5 static: refuse dotfiles, `EvalSymlinks`, no static fallback under a mount prefix.
9. M3 non-finite floats: trap or `null`; make `JsonParseBody` loud.

**Week two (parity and durability):**
10. H4: refuse `queue`/`cache`/`email` on a Postgres database until the stores exist; implement backoff delays.
11. M9, M11, M12, M13: Memory rollback, lock-free operand evaluation, NULL trap, lease timeout + 503.
12. M10: `DbTruncate` inside `WithDatabase`; `recover` → `Fatal` in test bodies.
13. M4, M7: route-shadowing checker rule; name-based (or warned) handler binding.
14. M14, M15, M16: agent budgets, transcript validation, provider deadline.
15. M17: metric cap, event drain, bounded regex/cache stores.

**Process (in parallel):**
16. H8: dune deps + `embedded_go_runtime.ml` diff gate + seam test.
17. H9: drop ledger; TLS, pool-timeout and cookie-confinement tests.
18. M19, M20: differential Memory/Postgres suite; vet/lint emitted corpus; `-race` on emitted tests; api-tests through `handlerWith`.
19. M21: fix `AGENTS.md`/`INSTALL.md`/`CONTRIBUTING.md`; correct `LANGUAGE-SPEC.md` line 51 and the queue/cache/outbox/pool sections; remove dead env knobs; add a CHANGELOG with the breaking changes.
20. H7, M18: token handshake for TCP debug; per-connection attach; private socket directory.

---

## Appendix A. Probes and how to re-run

All under the session scratchpad root `/tmp/claude-1000/-home-mikael-repos-wsl-tesl-github-tesl/c87f0b9c-20cc-4c20-accc-9dea089b7d8a/scratchpad/`. Each `rt/` is a copy of `runtime/go`; run probes with `go test -race -run <Name> -v ./teslrt/` inside it. Tesl probes were emitted with the compiler built from `286e2ed` (`compiler/_build/default/bin/main.exe <file> --out <dir>`), then `go vet ./... && go build ./... && go test ./internal/teslmod*`.

- `mine/` (lead reviewer): `p1-strings.tesl` (escaping, `//line` off-by-one), `p1b-jsonkey.tesl` (compiler crash), `p2-idents.tesl` (Go keyword identifiers), `p3-numeric.tesl` (proof-gated division, bignum), `p4-pairing.tesl`/`p4c-swap.tesl` (positional pairing), `p4b-verb.tesl` (unknown verb), `p5-isolation.tesl`/`p5b-isolation-db.tesl` (test store sharing), `p6-interp.tesl` (interpolation), `p7-inlist.tesl` (H1), `run.sh`.
- `agent-http/rt/teslrt/probe_http_test.go` (JSON strictness, encoding, router, WriteTimeout × SSE short and real, CSRF, Host, static + headers, error echo, body limits, api-test bypass); `nan-probe.tesl`, `shadow-probe.tesl`; `real-timeout.log`, `race.log`.
- `agent-auth/rt/teslrt/zz_review_auth_test.go` (Secret sinks, SSO no-state, redirect header forwarding, egress on redirect hops, https→http, classifier gaps, cookie Max-Age, JWT malleability, email recipient, stored Argon2 params); `emit-session/`, `emit-sso/`.
- `agent-db/p1/probe1.tesl` + Go tests (Memory/Postgres parity, deadlock, NULL decode, pool contention, race, RLock wedge), `p2/probe2.tesl` (`notInList`, `ilike` Unicode, groupBy zone). Temporary Postgres 17.10 cluster on port 54329 (stopped).
- `agent-rt/rt/teslrt/zz_review_{debug,int,growth,email,misc,nan,fuzz}_test.go`; `emit/{plain,debug}` (lesson03 diff), `emit/l70` (Postgres-declared queue); `vet.log`, `race.log`, `fuzz.log`.
- `agent-ai/rt/teslrt/agent_probe_test.go` (10 probes) and `agent-ai/tesl/*.tesl` (8 programs: capability indirections, `asTool` proof param, shadowing, cross-api auth, `Int` capture, duplicate names).
- `agent-parity/extract.py` (embedded-vs-disk diff), `emit-*/` (offline readonly builds + `go mod verify`), `jsondepth/`, `old/` (extracted Racket-era files and suite lists).
- Per-area reports: `findings-http.md`, `findings-auth.md`, `findings-db.md`, `findings-runtime.md`, `findings-agent.md`, `findings-parity.md`, `findings-emitter-mine.md`.

## Appendix B. Things deliberately not covered

Live vendor LLM APIs (provider client reviewed by code and stubs only). Non-C Postgres collations (only C/C.utf8 installed). Executing the `String.repeat`/`List.repeat` OOM shapes (would have taken the review host down). The playground/js_of_ocaml build. The VS Code extension JavaScript.

---

## 9. Remediation status (same day, 2026-09-02)

All nine High findings and the Medium/Low items marked below were fixed in the working tree after this
review, each with regression tests. Verification: runtime `go vet` + `go test -race ./...` (all 10
packages), the emitted-code gate stack (`nilaway`, `staticcheck`, `golangci-lint`, `gosec`) on fresh
emitted modules, the OCaml suite (`dune test`), snapshot regeneration (188), the Go corpus build and the
Tesl test manifest. `CHANGELOG.md` lists the user-visible changes.

| ID | Fix | Tests |
|---|---|---|
| H1 | `inList`/`notInList` require a list literal: checker rule `check_sql_list_membership_operands` names the operand; `sql_query.ml` fails closed on the shape | `compiler/test/test_sql_list_membership.ml` (7), `tests/sql-list-membership-tests.tesl` |
| H2 | `updateAndReturnOne` emits `where ctid = (select ctid from T where …)`; SQLSTATE 21000 and the Memory table both trap "matched more than one row" before any write | `table_test.go`, `database_test.go` (Postgres), `tests/sql-update-return-one-tests.tesl` |
| H3 | `hardenedWriter.Unwrap()`; SSE stream arms a rolling 30 s write deadline per write; `newHTTPServer` shared by `Serve` and tests | `sse_http_test.go` (stream outlives a 1 s WriteTimeout; stalled client still dropped) |
| H4 | Lint **W097** on `queue`/`cache`/`email` declared against a Postgres database; in-memory queue bounded (100 000) with O(log n) claim; spec §11 carries a "Go runtime status" note | `queue_test.go`; W097 fires on `lesson70` |
| H5 | Email worker: id-based status writes, `net.DialTimeout` + `SetDeadline` (`TESL_SMTP_CONNECT_TIMEOUT_MS`, `TESL_SMTP_TIMEOUT_MS`), `recover` per iteration | `email_worker_test.go` (8) |
| H6 | `Int.pow` bounded at 2^20 result bits (`ErrPowTooLarge`); `String.repeat` > 64 MiB traps; `List.repeat`/`range` cap 2^26 | `int_test.go`, `string_test.go`, `list_test.go`, fuzz identity |
| H7 | TCP debug control requires a per-launch token (`.tesl-stuff/debug.token`, 0600) in a first-message handshake; per-connection attach; locals cleared on `continue`/detach; all clients updated | `debug_control_auth_test.go` (6), `internal/dap`, `cmd/tesl-debug-attach` tests |
| H8 | Four files added to the dune rule deps; CI phase diffs `embedded_go_runtime.ml`; seam test compares embedded to disk and checks every file is embedded | `compiler/test/test_embedded_go_runtime_seam.ml` |
| H9 | Drop ledger `roadmap/completed/go_migration_test_drop_ledger.md`; TLS verification tests; cookie-confinement test | `httpclient_tls_test.go` (5), `test_server_tools.ml` |
| M1 | SSO `state` compared unconditionally (`subtle`) | `sso_test.go` |
| M2 | `CheckRedirect`: ≤5 hops, no https→http, no host change with secret headers, SSO and provider legs follow none | `httpclient_test.go` (7) |
| M3 | Non-finite floats trap in `EncodeJSONValue`; response encoding recovered into a sanitized 500; `JsonParseBody` loud | `json_test.go`, `server_test.go` |
| M4 | Checker rule `check_route_shadowing` | `compiler/test/test_route_shadowing.ml` (5) |
| M5 | Dotfiles refused; `EvalSymlinks` containment; mounted misses → JSON 404 | `serve_test.go` |
| M6 | `Origin`/`Referer` host checked against the public origin when Fetch Metadata is absent | `serve_test.go` |
| M7 | **Correction:** lint **W095** ("two api endpoints share one handler signature — positional-bind ambiguity") already existed and fires on the probe; the review missed it. Not a `--check` error; left as a lint. | — |
| M9 | `transaction {}` rolls back on Memory (restore-by-snapshot, goroutine keyed); Memory-only modules now emit the wrapper instead of inlining | `database_test.go` (5), `tests/transaction-memory-rollback-tests.tesl` |
| M10 | Test bodies recover traps into `t.Fatalf`; `with database D` truncates D's tables on the server inside the bound block | emitted `module_test.go` shape; snapshots |
| M11 | Memory tables: immutable published rows + version; predicates evaluated outside the lock; optimistic retry | `table_test.go` (4) |
| M12 | `PgIntOf` strict: NULL into non-`Maybe Int` traps | `postgres_test.go` |
| M13 | `TESL_PG_POOL_LEASE_TIMEOUT_MS` (10 s) bounds acquire/BEGIN/COMMIT; timeout → `RequestRejection{503}` | `database_test.go`, `postgres_test.go` |
| M14–M16 | Per-step tool-call cap 32, 64 KiB result truncation, 4 MiB/turn, `TESL_AI_TURN_TIMEOUT_MS`; transcript v1 envelope + validation; `TESL_AI_TIMEOUT_MS`, bounded retry; duplicate tool names refused | `agent_test.go`, `agent_provider_test.go` (20) |
| M17 | Metric series cap 2000 + overflow series; event ring drained on export; regex LRU 256; cache bound 100 000 + sweep | `telemetry_test.go`, `regex_test.go`, `cache_test.go` |
| M18 | Per-connection debugger attach (part of H7). Socket-dir chmod (finding 8) **not changed** | — |
| M21 | `AGENTS.md`, `INSTALL.md`, `CONTRIBUTING.md`, `LANGUAGE-SPEC.md` (line 51, queue status, TLS/libsodium, dead knobs), `manual/best-practices.md`; `CHANGELOG.md` added | — |
| Low | Secret `fmt.Formatter`; session cookie Max-Age follows policy; strict base64url; SSO cookie previous key; SSRF NAT64/6to4/reserved; Argon2 parameter ceiling; `ParseJSON` trailing content; decode errors name the type; 405 `Allow`; 4096-digit Int cap; api-test malformed path; `like` escapes; UTF8 dev cluster; `Requeue` guard; NaN metric; `%S`→`go_quote` at every program-text site (fixes the non-ASCII JSON-key crash); `//line` off-by-one | per-area `_test.go`; probes under `scratchpad/mine` |

**Later the same day:** the Postgres-backed stores were implemented (H4 closed for real): `queue` → `tesl_jobs` with SKIP LOCKED claims, declared backoff, transactional `enqueue` and stale-claim reclaim (`TESL_QUEUE_VISIBILITY_TIMEOUT_MS`); `email` → `tesl_email_outbox`; `cache` → `tesl_cache` (UNLOGGED); SSE `publish` → `tesl_pubsub_outbox` + LISTEN/NOTIFY fan-out to every instance. Emitted through `NewQueueOn`/`RegisterJobCodec`/`NewOutboxOn`/`NewCacheOn`/`NewSseChannelOn` when the declaration names a Postgres database (`test_durable_stores.ml`; runtime `pgstores_test.go`, `pgpubsub_test.go` against a live cluster). Lint W097 retired.

**Not done (deliberately deferred):** rate limiting on auth endpoints; a standing Memory/Postgres differential suite (M19) beyond the side-by-side cases added in `database_test.go`; vet/lint of the emitted corpus as a CI phase (M20); `api-test` through `handlerWith` (Info); debugger socket-directory chmod (M18 second half); the Go-backend-subset `--check`/emit split (M8).

---

## 10. Whitebox attack campaign (same day, after remediation)

Six attackers with source access (compiler, emitter, runtime) each wrote Tesl programs plus the attack that
exploits them, ran them, and reported only what ran. Per-area reports: `scratchpad/attack-{codegen,proofs,http,db,agent,secrets}.md`
(session scratchpad). Every confirmed issue below was closed the same day with a regression test.

| # | Area | Finding (CONFIRMED) | Severity | Fix | Test |
|---|---|---|---|---|---|
| A1 | proofs | **`via` coverage compared proof predicates by NAME only.** A check/auth establishing `Role u "guest"` satisfied a codec field, route capture and route auth declared `Role user "admin"`; the boundary credited the declared proof and a guest-validated request reached the admin sink (runtime-confirmed on codec and capture). Root: `proof_predicates` dropped arguments; three sites consumed it. | **High** (authz bypass) | Argument-for-argument comparison after canonicalising the subject binder (`proof_apps_of*` in `validation_common.ml`); the capturer's abbreviated binder no longer picks a literal. | `test_via_proof_arguments.ml` (6) |
| A2 | db | **`==`/`!=` on a `Maybe` column against a `Nothing` operand**: Memory matched NULL rows, Postgres never (`= NULL`). `where s.revokedAt == none` revoked every session in tests and none in production. | **High** (authz filter drift) | Emit `IS [NOT] DISTINCT FROM` for Maybe columns. | `test_sql_maybe_equality.ml`, `TestBoundMaybeEqualityIsNullSafe` (PG) |
| A3 | codegen | **Two module names folding to one Go package** (`FooBar`/`Foobar`/`Foo_bar` → `teslmodfoobar`): artifact dedupe kept the first `module.go`, so a dependency mirroring a trusted module's exposed names hijacked them with no diagnostic. | **High** with an untrusted dependency | Refused before emission (`compile_project`). | `test_package_collision.ml` |
| A4 | http | **Unauthenticated CPU DoS through the decimal parser**: the 4096-digit cap covered only JSON; `intCodec` path captures and `String.toInt` still ran the quadratic `big.Int` parse (900 000-digit segment = 1.7 s CPU, before any check). | **High** (DoS) | Cap moved into `ParseDecimal`/`validJSONInteger`; echoed segment bounded. | `TestDecimalDigitCapCoversEveryParsePath` |
| A5 | db | Query binder shadowing a parameter (`fn f(r: Row) = select r from Row where r.n == r.small`): Memory compared the row with itself, SQL bound the outer `r`. | Medium | Checker rule `check_query_binder_shadowing`. | `test_sql_maybe_equality.ml` |
| A6 | db | The new ctid-based `updateAndReturnOne` missed the row under contention (148/400 spurious "no row matched"): the outer TID scan keeps the statement snapshot while a writer moves the row. | Medium | Count-guarded statement (`… and (select count(*) … where <pred>) = 1`) plus an explaining probe (`PgSqlProbed`) so ambiguity keeps its own trap. | `TestBoundUpdateReturnOneIsExactUnderContention` (PG, 4×50 writers, 0 traps) |
| A7 | agent | Turn budget checked once per iteration; a 32-tool step overshot it six-fold. | Medium | Deadline checked before every dispatch; remaining calls answered is_error. | agent budget tests |
| A8 | codegen | `_hidden` record field became an unexported Go field (cross-module build break); `fn testMain` collided with the emitted harness. | Low | `X_` prefix for exported `_` names; `testmain` reserved. | `test_package_collision.ml` |

**Held (attacked, not broken):** the proof kernel and ordinary call-site discharge (arguments always compared there — which is what localised A1 to the `via` shortcut); all string/literal/identifier escaping shapes, api-test descriptions, odd-byte routes and JSON keys, `@db(...)`, table/index names; HS256 sessions, `__Host-` cookie, CSRF guard incl. today's Origin/Referer fallback, Host guard, traversal defences, sanitized 500s; SQL parameterisation with hostile identifiers; serverTools' bound user (`ToolDispatchWith(dispatch, u)`), tool argument decoding through the same codecs and checks as HTTP, transcript validation, humanActions inertness; the checker's wire-secret rule (a `secret` cannot leave through a return, SSE payload, `Maybe`/`List`/nested record or interpolation), `SecretString` redaction under every verb, SSRF egress on the resolved peer and on redirect hops.

**Documented, not changed:** Memory `transaction {}` rollback restores whole tables (a concurrent request's committed rows on the same table are undone with it); `selectOne` without `order` is insertion-ordered on Memory and heap-ordered on Postgres; Float `-0.0`/NaN comparisons and ICU collation differ between the stores; `env`/`envString` accept any variable name (an author who forwards user input as the name discloses `PGPASSWORD`); (fixed after all: `secret` columns now bind through `teslrt.PgSecret`, so the `--debug` SQL preview renders the redaction — `TestDebugPgSqlRedactsSecretParameters`, `TestBoundSecretParamStoresPlaintextAndRendersRedacted`); transcript validation is structural (a storage-write attacker can still fabricate a well-formed prior tool exchange the model will believe).
