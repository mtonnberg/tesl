# Small migration latency regression gate

`run-migration-tests.sh` runs `latency-statistics`, then `latency-regression`
sequentially in its full (no focused-test arguments) gate. Missing tools/history,
build failures, request errors, incorrect writes, non-format5 databases, failed
calibration and regressions are failures, never skips. CI fetches full history.

The pinned baseline is **9852f263b0ce52f78045c3edb266625aa4460674**.
Override with `TESL_MIGRATION_LATENCY_BASELINE` or standalone `--baseline-ref`.
Evidence includes the supplied and resolved baseline, candidate HEAD and dirty
status, every copied source's SHA-256, aggregate source identities, shared fixture
hashes, generated-source and binary hashes, tools, host, policy and raw timings.
The candidate is the actual checkout, including modified and Git-visible untracked
files. The output directory is excluded. Existing evidence is never replaced.

Both compilers and release (non-race) Go applications build from independent
copies. Both compile the same candidate V1 fixture from `example/db-three-upgrades`.
Each run gets a fresh database in a private Unix-socket PostgreSQL cluster. Its
installer installs real control objects; its worker and unprivileged request
process run normally. The observer checks `tesl_schema_meta.format_version = 5`.
Three rows are inserted through public HTTP endpoints.

Each run uses a persistent HTTP client, concurrency one, 200 excluded warmup
iterations and 1,000 measured iterations. An iteration times a three-row GET and
an alternating PUT update. An additional untimed GET verifies every stored write;
all reads check IDs, metadata and unchanged fields. Timings include HTTP and
database admission/transactions, not just admission overhead. Startup, installation,
seeding and readback are excluded. Warmup observations remain in `raw.jsonl`.

Six baseline/baseline pairs calibrate noise first. Eight baseline/candidate pairs
alternate AB/BA order. Metrics are within-run p50/p95 for reads/writes. Comparison
uses median paired differences and a deterministic 4,000-resample, one-sided 99%
percentile-bootstrap upper bound, resampling whole pairs, not correlated requests.
All four upper bounds must fit `max(50% of baseline metric, floor)`, where the
floor is **0.5 ms for p50 and 2 ms for p95**. Two-sided A/A
noise must fit half that allowance; noisy hosts fail rather than widening limits.
These small-sample bootstrap estimates are not a distribution-free guarantee.

Absolute 1%/5% overhead is not a merge criterion. Large datasets, active migrations,
queues, concurrency and large-data sweeps are deferred.

## Empirical policy review (2026-10-18)

The first completed compiled HTTP/PostgreSQL run is retained at
`.tesl-stuff/latency-first-20261018-retry/{result.json,raw.jsonl,policy-audit.json}`.
Baseline was the pinned commit; candidate was actual root HEAD
`ec0712977865ee65b90a8f6b50605caef1de4512` plus the six latency integration files.
Its source inventory SHA-256 was
`0f949ca6844b76c40acb43cfc2d7a8973392533ce64a11f986a552988131f702`.
Both independent compiler/application builds and all 28 fresh-database runs
completed; every read and every update's readback passed. An earlier attempt
was interrupted by the tool's 120-second deadline during compilation; its failed
evidence is retained in `latency-first-20261018` and contributes no observations.

Milliseconds (baseline/candidate are medians of per-run quantiles):

| Metric | Baseline | Candidate | Paired delta | Upper 99% delta | A/A noise | Revised allowance |
|---|---:|---:|---:|---:|---:|---:|
| Read p50 | 0.925 | 0.915 | 0.002 | 0.073 | 0.149 | 0.500 |
| Read p95 | 2.154 | 2.226 | 0.057 | 0.525 | 0.928 | 2.000 |
| Write p50 | 1.606 | 1.609 | -0.062 | 0.092 | 0.312 | 0.803 |
| Write p95 | 4.029 | 4.408 | 0.537 | 0.970 | 1.072 | 2.014 |

The original 50%/2ms policy was explicitly uncalibrated. Reviewing the raw run
quantiles showed A/A read p50 0.807–1.011ms and write p50 1.431–1.866ms,
versus read p95 1.465–3.137ms and write p95 3.336–5.065ms. A common 2ms floor
would allow more than doubling typical reads. We tightened the median floor to
0.5ms; retained the 50% relative component and 2ms tail floor as a coarse
regression guard given this tail variability. Nothing was widened to pass.
The revised A/A half-allowance budgets are 0.250/0.396ms for read/write p50
and 1.000/1.106ms for p95. Tail calibration is close to its budget, so this
single-host result does not establish CI reliability or sensitivity to small
regressions. A noisy subsequent host must fail, not silently relax the policy.

The fresh revised-policy run at `.tesl-stuff/latency-policy-20261018` did fail A/A
calibration: p95 noise was 1.801ms for reads (1.000ms budget) and 3.318ms for writes
(1.516ms budget). It produced no baseline/candidate verdict. Those measurements
used the original 20 warmup / 100 measured iterations. The runner now uses
200 warmup / 1,000 measured iterations to reduce small-sample tail variability;
the threshold and noise budgets remain unchanged. Historical raw evidence remains
replayable at its recorded sample count under the current comparison policy.

The larger-sample run at `.tesl-stuff/latency-sampled-20261018` also refused a
verdict: read p50 noise was 0.361ms against a 0.276ms budget and read p95 noise was
1.258ms against a 1.000ms budget. This failure is retained, not retried silently.
Review additionally found that building Dune's default target compiled every test
executable, creating about 6.8GB of unnecessary scratch per comparison. The runner
now builds only `bin/main.exe`, records each compiler binary's hash, and removes
Dune scratch after writing evidence. Sources, generated Go, application binaries,
raw observations and result metadata remain retained.

The revised CLI-only run at `.tesl-stuff/latency-cli-only-20261018` passed both
calibration and comparison with the larger samples and unchanged limits:

| Metric | Baseline ms | Candidate ms | Upper 99% delta ms | A/A noise ms | Allowance ms |
|---|---:|---:|---:|---:|---:|
| Read p50 | 0.936 | 0.925 | 0.009 | 0.059 | 0.500 |
| Read p95 | 2.405 | 2.468 | 0.215 | 0.499 | 2.000 |
| Write p50 | 1.656 | 1.636 | 0.054 | 0.118 | 0.828 |
| Write p95 | 4.779 | 4.621 | 0.310 | 0.884 | 2.389 |

All 28 fresh-database runs and correctness checks completed. The +3ms comparator
negative control rejected all four metrics on these observations too. Retained
evidence occupies 225MB after removing Dune scratch. This is one passing standalone
run following the documented harness changes; the failed calibrations above remain
part of the record. Hosted-runner reliability and the full CI invocation remain
unverified.

`python3 scripts/test-migration-latency.py --evidence DIR` reconstructs all pairs
from raw observations and compares deliberately slowed copies (+3ms per candidate
request). On this run all four slow metrics failed (upper deltas
3.073/3.525/3.092/3.970ms in table order). This is a comparator negative control,
not a claim that delay was injected into the running server. Ten lightweight
tests also cover tail-only slowdown, drift, missing samples/history and snapshot
exclusion. These targeted results are not a full-gate pass.

Tesl load-test reuse was investigated: `NoteLoadTestBaseline` and
`NoteLoadTestRegression` in `runtime/go/teslrt/loadtest.go` only log messages;
the Racket backend likewise defers stored comparison. They are not evidence for
this gate. This runner uses existing real HTTP endpoints without changing the
load-test language.

## Commands

From the candidate checkout inside the project's development environment:

```sh
python3 scripts/test-migration-latency.py
python3 scripts/compare-migration-latency.py \
  --baseline-ref 9852f263b0ce52f78045c3edb266625aa4460674 \
  --output .tesl-stuff/latency-first-UNIQUE
TESL_MIGRATION_TEST_OUTPUT=/tmp/opencode/tesl-migration-full-latency-UNIQUE \
  bash scripts/run-migration-tests.sh
```

Use fresh output paths. Full-gate latency evidence is under
`TESL_MIGRATION_TEST_OUTPUT/latency-regression`; phase logs and exit codes are in
the parent's `phases.tsv`. Retained sources, builds and PostgreSQL data can be
large. Retain `result.json`, `raw.jsonl`, logs and source identities for review.
Failed partial observations never constitute a passing comparison. An outer
timeout also fails even if an abrupt kill prevents writing final JSON.
