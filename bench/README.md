# Runtime benchmarks

Tesl programs compiled to Go, driven by the generated load-test harness or a real HTTP client.

## What is here

| file | what it measures |
|---|---|
| `BenchApi.tesl` | light load (200 rps), dominated by the harness timer granularity; kept because it matches the lesson shape |
| `BenchLoad.tesl` | 2,000 rps for 5 s |
| `BenchCeiling.tesl` | 20,000 rps for 5 s, used to probe the runtime ceiling |
| `BoundedMemory.tesl` | ordered first-page, pagination, selectOne and unordered range queries over a populated Memory table |
| `InsertManyMemory.tesl` | real HTTP batch insertion with primary/composite unique constraints, inside/outside transactions |
| `NullablePostgres.tesl` | real PostgreSQL HTTP equality and list lookups on nullable indexed columns |

The three load-test programs exercise two request paths, both free of sleeps and outbound calls, so the measurement is the
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

Run all load-test sources:

    for file in bench/Bench*.tesl; do tesl test --test-kind load-test "$file"; done

Run the bounded-query HTTP benchmark (seeding is outside query timing):

    python3 scripts/measure-memory-selection.py --output /tmp/memory-after --rows 20000

Use `--repo-root /path/to/baseline-checkout` to run the same fixture with another
built compiler/runtime. Alternate before/after order. Every response is checked
against independently computed rows and ordering; raw timings and source/binary
hashes remain in the output directory. See [wave-six evidence](../dev-docs/runtime-wave6.md).

Run the insertion benchmark, including row construction inside each request:

    python3 scripts/measure-memory-insert.py --output /tmp/insert-after

It validates all rows plus duplicate-prefix and rollback behavior. Use the same
`--repo-root` baseline option and alternating run order. See
[wave-seven evidence](../dev-docs/runtime-wave7.md).

Run indexed nullable lookups through HTTP against a private PostgreSQL cluster:

    python3 scripts/measure-nullable-postgres.py --output /tmp/nullable-after

Both versions receive the same existing index outside timing. The runner checks
complete results, captures emitted SQL and EXPLAIN plans, and supports baseline
`--repo-root` plus separate `--plan-modes auto force_generic_plan` controls. See
[wave-eight evidence and scope](../dev-docs/postgres-ci-wave8.md).

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
