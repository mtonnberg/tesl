# Real OTLP exporter — telemetry to a remote endpoint, not just console

**Status:** DONE (OTLP/HTTP+JSON Logs) · **Effort:** M (OTLP/HTTP+JSON) — L if native protobuf/gRPC is required.
**Refs:** `TESL-REVIEW-EXECUTIVE.md` / `TESL-REVIEW-TECHNICAL.md` §8.2; docs-claim correction `bf0a2b2`;
relocated from `docs_and_small_features_backlog.md` (was D2-OTLP).

## Outcome (implemented 2026-07-02)

A configured telemetry `endpoint` now actually exports events over **OTLP/HTTP+JSON, Logs signal**;
console emission remains available for dev. The previously-inert `endpoint` is wired to a real exporter.

- **New consumer** `make-otlp-http-consumer` in `dsl/otel.rkt` (alongside `make-console-telemetry-consumer`):
  `#:endpoint #:headers #:timeout #:batch-size #:flush-interval-ms`. It enqueues events into a **bounded**
  queue and flushes batches to `<endpoint>/v1/logs`.
- **Single POST path:** reuses `tesl/http-client.rkt`'s `HttpClient.post` (the same client every other
  outbound call uses) via `dynamic-require` — no second HTTP implementation. The egress is kept **ambient**
  (LANGUAGE-SPEC §5.2): the POST runs under a local `httpClient` capability grant, so export is opt-in
  purely by the *presence* of a configured endpoint, not a user-declared capability.
- **Async + bounded + resilient:** a background timer thread flushes every `flush-interval-ms`; a full
  batch (`batch-size`) is flushed immediately. Bounded buffer (10× batch-size), **drop-oldest** overflow
  policy (keep the freshest events). An unreachable/erroring collector NEVER propagates — the emit path is
  never blocked and never raises.
- **Pure mapping** `telemetry-events->otlp-logs-jsexpr` (unit-testable): `service` → `service.name`
  resource attr; each event → one `logRecord` with `timeUnixNano` (ms×1e6, as a string), `body.stringValue`
  = message, `attributes` as OTLP `KeyValue`s (string→stringValue, int→intValue-as-string, real→doubleValue,
  bool→boolValue).
- **Config knobs** added to `init-opentelemetry!` (all optional, additive — existing callers unchanged):
  `#:otlp-headers #:otlp-timeout-ms #:otlp-batch-size #:otlp-flush-interval-ms`. `endpoint "in-memory"`
  (and empty string) means "no remote export".
- **Tests:** `tests/otlp-exporter-test.rkt` — unit (mapping/attribute types), integration (in-process
  localhost OTLP sink asserts the batch POST to `/v1/logs`; self-skips if it cannot bind a port), and
  resilience (closed-port endpoint: emit returns normally, nothing escapes).
- **Docs reconciled:** `example/learn/lesson17-telemetry.tesl` + `LANGUAGE-SPEC.md` §5.2 now state the
  truthful OTLP/HTTP+JSON-Logs export behavior.

## Non-goals (still out of scope)

- Native protobuf or gRPC OTLP transport (HTTP+JSON is the shipped exporter).
- Full spans/traces with propagation (start/end + trace-context) — the model is flat events → Logs.
- Metrics pipeline.

## Refs / source sites

- `dsl/otel.rkt` — `make-otlp-http-consumer`, `telemetry-events->otlp-logs-jsexpr`,
  `telemetry-value->otlp-any-value`, `init-opentelemetry!` (new `#:otlp-*` keywords).
- `tesl/http-client.rkt` — `HttpClient.post` (the shared POST path).
- `tesl/telemetry.rkt` — the surface shim.
- `example/learn/lesson17-telemetry.tesl` — config surface + endpoint comment.
- `tests/otlp-exporter-test.rkt` — the rackunit suite.
