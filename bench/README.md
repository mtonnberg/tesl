# Runtime benchmarks

Tesl programs compiled to Go and driven by the generated in-process load-test harness.

## What is here

| file | what it measures |
|---|---|
| `BenchApi.tesl` | light load (200 rps), dominated by the harness timer granularity; kept because it matches the lesson shape |
| `BenchLoad.tesl` | 2,000 rps for 5 s |
| `BenchCeiling.tesl` | 20,000 rps for 5 s, used to probe the runtime ceiling |

Two request paths in each, both free of sleeps and outbound calls, so the measurement is the
runtime's own cost:

* `GET /count` — routing, a Memory-backend read, response encoding
* `POST /notes` — routing, JSON DECODE of a body, a String operation, response encoding

The load-tested POST deliberately does NOT insert: a load-test body is a static template, so
every request would carry the same primary key and every insert after the first would fail. The
run would then measure the duplicate-key path at a 100 % error rate rather than the request path.
Insert correctness lives in an api-test instead, which is where a one-shot assertion belongs.

## Running them

Run one benchmark through the public CLI:

    tesl test --test-kind load-test bench/BenchLoad.tesl

Run all benchmark sources:

    for file in bench/*.tesl; do tesl test --test-kind load-test "$file"; done

For process-level CPU/RSS measurements, build once and time the generated load test directly:

    tesl compile bench/BenchLoad.tesl --out /tmp/benchload
    (cd /tmp/benchload && /usr/bin/time -v go test ./... -run TestTeslLoad -count=1)

`go test -short` skips load tests, so an ordinary test run does not pay for them.

## Reading the numbers honestly

* Latency is measured from the SCHEDULED send time on both backends (an open model), so a runtime
  that cannot keep up shows it as growing latency rather than as a lower request count.
* At low rates p50 is a floor set by the scheduler's sleep granularity (~1 ms),
  not by the request. Only a rate high enough to saturate says anything about the runtime.
* Peak RSS from `/usr/bin/time -v go test` includes the Go test toolchain and harness. Build the
  test binary first when measuring runtime-only RSS.
