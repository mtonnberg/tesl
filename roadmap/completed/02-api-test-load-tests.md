# API Tests — Track C: Load Tests

## Context

Track C builds directly on the `api-test` foundation from `roadmap/completed/02-api-test.md`
(Tracks A and B). The `load-test` block reuses the same `seed { }` syntax, the same
request builder syntax (`get`, `post`, `put`, `delete`), the same `Tesl.ApiTest` import,
and the same in-memory database isolation. Everything that differs is in the scheduler,
the measurement infrastructure, and the assertion model.

**Timing:** Track C is deferred until after the compiler rewrite
(`roadmap/now/03-compiler-frontend-rewrite.md`). Implement it in OCaml from the start
rather than building it in Python and then porting it.

---

## Why load tests belong in the language

Inline load tests that reuse the same seed and request syntax as example-based tests close
the gap between "does it work?" and "does it stay fast?" without a separate tool or process.
Because the load test runs against the same in-memory server with the same dependency
injection as the API tests, performance regressions are caught on the same `tesl test` run
that catches correctness regressions — no separate CI step, no separate baseline service.

---

## Syntax

```tesl
load-test "create book throughput" for BookServer
  rate 200rps
  duration 30s
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-load",
      email:     "load@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
  }

  post "/books"
    cookie "session=user-load"
    body { "title": "bench", "authorId": "author-1" }

  assert p99 < 200ms
  assert p95 < 80ms
  assert errorRate < 0.01
  assert throughput > 150rps
}

load-test "list books regression guard" for BookServer
  rate 100rps
  duration 20s
  baseline "main"
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-load",
      email:     "load@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
  }

  get "/books" cookie "session=user-load"

  assert p95 < 50ms
  assert regressionVsBaseline p95 < 1.2
}
```

**Keywords specific to `load-test` (not present in `api-test`):**

| Keyword | Required | Description |
|---------|----------|-------------|
| `rate Nrps` | Yes | Target arrival rate (open workload model) |
| `duration Ns` | Yes | How long to run after warm-up ends |
| `baseline "label"` | No | Compare against stored baseline |
| `assert ...` | No | Post-run assertions on histogram values |

`seed { }`, request builders, and `requires [...]` are inherited from the api-test
foundation and work identically.

---

## Load test design

### Workload model — open (rate-based)

The proposal uses an **open workload model**: requests arrive at a fixed target rate
(`rate 200rps`) independent of how long previous requests take. This is the correct model
for public HTTP APIs, where new clients arrive regardless of server latency.

The `concurrency N` parameter from the earlier proposal is replaced by `rate Nrps`. An
optional `maxConcurrency N` cap can be added to prevent unbounded queue growth during
saturation, but the primary control is arrival rate.

*Alternative considered: `concurrency N` (closed model). Rejected because closed models
have a built-in negative feedback loop — the tester slows down as the server slows down —
producing optimistically biased latency distributions (coordinated omission).*

### Coordinated omission

Requests are scheduled on a fixed wall-clock schedule derived from the target rate. If a
request cannot be sent on time because the previous request has not yet returned, the
scheduled send time is still recorded as the start time for latency measurement. This means
queue buildup appears in the latency numbers rather than being hidden by the tester's own
backpressure.

### Warm-up and steady-state detection

Before recording measurements, the harness runs a warm-up phase. Warm-up ends when the p99
latency over a 2-second sliding window has a coefficient of variation below 5% for three
consecutive windows (steady state), or after a maximum of 30 seconds, whichever comes first.
Results from the warm-up phase are discarded.

This detects Racket JIT warm-up, connection pool establishment, and OS-level scheduling
instability without requiring a hard-coded request count.

### Latency measurement — HDR Histogram

All request latencies are recorded in an HDR Histogram. The implementation must use the
canonical HdrHistogram library (via a Racket FFI binding or a faithful port) — not a custom
implementation. HDR Histograms provide constant relative precision across the full range
(nanoseconds to minutes) with a fixed, small memory footprint, making them correct for tail
latency measurement.

After the run the harness reports p50, p95, p99, p99.9, min, max, and total request count.
Assertions (`assert p99 < 200ms`) are evaluated against these values.

### Baseline comparison

When `baseline "label"` is specified, the harness compares the current run's latency
distribution to a stored baseline using Mann-Whitney U (non-parametric, no normality
assumption).

**Baseline storage.** Baselines are stored as JSON files in a `.tesl-baselines/` directory
at the repository root. Each baseline file is named `{test-name}-{label}.baseline.json` and
contains the raw HDR Histogram bucket data. These files should be committed to version
control so CI comparisons are reproducible.

**Bootstrap.** If no baseline file exists for the given label, the first run creates it
automatically and the test passes (no comparison to make). A message is printed:
`baseline "main" created — future runs will compare against this`.

**Update workflow.** Run `tesl test --update-baseline` to overwrite existing baselines with
the current run's measurements. This is the explicit opt-in for "this regression is
intentional."

**Minimum sample size.** Mann-Whitney U requires at least 20 samples per distribution for
meaningful results. If the `duration` limit is reached with fewer than 20 completed requests
in either distribution, the comparison is skipped and a warning is emitted. The absolute
assertions (`assert p99 < 200ms`) still run.

**Regression assertion syntax.** `assert regressionVsBaseline p95 < 1.2` passes if the
Mann-Whitney test finds no statistically significant difference at the 0.05 level, OR if the
current p95 is less than 1.2× the baseline p95. Both conditions are reported separately in
the output.

### Observer effect

Load tests run the harness and the server in the same process. This is acceptable for
regression detection (comparing the same binary against itself across branches) but means
absolute latency numbers include harness overhead. The test output notes this: *"measurements
include in-process harness overhead; do not use as absolute production latency estimates."*

Out-of-process load testing (separate process or separate machine) is a future improvement
for production capacity planning. The in-process model is the right starting point.

---

## Compilation strategy

`load-test` blocks compile to Racket inside the `module+ test` submodule alongside
`api-test` blocks. The generated code:

1. Acquires the server value from the same module.
2. Executes the `seed { }` block against the in-memory store directly.
3. Wraps the block in `call-with-fresh-memory-db`.
4. Runs the open-model scheduler loop, recording each request latency to the HDR Histogram.
5. Evaluates `assert` expressions against the histogram values.
6. If `baseline "label"` is present, loads the stored baseline and runs Mann-Whitney U.

New Racket runtime primitives needed (beyond what Track A+B already provides):

- `dsl/load-test.rkt` — HDR Histogram recorder and open-model scheduler
- `dsl/baselines.rkt` — baseline JSON read/write

---

## Parser additions

The following top-level form is added alongside `parse_api_test_block` (Track A):

- `parse_load_test_block` — parses `load-test "name" for Server rate N duration T
  [baseline L] { seed? request assert* }`.

Added as a top-level form alongside `parse_test_block` and `parse_api_test_block` in the
compiler dispatch.

---

## Deferred

- **Out-of-process load testing.** Separate process/machine for absolute latency
  measurements free of harness overhead. The current in-process model is sufficient for
  regression detection.
- **SSE load testing.** Load-testing SSE endpoints (many concurrent subscribers) requires
  different infrastructure than HTTP load testing. Deferred to a future extension.

---

## Implementation plan

Depends on Track A and B being complete and the OCaml compiler rewrite being done.

| Step | What | Notes |
|------|------|-------|
| C1 | `dsl/load-test.rkt`: HDR Histogram recorder, open-model scheduler, steady-state detection | Use canonical HdrHistogram; scheduler tracks scheduled-minus-actual send time |
| C2 | Parser/compiler: `parse_load_test_block`, `emit_load_test_block` | `rate`, `duration`, `baseline`, `assert` |
| C3 | `dsl/baselines.rkt`: read/write `.tesl-baselines/`, Mann-Whitney U comparison | Minimum 20 samples check |
| C4 | `tesl test --update-baseline` CLI flag | |

---

## Example

```tesl
load-test "list todos at scale" for TodoServer
  rate 150rps
  duration 30s
  baseline "main"
  requires [dbWrite, time] {
  seed {
    insert User {
      id:        "user-load",
      email:     "load@example.com",
      role:      Member,
      createdAt: nowMillis()
    }
  }

  get "/todos" cookie "session=user-load"

  assert p99 < 300ms
  assert p95 < 100ms
  assert errorRate < 0.001
  assert throughput > 100rps
  assert regressionVsBaseline p95 < 1.15
}
```
