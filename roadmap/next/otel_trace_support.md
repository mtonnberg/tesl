# OpenTelemetry traces — context propagation first, span export second, a user span API never

**Status: PLANNED (drafted 2026-07-30, expanded from a three-line ask)**

## Original ask

> Today we support open telemetry logs and metrics but (as far as I know) we do not support
> traces. Goals: support traces. Open questions: how would that look like, is it desirable?

## What is actually true today (mapped 2026-07-30)

**Nothing trace-shaped exists.** `grep -rn "traceparent\|trace_id\|span_id"` over `dsl/`,
`tesl/`, `compiler/` is empty (the only hits are a `b3` local in `tests/bench/proof-overhead.rkt`
and a literal `'traceId "trace-9"` attribute in `tests/secret-runtime-tests.rkt`). Traces are an
explicit non-goal in three places: `dsl/otel.rkt:117`, LANGUAGE-SPEC §5.2, and
`roadmap/completed/opentelemetry_metrics.md` Non-goals (:149).

What a trace feature would ride on — all of it already built for logs and metrics:

- **Per-request context is already a Racket parameter**: `current-telemetry-context`
  `dsl/otel.rkt:50`, extended by `call-with-telemetry-context` (:403-405), established once per
  request in `dispatch-request` with `route-context` = `request.id`, `http.method`, `http.path`,
  `operation`, `user.id` (`dsl/web.rkt:1818-1831, :1847`). Every emitted event appends it
  (`otel.rkt:413`). A `parameterize` nests with the call stack and is inherited by child threads —
  which is exactly span-context semantics, for free, inside one process.
- **`request.id` is not a trace id**: `(format "req-~a-~a" (current-seconds) (random 1000000))`
  `dsl/web.rkt:1804-1805` — not 16 bytes, not hex, not W3C, and `random` is not seeded per replica
  so two replicas booting in the same second can collide.
- **Every hook a span needs is already a `with-*` wrapper**, so the start/end pair the flat event
  model lacks is available without new call sites: `with-sql-capture` `dsl/sql.rkt:2031-2035`
  (~14 exec sites), `connection-pool-lease` (:2789-2792), `do-http-request`
  `tesl/http-client.rkt:523-541`, the queue `handler-fn` wrap (`tesl/queue.rkt:759, :797`),
  `call-provider` `tesl/agent-provider.rkt:504-513`, `run-tool-call` `tesl/agent.rkt:394`,
  `tesl/cache.rkt` get/set. These are the same points the metrics catalog already instruments.
- **Exporter machinery is reusable verbatim**: `make-otlp-http-consumer` `dsl/otel.rkt:228-285`
  (bounded buffer, drop-oldest, background flusher, never raises), `otlp-logs-url` :168-172 needs
  only a `/v1/traces` sibling, and `dsl/metrics.rkt` is the worked example of adding a second
  signal to `init-opentelemetry!` (:287-335).
- **Outbound HTTP injects nothing**: `do-http-request` sends only caller-supplied headers, so a
  Tesl app calling another service today breaks the trace chain.
- **Test seam exists**: `current-outbound-http-hook` (`tesl/private/http-stub.rkt:38`,
  `dsl/test-support.rkt:321`) plus the localhost-collector pattern in
  `tests/otlp-exporter-test.rkt` / `tests/otlp-metrics-test.rkt`.

## Is it desirable? — critically

**Two of the three usual justifications do not apply to Tesl, and one does.**

- ✗ *"See how a request flows across services."* Tesl apps are deliberately single-process
  monoliths (one `App`, one `server`, horizontal replicas of the same binary — see the stateless
  session argument in `example/learn/lesson76-sessions.tesl`). There is no mesh to trace.
- ✗ *"Know whether the app is healthy / how slow it is."* Already answered, cheaper and at lower
  volume, by the metrics catalog (`http.server.request.duration`, `db.client.operation.duration`,
  `tesl.queue.job.duration`, `gen_ai.*`).
- ✓ *"Which of the 40 queries in this one slow request was the problem, and what called it."*
  Metrics aggregate this away by construction and logs have no parent/child structure. This is the
  N+1 question, and it is the single question a Tesl user cannot answer today with anything we ship.
- ✓ *"Be a citizen in someone else's trace."* A Tesl app behind an API gateway / another team's
  service receives `traceparent` and drops it, so the caller's trace shows a hole where our app is
  and our own logs cannot be joined to it. This is a correctness-of-observability bug that costs
  almost nothing to fix and does not require exporting a single span.

**Therefore: the cheap half is worth more than the expensive half.** Correlating existing logs to a
trace id (Phase A) is a few hundred lines and makes every already-shipped log usable in a trace
UI. Exporting spans (Phase B) is where the real cost is — per-request, unaggregated volume, orders
of magnitude above logs+metrics, on the ambient egress path (SEC-TELEMETRY,
`roadmap/completed/architecture_trajectory.md:13-14`) — and it must default off or heavily sampled.
A user-facing span API (Phase C) is where the OTel SDK surface explodes (span kinds, links, events,
status, baggage, samplers, processors) for a feature the language's own instrumentation already
covers; **recommend rejecting it outright**, as the metrics item rejected full OTel API parity.

**Do Phase A. Do Phase B only if a user asks the N+1 question. Do not do Phase C.**

## Phase A — W3C trace context (no span export, independently shippable)

Deliverable: the app participates in traces and every log line is joinable to one.

1. `dsl/trace-context.rkt` (new, tiny, no net code): a 16-byte trace id + 8-byte span id
   generator over `crypto-random-bytes` (**not** `random` — `request.id`'s current weakness),
   `traceparent` parse/format per W3C (`00-<32 hex>-<16 hex>-<flags>`, reject malformed → start a
   new trace, never raise), and `tracestate` pass-through unmodified.
2. `dsl/web.rkt:1804-1831`: parse inbound `traceparent` from `dsl-request-headers` (names already
   lowercased). Put `trace.id` / `span.id` / `trace.sampled` into `route-context`, so **every
   existing log record gains them with zero new call sites**. Keep `request.id` (it is in user-facing
   error output); do not redefine it.
3. `tesl/http-client.rkt` `do-http-request`: inject `traceparent` (+ `tracestate`) from the ambient
   context on every outbound call, unless the caller already supplied one. Guard with the existing
   `http-header-field-safe?` (:52).
4. Sampling decision made once per request (parent-respecting, `traceRatio` default 1.0 in Phase A
   because nothing is exported yet) and carried in the context.
5. `tesl/queue.rkt` `enqueue!`: persist the current `traceparent` on the job row so a job's logs
   join the request that enqueued it. **This is a schema change to the queue table** — check the
   migration story for both backends before committing to it; if it is not free, defer to Phase B.

*Exit:* Racket unit tests for parse/format/reject (malformed, wrong version, all-zero ids); an
api-test asserting an inbound `traceparent` reaches the log attributes unchanged and that a stubbed
outbound call carries one; `./compile-examples.sh` green. No new Tesl surface, no new docs beyond a
LANGUAGE-SPEC §5.2 sentence.

## Phase B — server + internal span export (only on demand)

1. `dsl/traces.rkt`: a span recorder with the same never-raise/never-block discipline as
   `dsl/metrics.rkt` — start/end capture, ring buffer, OTLP `ExportTraceServiceRequest` JSON to
   `<endpoint>/v1/traces`, pure `spans->otlp-jsexpr` mapped unit-test-first like
   `telemetry-events->otlp-logs-jsexpr` (`otel.rkt:143-163`).
2. One `SERVER` span per request in `dispatch-request`; `CLIENT`/`INTERNAL` children at the
   `with-*` wrappers listed above. No new call sites — each wrapper already brackets the work.
3. `initTelemetry` gains `traces Bool` (**default `False`** — unlike `metrics`, because volume and
   egress are per-request) and `traceRatio Float`. Checker keyword validation
   `checker.ml:2505-2523`, emitter mapping `emit_racket.ml:2107-2159`; the valueless-keyword hard
   error from the metrics review (finding 2) covers the new names automatically.
4. Attribute discipline copied from metrics: low-cardinality names (`route-spec-operation`, never
   the raw path); `db.statement` is the parameterized SQL already condensed by
   `tesl-log-sql!` `tesl/logging.rkt` — **and `render-param`'s secret redaction must apply on the
   span path too**, or spans become the one sink that leaks a `secret` column.

*Exit:* localhost collector receives a well-formed parent/child tree for a request that does N
queries and one outbound call; closed-port resilience; `traces False` proves zero span allocation;
new `example/learn/lessonXX-traces.tesl`; LANGUAGE-SPEC §5.2 + grammar + stdlib list.

## Non-goals

- **User-facing `span` / `startSpan` API, or a `trace { }` statement form** — rejected. Same
  blast-radius argument the metrics item made against a `metric` statement, and here it buys less:
  the interesting spans are framework spans. If a user needs an inner boundary, they already have
  `telemetry` events, which Phase A now stamps with `trace.id`/`span.id`.
- Baggage, span links, span events, exponential/tail sampling, span processors/exporters as a
  plugin surface, OTel `Tracer` API parity.
- gRPC/protobuf transport — JSON over HTTP, matching logs and metrics.
- Redefining or removing `request.id`.
- Resolving SEC-TELEMETRY (ambient egress) — inherited, tracked separately, but note traces make it
  materially worse and that is an argument for `traces False` by default.
- Trace-based test assertions (asserting a span tree from an api-test).

## Risks

1. **Volume/cost.** Unaggregated per-request export at a real endpoint. Contain: default off,
   head sampling with a parent-respecting ratio, and state the cost in the lesson.
2. **Secret leakage via span attributes.** Spans are a new rendering sink and the redaction rules
   live at the old ones (`tesl/logging.rkt` `render-param`, `telemetry-value->jsexpr`'s
   `current-redact-secrets?` `otel.rkt:94-96`). Contain: spans reuse those functions, never format
   their own values; add a `secret`-in-span-attribute regression test alongside
   `tests/secret-runtime-tests.rkt`.
3. **Cross-thread context.** `parameterize` is inherited by `thread` children, but the queue and
   SSE paths outlive the request (`handle-sse-request`'s streaming loop deliberately runs outside
   the capability extent — see F6 in `roadmap/completed/session_cookie_security_followups.md`). A
   span that outlives its parent's extent must be *linked by ids carried in data*, not by ambient
   context. Decide per hook, and never let a stale ambient parent attach a worker's span to an
   unrelated request.
4. **Queue schema change** for propagation (Phase A step 5) — the only migration in this item.
5. **Clock.** Span timing must use `current-inexact-milliseconds` (monotonic-ish, already the
   metrics choice), not wall clock, or a clock step produces negative durations collectors reject.

## Open questions

1. **Ship Phase A alone?** RECOMMENDATION: yes — it is independently valuable (log correlation +
   upstream citizenship) and does not commit us to span volume.
2. **Queue propagation via a job-row column** (needs a migration, works across replicas and restarts)
   **or skipped entirely in Phase A**? RECOMMENDATION: skip in A, land with B, so A stays
   migration-free.
3. **Does OneUptime accept OTLP/HTTP+JSON traces?** Verify before Phase B, exactly as open question
   5 of the metrics item required for `/v1/metrics`.
4. **Does `db.statement` on a span cross a line the log sink does not?** Logs are typically
   short-retention and operator-only; traces get shared into dashboards. Consider
   name-and-table-only by default with the statement behind an explicit knob.
