# OpenTelemetry traces — context propagation first, span export second, a user span API never

**Status: IMPLEMENTED 2026-07-30 (drafted the same day, expanded from a three-line ask).
Phase A and Phase B both shipped; Phase C rejected as planned.**

## What landed

Phase A and Phase B were implemented together because Phase A alone leaves the
original ask ("support traces") unmet — nothing is exported — while Phase B costs
nothing when off, which is its default.

**New modules**

- `dsl/trace-context.rkt` — the Phase-A core. Crypto-random 16/8-byte ids
  (`crypto-random-bytes`, all-zero regenerated), a `traceparent` parser that is
  TOTAL over arbitrary strings (malformed ⇒ `#f` ⇒ start a fresh trace, never a
  raise on a request path), W3C version rules (`ff` rejected, version 00 exactly
  four fields, unknown future versions accepted with extra fields ignored),
  `tracestate` pass-through behind a printable-ASCII/512-char shape gate, the
  ambient `current-trace-ctx` parameter, and parent-respecting head sampling.
- `dsl/traces.rkt` — the Phase-B span recorder + `/v1/traces` OTLP/HTTP+JSON
  exporter, with the never-raise / never-block / bounded-buffer (drop-oldest,
  2048) discipline of the other two signals and the same cooperative
  exporter-generation shutdown as `dsl/metrics.rkt`. Buffering runs in ATOMIC
  MODE, not under a semaphore, for the kill-safety reason `dsl/metrics.rkt`
  documents.
- `dsl/otlp-value.rkt` — extracted from `dsl/otel.rkt`: the ONE OTLP
  attribute-value renderer, now shared by Logs and Traces. This is the structural
  answer to risk 2 below — a signal that renders its own values is a `secret`
  redaction hole waiting to be added; `dsl/otel.rkt` re-provides the two
  historical names so `tests/secret-runtime-tests.rkt` still measures them.

**Wiring (no new call sites anywhere)**

- `dsl/web.rkt` `dispatch-request` — parses inbound `traceparent`/`tracestate`,
  runs the whole request under the ambient context (`parameterize`, never an
  imperative set, so a keep-alive thread cannot carry one request's trace into
  the next), and brackets it in a SERVER span whose name is refined to
  `METHOD operation` after the match loop (never the raw path). `request.id` is
  untouched.
- `dsl/otel.rkt` `emit-telemetry-event!` — appends `trace.id`/`span.id`/
  `trace.sampled` to EVERY event, rather than baking them into `route-context`:
  the innermost active span wins, and a non-HTTP entry point (queue worker, agent
  run) gets the same correlation with no second call site. The OTLP log record
  additionally LIFTS them into the first-class `traceId`/`spanId`/`flags` fields,
  which is what a collector actually joins on.
- `tesl/http-client.rkt` — `traceparent` (+ inbound `tracestate`) injected on
  every outbound call, inside the CLIENT span so the downstream service parents on
  it; a caller-supplied `traceparent` wins and is never overwritten; values
  re-checked through `http-header-field-safe?`.
- `dsl/sql.rkt` — one CLIENT span per statement from `with-sql-capture` (the same
  seam the duration histogram uses), plus a `db.pool.lease` INTERNAL span for the
  connection WAIT. `count-of` is called once and shared with the existing capture.
- `tesl/queue.rkt`, `tesl/agent-provider.rkt`, `tesl/agent.rkt`, `tesl/cache.rkt`
  — CONSUMER span per job attempt, CLIENT span per LLM call (with token usage),
  INTERNAL span per agent tool execution, INTERNAL spans for cache get/set.
- `compiler/lib/checker.ml` + `compiler/lib/emit_racket.ml` — `traces Bool` and
  `traceRatio Float` on `initTelemetry`; the valueless-keyword hard error from the
  metrics review covers the new names automatically.
- All three exporters POST with `current-trace-ctx` parameterized to `#f`: without
  it, exporting a span is itself an instrumented outbound call, which buffers a
  span, which the next flush exports — a self-feeding loop.

**Tests**

- `tests/trace-context-test.rkt` — parse/format totality over hostile input, ids,
  parent-respecting sampling, log correlation (attributes AND the lifted OTLP
  `traceId`/`spanId`/`flags` fields), outbound injection incl. "a caller-supplied
  `traceparent` wins".
- `tests/otlp-traces-test.rkt` — recording gates, the parent/child tree, the
  exactly-once body contract, the ring buffer's drop-oldest bound, the pure OTLP
  mapping, an end-to-end `dispatch-request` tree (SERVER + outbound CLIENT child),
  the queue link, the db span (including "40 sibling spans" and "no bound
  parameter, secret or not, ever reaches the collector"), a localhost-collector
  integration tier, closed-port resilience, and the `traces False` /
  `traces True` + in-memory gates.
- `tests/trace-propagation-tests.tesl` — the Tesl-side property: propagation is
  INVISIBLE. A well-formed, absent, malformed or hostile inbound `traceparent`
  changes nothing about an endpoint's behaviour, and injection does not disturb
  the outbound-HTTP stub surface or its call count.
- `example/learn/lesson77-traces.tesl` (+ committed `.rkt`, `test` and `api-test`
  blocks). Both Racket suites are registered in `ci.sh`'s Racket-suite phase.

`with-sql-capture` is now exported from `dsl/sql.rkt` so the db span's attribute
discipline is testable without a live PostgreSQL — that discipline is a security
property (a `secret` column's bound parameter really is the secret), so it should
not be reachable only through an optional-dependency phase.

## Decisions taken on the open questions

1. **Ship Phase A alone?** No — both shipped. Phase A is what makes the logs
   joinable, but "support traces" is not true until spans exist, and `traces False`
   makes Phase B free until asked for.
2. **Queue propagation — job-row column or skipped?** NEITHER: the `traceparent`
   rides the payload jsonb ENVELOPE beside the reserved `__type` key, so there is
   NO migration and a deployment whose `tesl_jobs` predates traces works unchanged.
   It still crosses replicas and restarts, because it is in the row. Risk 4 is
   therefore closed rather than accepted.
3. **Does OneUptime accept OTLP/HTTP+JSON traces?** Unverified (no network here) —
   the transport is byte-identical in shape to the `/v1/logs` and `/v1/metrics`
   paths already in production, and the endpoint is the standard `/v1/traces`.
4. **Does `db.statement` cross a line the log sink does not?** YES, treated as
   such: db spans carry operation + table + row count by default, and the
   parameterized statement only under `TESL_TRACE_DB_STATEMENT=1`. Bound PARAMS
   never reach a span at all.

Risk 3 (cross-thread context) is handled by carrying the queue link in DATA and
rebuilding a root context in the worker; SSE deliberately produces no spans (it is
matched before `dispatch-request` and its stream outlives the request extent).

## Two decisions the plan did not anticipate

1. **The propagated `sampled` bit is independent of `traces`.** Step 4 said
   "`traceRatio` default 1.0 in Phase A because nothing is exported yet"; the
   reason that matters is sharper than "nothing is exported". If span export off
   meant `sampled = 0` on every outbound header, a Tesl app would silence the
   tracing of every parent-respecting service DOWNSTREAM merely by sitting in the
   request path — the opposite of the citizenship goal that justified Phase A. So
   the ratio alone decides the bit, and "do WE record" is a separate question
   asked against `traces-active?`.
2. **The span bracket must guard setup but NOT the body.** A single
   `with-handlers` around both (the first implementation) catches the body's own
   exception, and its "instrumentation must degrade to no span" recovery then runs
   the body A SECOND TIME — a duplicate outbound POST or a duplicate INSERT on any
   failing traced call. Setup and body are now separately bracketed, and
   `tests/otlp-traces-test.rkt` pins "the body runs exactly once" on both the
   success and failure paths, for both brackets.

## Original ask

> Today we support open telemetry logs and metrics but (as far as I know) we do not support
> traces. Goals: support traces. Open questions: how would that look like, is it desirable?

## How a developer uses this

The whole point of the design below: **the developer-facing surface is one keyword.** Everything
else is automatic, because the spans worth having are framework spans and the framework already
brackets them.

| Phase | What the developer writes | What the developer gets |
|-------|---------------------------|-------------------------|
| A | *nothing* | existing logs joinable to the caller's trace; outbound chain no longer broken |
| B | `traces True` (+ `traceRatio`) on `initTelemetry` | per-request span tree — the N+1 answer |
| C | *n/a — rejected* | use the `telemetry` statement, now trace-stamped |

### Phase A is not a feature to learn — it is a fix to logs they already have

Unchanged `main`:

```tesl
main() -> App requires [] =
  let _ = initTelemetry service "todo-api" endpoint "https://otel.example.com" console False
  App { database: TodoDb, api: TodoServer, port: 8080 }
```

An upstream caller (gateway, another team's service) sends:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

Every log record from that request gains the ids, with no new call sites, because `route-context`
is appended to every emitted event:

```jsonc
// today
{"message":"note created","attributes":{"request.id":"req-1753...-84213","http.path":"/notes","user.id":"u_7"}}
// Phase A
{"message":"note created","attributes":{"request.id":"req-1753...-84213","http.path":"/notes","user.id":"u_7",
  "trace.id":"4bf92f3577b34da6a3ce929d0e0e4736","span.id":"a1b2c3d4e5f60718","trace.sampled":true}}
```

Paste that `trace.id` into the trace UI and the caller's trace and our logs are one timeline. No
inbound `traceparent` → a fresh trace id is minted, same fields present either way.

Outbound calls propagate it. This existing line:

```tesl
let resp = httpGet "https://billing.internal/invoice/42" [] requires [net]
```

carries `traceparent` from the ambient context, so the downstream service continues the same trace.
A caller-supplied `traceparent` header wins — never overwritten.

### Phase B is one keyword, and the developer only *reads* the result

```tesl
let _ = initTelemetry
          service "todo-api"
          endpoint "https://otel.example.com"
          console False
          metrics True
          traces True          # default False — per-request volume and egress
          traceRatio 0.05      # head sampling, parent-respecting
```

They then look at their collector, never at Tesl code:

```
SERVER  POST /notes                      142ms
├─ CLIENT  db.query notes (INSERT)         3ms
├─ CLIENT  db.query tags (SELECT)          2ms
├─ CLIENT  db.query tags (SELECT)          2ms   ← 38 more of these
└─ CLIENT  POST billing.internal          61ms
```

That tree is the N+1 question — the one thing our logs and metrics cannot answer. It costs the user
no annotation because each child comes from a `with-*` wrapper that already exists. `traces False`
(the default) allocates no spans and sends no extra bytes.

### Phase C: the inner boundary already has a spelling

Not `span "..."`, not `startSpan`. The statement they already write:

```tesl
let _ = telemetry "pricing recalculated" [ "sku" => sku, "tier" => tier ]
```

Phase A stamps that event with `trace.id`/`span.id`, so it lands inside the request's span in the
trace UI. Free, no new surface.

## What is actually true today (mapped 2026-07-30)

**Nothing trace-shaped exists.** `grep -rn "traceparent\|trace_id\|span_id"` over `dsl/`, `tesl/`,
`compiler/` is empty. Traces are an explicit non-goal in `dsl/otel.rkt:117`, LANGUAGE-SPEC §5.2, and
`roadmap/completed/opentelemetry_metrics.md:149`.

Everything a trace feature rides on is already built for logs and metrics:

- **Per-request context is already a Racket parameter.** `current-telemetry-context`
  `dsl/otel.rkt:50`, extended by `call-with-telemetry-context` (:403-405), established once per
  request in `dispatch-request` as `route-context` (`dsl/web.rkt:1818-1831, :1847`) and appended to
  every event (`otel.rkt:413`). `parameterize` nests with the call stack and is inherited by child
  threads — span-context semantics for free, in-process.
- **`request.id` is not a trace id.** `(format "req-~a-~a" (current-seconds) (random 1000000))`
  `dsl/web.rkt:1804-1805` — not 16 bytes, not hex, not W3C, and `random` is unseeded per replica.
- **Every hook a span needs is already a `with-*` wrapper**, so the start/end pair the flat event
  model lacks needs no new call sites: `with-sql-capture` `dsl/sql.rkt:2031-2035` (~14 exec sites),
  `connection-pool-lease` (:2789-2792), `do-http-request` `tesl/http-client.rkt:523-541`, the queue
  `handler-fn` wrap (`tesl/queue.rkt:759, :797`), `call-provider` `tesl/agent-provider.rkt:504-513`,
  `run-tool-call` `tesl/agent.rkt:394`, `tesl/cache.rkt` get/set — the same points metrics instruments.
- **Exporter machinery is reusable verbatim.** `make-otlp-http-consumer` `dsl/otel.rkt:228-285`
  (bounded buffer, drop-oldest, background flusher, never raises); `otlp-logs-url` :168-172 needs a
  `/v1/traces` sibling; `dsl/metrics.rkt` is the worked example of a second signal in
  `init-opentelemetry!` (:287-335).
- **Outbound HTTP injects nothing.** `do-http-request` sends only caller-supplied headers, so
  calling another service breaks the chain today.
- **Test seam exists.** `current-outbound-http-hook` (`tesl/private/http-stub.rkt:38`,
  `dsl/test-support.rkt:321`) plus the localhost-collector pattern in
  `tests/otlp-exporter-test.rkt` / `tests/otlp-metrics-test.rkt`.

## Is it desirable? — critically

**Two of the four usual justifications do not apply to Tesl. Two do.**

- ✗ *"See how a request flows across services."* Tesl apps are deliberately single-process monoliths
  (one `App`, one `server`, horizontal replicas of one binary — see `lesson76-sessions.tesl`). No mesh.
- ✗ *"Know whether the app is healthy / how slow it is."* Already answered cheaper and at lower
  volume by the metrics catalog (`http.server.request.duration`, `db.client.operation.duration`,
  `tesl.queue.job.duration`, `gen_ai.*`).
- ✓ *"Which of the 40 queries in this one slow request was the problem, and what called it."*
  Metrics aggregate it away by construction; logs have no parent/child structure. The N+1 question —
  the one question a Tesl user cannot answer with anything we ship.
- ✓ *"Be a citizen in someone else's trace."* We receive `traceparent` and drop it, so the caller's
  trace shows a hole where our app is and our logs cannot be joined to it. A
  correctness-of-observability bug that costs nearly nothing and exports no spans.

**The cheap half is worth more than the expensive half.** Phase A is a few hundred lines and makes
every already-shipped log usable in a trace UI. Phase B carries the real cost — per-request,
unaggregated volume orders of magnitude above logs+metrics, on the ambient egress path
(SEC-TELEMETRY, `roadmap/completed/architecture_trajectory.md:13-14`) — so it defaults off. Phase C
is where the OTel SDK surface explodes (span kinds, links, events, status, baggage, samplers,
processors) for spans the framework already emits; **reject outright**, as the metrics item rejected
full OTel API parity.

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
