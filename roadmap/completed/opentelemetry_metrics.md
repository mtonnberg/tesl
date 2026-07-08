# OpenTelemetry Metrics — built-in runtime metrics + user-facing instruments over the existing OTLP pipeline

**Status: IMPLEMENTED (2026-07-08)** — all three phases shipped in one pass, as designed below plus the following deviations/additions discovered during implementation:

- **Cache + agent metrics promoted from "deferred" into the shipped catalog** (Mikael's steer): `tesl.cache.requests{cache,result=hit|miss}` (chokepoint `cache-get!`, covers both backends; Nothing = miss includes expired + undeserializable), `tesl.agent.calls{provider,model}`, `gen_ai.client.operation.duration`, `gen_ai.client.token.usage{type}` (all at `call-provider`; provider/model recovered via a weak-hash metadata registry the constructors populate — providers are opaque closures), and `tesl.agent.tool.duration{tool,outcome}` (`run-tool-call` wrapper).
- **Host CPU/memory confirmed out of scope** (collected by the host's agent, not the app); moved to Non-goals.
- **Attrs surface**: `List (Tuple2 String String)` — `[Tuple2 "plan" plan]`, the `Dict.fromList` precedent (open question 1 resolved as recommended; there is no tuple literal syntax).
- **Exporter shutdown is cooperative** (generation counter), NOT kill-thread: re-init can run under a different custodian than the one that started the exporter thread, and `kill-thread` across custodians raises (caught live by cache-tests).
- **No log-buffer for metrics**: cumulative aggregation means a failed POST is simply retried-by-snapshot next interval — the logs exporter's bounded-queue/drop-oldest machinery is unnecessary for this signal.
- **`#:otlp-timeout-ms` fix DEFERRED**: `HttpClient.post` → `http-sendrecv` has no timeout parameter; a real fix needs timeout support in `tesl/http-client.rkt` first (follow-up).
- Files: `dsl/metrics.rkt` (new core), `dsl/otel.rkt` (init wiring + drop counter), `tesl/logging.rkt` untouched (gates kept separate), capture points in `dsl/web.rkt`/`dsl/sql.rkt`/`tesl/queue.rkt`/`tesl/sse.rkt`/`tesl/agent-provider.rkt`/`tesl/agent.rkt`/`tesl/cache.rkt`; surface in `type_system.ml`/`checker.ml`/`emit_racket.ml`/`tesl/telemetry.rkt`; tests `tests/otlp-metrics-test.rkt` (21 checks, registered in ci.sh); docs LANGUAGE-SPEC §5.2 **Metrics** paragraph + grammar + stdlib list, `manual/tour.md`, new `example/learn/lesson73-metrics.tesl` (compiles + boots + records live).

**Adversarial review pass (2026-07-08, 24-agent workflow, 10 confirmed findings — all fixed):**
1. Registry semaphore was not kill-safe (web server kills request threads mid-critical-section → stranded lock → site-wide hang). Fixed: registry uses ATOMIC MODE (`call-as-atomic`) — kills defer until the section exits, no lock object to strand; attr normalization moved outside the atomic body.
2. Widening the emitter's `known_kw` set reserved `metrics`/`metricsInterval` inside initTelemetry's value refolding, silently mis-emitting `console metrics` (user binding named `metrics`) as valueless keywords. Fixed at the emitter (valueless keyword = hard compile error with rename hint) + a checker guard for typed positions. **Discovery: App-main bodies are NOT type-checked at all** (`checker.ml` `is_app_main` — validated structurally, body skipped), so the checker's initTelemetry keyword validation never ran for the canonical `let _ = initTelemetry …` in main — `initTelemetry bogus "x"` compiled clean pre-diff too. The emitter guard is the only one covering main.
3. Request-duration histogram recorded the `'route-not-found` sentinel as 404/unmatched before `serve` resolved it — every healthy SPA page load would export a 404. Fixed: dispatch skips the sentinel; `serve` records the RESOLVED outcome (200 `spa-fallback` vs real 404 `unmatched`).
4. `metricsInterval` unvalidated: negative killed the exporter thread on its first `sleep`, zero busy-looped. Fixed: clamp to ≥1000 ms.
5. `reset-metrics!` (every re-init) zeroed cumulative counters without advancing `startTimeUnixNano` — an OTLP temporality violation collectors reject/mis-rate. Fixed: start-ms is a box, reset advances it (regression test added).
6. `mistral` provider reused `make-openai-provider` without metadata re-registration → Mistral traffic labeled `openai`. Fixed like `local`.
7. SSE active-count hash was gated on `metrics-active?` → connects/disconnects during a metrics-off window permanently skewed the gauge. Fixed: count is unconditional (mirrors registry membership); only emission is gated.
8. `tesl.queue.jobs.dead` incremented BEFORE the persisting UPDATE — a transient PG failure counted a dead-letter that never happened. Fixed: count after persist, both backends.
9. SSE gauge written outside `sse-metrics-lock` → out-of-order writes could leave a stale value indefinitely. Fixed: gauge write inside the lock (lock order sse-lock → registry-atomic, no inversion).
10. Tesl-surface `counter`/`histogram`/`gauge` evaluated `raw-value`/attrs conversion before the gate and outside any handler — cost with metrics off, raise-through on malformed values. Fixed: gate first, convert inside a swallow-all handler (regression test added); bare built-in call sites (cache/queue/sse/otel) also gated to avoid eager attr allocation.

The original accepted design follows unchanged.

---

**Status: PLANNED (drafted 2026-07-08, expanded from the original one-paragraph ask)**

## Original ask

> Right now we support logging via open telemetry (to for instance OneUptime). But we do not have any support for metrics/performance data etc. Since open telemetry is a first class citizen and it is important to know the state of an application if you going to host a saas-app at scale we should support a larger feature set.

## What is actually true today (mapped 2026-07-08, commit 6844ef2)

**Logs signal only, OTLP/HTTP+JSON.** Metrics/traces/gRPC/protobuf are explicit non-goals in three places: `dsl/otel.rkt:82-85`, `LANGUAGE-SPEC.md:66` + `:179`, and `roadmap/completed/otlp_exporter.md` (DONE 2026-07-02 — its Non-goals list is exactly this item's scope).

What exists and what a metrics feature rides on:

- **Emit chokepoint**: `emit-telemetry-event!` `dsl/otel.rkt:342-354` — fans out to consumers, never raises. Flat event model (no start/end pair, no span IDs).
- **Exporter machinery** (`make-otlp-http-consumer` `dsl/otel.rkt:228-285`): bounded buffer (10× batch-size), drop-oldest overflow, background flusher thread (2 s timer OR batch-full semaphore), POST via shared `tesl/http-client.rkt`, never raises — dead collector degrades to dropped batches. URL normalization `otlp-logs-url` `otel.rkt:168-172` (a `/v1/metrics` sibling goes here). Pure unit-tested mapping `telemetry-events->otlp-logs-jsexpr` `otel.rkt:143-163` (the pattern for `->otlp-metrics-jsexpr`).
- **Config**: `init-opentelemetry!` `otel.rkt:287-335` (`#:service-name #:endpoint #:console? #:otlp-headers #:otlp-timeout-ms #:otlp-batch-size #:otlp-flush-interval-ms`; endpoint `"in-memory"`/`""` = no export). Tesl surface (`initTelemetry`) exposes only `service`/`endpoint`/`console` — checker keyword validation `checker.ml:2505-2523`, emitter mapping `emit_racket.ml:2107-2159`. Bug drive-by: `#:otlp-timeout-ms` is accepted but unused (`_timeout-ms` `otel.rkt:230`).
- **Framework instrumentation bridge**: `tesl/logging.rkt` — typed helpers already carry metric-ready OTel-semconv attributes through one funnel (`tesl-emit!` `logging.rkt:65-71`, gated by `tesl-log-active?` :58-59 = verbose OR telemetry sink installed): HTTP request/response **incl. `http.duration_ms`** (:78-88), SQL statement (:95-105, no duration), queue enqueue/dequeue/done/fail (:109-139), pubsub publish/deliver (:143-157). Sink installed by `init-opentelemetry!` only when a real endpoint is set (`otel.rkt:329-333`).
- **Per-request context**: `call-with-telemetry-context` with `request.id`/`http.method`/`http.path`/`operation`/`user.id` — `dsl/web.rkt:1788-1809`.
- **Capability model**: telemetry is the deliberate ambient exception (LANGUAGE-SPEC §5.2, `:168-179`); exporter grants `httpClient` internally for its own POST only (`otel.rkt:92-96, 192-196`). Known open concern SEC-TELEMETRY (`roadmap/completed/architecture_trajectory.md:13-14`): ambient egress is an unaccounted network side channel — metrics inherit this; no new decision needed here.

**There is no counter/histogram/gauge anywhere.** Job duration, SQL duration, pool wait, queue depth, SSE connection counts are not measured today (details + exact hook lines in the catalog below).

## Design decision

Two halves, in this order:

1. **Built-in runtime metrics** (the actual "know the state of a SaaS app at scale" value): the runtime records a fixed catalog of low-cardinality metrics automatically whenever metrics are enabled — zero user code beyond `initTelemetry`.
2. **User-facing instruments**: `counter`/`histogram`/`gauge` as plain import-gated stdlib functions on `Tesl.Telemetry`.

Core mechanics:

- **New runtime module `dsl/metrics.rkt`**: an in-process pre-aggregating registry (OTel SDK style) — counters = monotonic cumulative sums, histograms = explicit-bucket (OTel default boundaries), gauges = last-value. Keyed by `(name, sorted-attrs)`. Mutations O(1) under a semaphore (Racket green threads — cheap), never raise. Cumulative temporality, `startTimeUnixNano` = process start (collector handles restarts).
- **Export**: periodic snapshot → `ExportMetricsServiceRequest` JSON → POST `<endpoint>/v1/metrics`, reusing the flusher-thread/never-raise pattern from `make-otlp-http-consumer`. Default interval 60 s (OTel default).
- **Built-ins record at existing chokepoints**: the typed `tesl/logging.rkt` helpers double as metric recorders where they already fire (HTTP duration/status, queue events, pubsub), plus new capture at the cited lines for the gaps (SQL duration, job duration, pool wait/timeout, SSE gauge/drops, LLM tokens). Gate: a dedicated `metrics-active?` flag — do NOT widen `tesl-log-active?` (would drag verbose-log behavior along).
- **Instrumentation is direct calls to typed recorder functions** — not parsing log events back out of the sink. Explicit, typed, no coupling of metric fidelity to log attribute spelling.

Rejected alternatives:

- **New `metric` statement form** (like `telemetry ... { }`): touches token/AST/parser/desugar plus ~15 exhaustive matches (`validation_proof.ml`, `validation_capabilities.ml`, `ast_visitor.ml`, `linter.ml`, `mutate.ml`, `proof_checker.ml`, several `emit_racket.ml` statement lists). Plain stdlib functions are tables-only. Rejected — blast radius buys nothing; the syntax doesn't need it.
- **New `Tesl.Metrics` module**: metrics and logs are the same signal family, same endpoint, same init. One module (`Tesl.Telemetry`) keeps the ambient story and config in one place. Rejected.
- **Deriving metrics by sniffing the log-event sink** ("zero new call sites"): couples metrics to log attribute strings, and the gaps (durations, gauges) need new capture anyway. Rejected.
- **Prometheus pull endpoint**: second transport model, second config surface; OTLP push already reaches OneUptime/Grafana/Honeycomb. Rejected (can be a collector concern).
- **Traces/spans in this item**: needs start/end pairs + context propagation — a different model than both flat events and aggregated metrics. Separate future roadmap item.

## Language surface

```tesl
import Tesl.Telemetry exposing [initTelemetry, counter, histogram, gauge]

main() -> App requires [] =
  -- metrics on by default when endpoint is real; new optional knobs:
  let _ = initTelemetry service "todo-api" endpoint (env "OTEL_ENDPOINT") console False metrics True metricsInterval 60000
  App { ... }

fn completeTodo(id: TodoId) -> Todo requires [dbWrite] =
  ...
  counter "todo.completed" 1 [("plan", planName)]
  ...
```

Signatures (builtin `stdlib_env`, import-gated to `Tesl.Telemetry` like `telemetry`/`initTelemetry`):

```
counter   : String -> Int -> List (String, String) -> Unit    -- add to monotonic sum
histogram : String -> Float -> List (String, String) -> Unit  -- record distribution sample
gauge     : String -> Float -> List (String, String) -> Unit  -- set current value
```

Ambient like `telemetry` (no capability) — extends the LANGUAGE-SPEC §5.2 ambient exception to the metrics signal. Unlike `telemetry`/`initTelemetry` these are real runtime functions, so `tesl/telemetry.rkt` provides them for real (re-exported from `dsl/metrics.rkt`), not as sentinels.

## Built-in metric catalog (phase 1)

OTel semantic-convention names where they exist; `tesl.*` where they don't. Durations in seconds (current semconv). All attrs low-cardinality by construction (route = `route-spec-operation`, never the raw path).

| Metric | Kind | Attrs | Hook |
|---|---|---|---|
| `http.server.request.duration` | histogram | method, status, operation | `dispatch-request` `dsl/web.rkt:1777-1906` (start-ms :1785 becomes unconditional-when-active; status+elapsed :1898-1902; pool-503 :1810-1829, exn-500 :1830-1853, 404 :1894-1896) |
| `db.client.operation.duration` | histogram | operation, table | `with-sql-capture` `dsl/sql.rkt:2031-2035` wraps every postgres-* exec (~14 sites) — time `(run)` there, zero new call sites |
| `db.client.connection.wait_time` | histogram | — | around `connection-pool-lease` `dsl/sql.rkt:2789-2792` |
| `db.client.connection.timeouts` | counter | — | `#:fail` thunk `dsl/sql.rkt:2793-2797` (issue #31 pool-exhaustion path) |
| `db.client.connection.max` | gauge | — | pool creation `dsl/sql.rkt:2840-2843` (`#:max-connections`) |
| `tesl.queue.enqueued` | counter | queue | `enqueue!` `tesl/queue.rkt:589-626` |
| `tesl.queue.job.duration` | histogram | queue, outcome (ok/check-fail/exn) | wrap `handler-fn` at `queue.rkt:759, :797` — **not measured today** |
| `tesl.queue.jobs.dead` | counter | queue | `fail-job!` dead transition `queue.rkt:707` (PG) / `:728-730` (in-memory) |
| `tesl.sse.connections.active` | gauge | channel | janitor register/unregister `tesl/sse.rkt:132/:135` (issue #32 rework — fires on every exit path) |
| `tesl.sse.events.dropped` | counter | channel | `on-event` `sse.rkt:107-108` — buffer-full currently a **silent drop** (limit 64) |
| `gen_ai.client.token.usage` | counter | provider, model, type (input/output/cache-read/cache-write) | `call-provider` `tesl/agent-provider.rkt:504-513` (self-described "single choke point … one place for telemetry/cost"); usage already normalized `:377-382, :193-201, :277-281` |
| `gen_ai.client.operation.duration` | histogram | provider, model | same chokepoint |
| `tesl.agent.calls` | counter | provider, model | same chokepoint — LLM call count |
| `tesl.agent.tool.duration` | histogram | tool, outcome | `run-tool-call` `tesl/agent.rkt:394` — per-tool latency + implicit call count |
| `tesl.cache.requests` | counter | cache, result (hit/miss) | `tesl/cache.rkt` mem-get/pg-get paths (hit/miss knowable, e.g. comment :113) |
| `tesl.telemetry.dropped` | counter | signal | exporter drop-oldest `otel.rkt:274-285` — self-observability |

Deferred from the catalog (candidates for a later cut): pool leases-in-flight gauge (no single release chokepoint — releases via thread death + `release-pool-lease!` `tesl/queue.rkt:202-206` + SSE pre-stream `web.rkt:1967-1970`; wait-time + timeout counters approximate it), queue depth gauge (in-memory trivial at `queue.rkt:662`; PG needs `count(*)` polling — contention risk, see Risks), `http.client.request.duration` (`tesl/http-client.rkt:114, :184`), pubsub publish/deliver counters, email outbox (`tesl/email.rkt:203, :253-264`), process runtime gauges (`current-memory-use` one-liner if ever wanted).

## Phases

**Phase 0 — metrics core + exporter.** New `dsl/metrics.rkt`: registry (counter/histogram/gauge, cumulative, default bucket boundaries), cardinality cap per instrument (OTel SDK default 2000 attr-sets; overflow folds into the spec's `otel.metric.overflow` set + bumps `tesl.telemetry.dropped`), pure `metrics-snapshot->otlp-jsexpr`, periodic exporter to `/v1/metrics` reusing the flusher/never-raise pattern. Wire into `init-opentelemetry!` (`#:metrics?` default `#t` when endpoint real, `#:metrics-interval-ms` default 60000). Fix the unused `#:otlp-timeout-ms` while in there. Tests: `tests/otlp-metrics-test.rkt` mirroring `tests/otlp-exporter-test.rkt` (pure mapping units + localhost OTLP sink asserting the `/v1/metrics` batch + closed-port resilience + cardinality-cap test).
*Exit:* Racket suite green; snapshot mapping unit-verified; dead collector provably never blocks/raises the record path.

**Phase 1 — built-in runtime metrics.** Record the catalog above at the cited hooks; `metrics-active?` gate separate from `tesl-log-active?`; timing capture unconditional-when-active. PG-vs-in-memory parity asserted for queue metrics (SKIP ≠ PASS).
*Exit:* `./compile-examples.sh` green; an example app (todo-api) under a short load run shows the catalog at a localhost collector sink; per-surface Racket tests for the new capture points (job duration, pool wait/timeout, SSE gauge/drops).

**Phase 2 — user-facing instruments + surface.** Table edits (see map), real provides in `tesl/telemetry.rkt`, `initTelemetry` new keywords through checker+emitter, new lesson `example/learn/lessonXX-metrics.tesl` (mirrors lesson17), LANGUAGE-SPEC §5.2 + grammar + `manual/tour.md` updates.
*Exit:* `dune test` green (stdlib-binding seam test `test_stdlib_runtime_binding.ml` passes for the new names — it auto-derives from the tables); `./compile-examples.sh` green; lesson exercises all three instruments end-to-end.

## Implementation map

- `dsl/metrics.rkt` (NEW) — registry, snapshot, OTLP mapping, exporter loop, `metrics-active?`.
- `dsl/otel.rkt` — `init-opentelemetry!` metrics wiring (`otel.rkt:287-335`), URL sibling of `otlp-logs-url` (:168-172), timeout fix (:230).
- `tesl/logging.rkt` — typed helpers double as recorders (HTTP :78-88, queue :109-139).
- `dsl/web.rkt:1777-1906`, `dsl/sql.rkt:2031-2035, :2787-2797, :2840-2843`, `tesl/queue.rkt:589-626, :695-812`, `tesl/sse.rkt:43-58, :107-135`, `tesl/agent-provider.rkt:504-513` — capture points per catalog.
- `compiler/lib/type_system.ml` — `stdlib_env` types (~:765), `stdlib_bare_home_module` rows (:1115-1116 vicinity). No `stdlib_capabilities` / `tesl_stdlib_cap_map` rows (ambient — same deliberate absence as telemetry; if this decision flips, `validation_common.ml:1548` needs the provider row or we recreate the 2026-07-06 email bug).
- `compiler/lib/checker.ml:2505-2523` — `initTelemetry` keyword validation (`metrics` Bool, `metricsInterval` Int).
- `compiler/lib/emit_racket.ml:2107-2159` — keyword → `#:metrics?`/`#:metrics-interval-ms`. `module_path_table` unchanged (Tesl.Telemetry row exists :109). New names must NOT go into `config_only_import_names` (:4048) — they are real provides.
- `tesl/telemetry.rkt` — real `counter`/`histogram`/`gauge` provides (re-export from `dsl/metrics.rkt`), phase 0, verbatim names.
- Tests: `tests/otlp-metrics-test.rkt` (NEW); `compiler/test/test_stdlib_runtime_binding.ml` (auto-covers); lesson file; PG parity checks in the queue/SSE Racket tests.
- Docs: LANGUAGE-SPEC §5.2 (`:168-179`) + grammar (`:2294-2297` vicinity) + stdlib list (`:639`); `manual/tour.md:721-742`; `roadmap/completed/otlp_exporter.md` non-goals cross-ref.

## Non-goals

- Traces/spans, trace-context propagation (separate future roadmap item; different model).
- gRPC/protobuf transport — JSON over HTTP only, matching the logs exporter.
- Prometheus scrape/pull endpoint, exemplars, exponential histograms, observable-callback instruments, UpDownCounter (full OTel API parity is not the bar).
- Custom middleware/hook API for user-defined built-in instrumentation.
- Resolving SEC-TELEMETRY (ambient egress control) — inherited, tracked separately.
- Host/system metrics (CPU, memory, disk, network) — collected at the host by the infra agent (node exporter / OneUptime agent / container runtime), not by the app. Tesl only sees its own process; a `current-memory-use` process gauge is a trivial later add if ever wanted.

## Risks & containment

1. **Cardinality explosion** (worst: user puts an ID in attrs; or route label accidentally = raw path). Contain: route label is `route-spec-operation` only; per-instrument attr-set cap with overflow set + meta-counter; cap covered by a unit test.
2. **Hot-path overhead when disabled.** Contain: single `metrics-active?` boolean check, no timing capture, no allocation when off; assert via the existing perf-sensitive example sweep.
3. **Record path must never block/raise** (same bar as logs). Contain: O(1) registry update under semaphore; export on background thread; closed-port resilience test.
4. **PG queue-depth polling contention** — why depth is deferred; if added, piggyback the existing poller thread (`queue.rkt:845-867`), never a fresh pool lease from the exporter.
5. **Gate confusion** (`tesl-log-active?` vs metrics). Contain: separate flag; a test that `TESL_VERBOSE=0` + metrics-on records metrics without stderr logs, and vice versa.
6. **Collector semantics** (cumulative vs delta, int64-as-string, `timeUnixNano`): follow the OTLP JSON encoding rules already proven in the logs mapping (`telemetry-value->otlp-any-value` `otel.rkt:116-127`); verify against OneUptime once early in Phase 0.

## Open questions (answer inline)

1. **Attrs representation** — `List (String, String)` (proposed; explicit, no parser work) vs a trailing `{ k = v }` block (needs statement-form parsing, big blast radius — recommend against) vs no-attrs overload names (`counterN`?). RECOMMENDATION: `List (String, String)`, pass `[]` when none.
2. **Bare names `counter`/`histogram`/`gauge`** claim common identifiers (import-gated, so only bites importers of Tesl.Telemetry — but `exposing [counter]` then shadows nothing else?). Alternative: dotted `Metric.count`/`Metric.record`/`Metric.set`. RECOMMENDATION: bare, matching the module's existing bare style; verify shadowing behaves via a lesson case.
3. **Ambient vs capability-gated** user instruments. Ambient matches §5.2 and telemetry precedent; a `metricsCap` would be the first observability capability and needs the full cap-map wiring. RECOMMENDATION: ambient.
4. **Metrics default-on when endpoint set?** RECOMMENDATION: yes (`metrics True` default) — the built-in catalog is the headline value; opt-out knob exists.
5. **OneUptime ingestion check** — confirm it accepts OTLP/HTTP+JSON cumulative metrics early (Phase 0), before the catalog work.
