# Backend comparison benchmarks

The same Tesl program, compiled by both backends and driven by the same in-process harness, so
the numbers differ by RUNTIME rather than by what is being measured or how.

## What is here

| file | what it measures |
|---|---|
| `BenchApi.tesl` | light load (200 rps) — dominated by the harness's timer granularity on both backends, so it says little about the runtime; kept because it is the shape a lesson uses |
| `BenchLoad.tesl` | 2 000 rps for 5 s — the rate where the Racket runtime saturates |
| `BenchCeiling.tesl` | 20 000 rps for 5 s — Go still holds the rate here; its ceiling is above this |

Two request paths in each, both free of sleeps and outbound calls, so the measurement is the
runtime's own cost:

* `GET /count` — routing, a Memory-backend read, response encoding
* `POST /notes` — routing, JSON DECODE of a body, a String operation, response encoding

The load-tested POST deliberately does NOT insert: a load-test body is a static template, so
every request would carry the same primary key and every insert after the first would fail. The
run would then measure the duplicate-key path at a 100 % error rate rather than the request path.
Insert correctness lives in an api-test instead, which is where a one-shot assertion belongs.

## Running them

    # Go
    tesl --backend go bench/BenchLoad.tesl --out /tmp/benchload_go
    cd /tmp/benchload_go && /usr/bin/time -v go test ./internal/teslmodbenchload -v -run TestTeslLoad

    # Racket
    tesl bench/BenchLoad.tesl > /tmp/benchload.rkt
    /usr/bin/time -v raco test /tmp/benchload.rkt

`go test -short` skips load tests, so an ordinary test run does not pay for them.

## Reading the numbers honestly

* Latency is measured from the SCHEDULED send time on both backends (an open model), so a runtime
  that cannot keep up shows it as growing latency rather than as a lower request count.
* At low rates both backends' p50 is a floor set by the scheduler's sleep granularity (~1 ms),
  not by the request. Only a rate high enough to saturate says anything about the runtime.
* Peak RSS from `/usr/bin/time -v` is the whole TEST PROCESS: `go test`'s toolchain or Racket's
  VM plus the harness. The Go test BINARY alone is a much smaller number, and it is the honest
  one for "what the runtime costs" — but it has no Racket counterpart, so the toolchain-to-
  toolchain pairing is the comparable one.
