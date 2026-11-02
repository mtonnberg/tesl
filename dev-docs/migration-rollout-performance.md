# Active migration rollout performance

> Audience: contributors assessing PR 102 rolling-update correctness and performance.

The driver builds ordinary V1/V2 application binaries and equivalent plain
controls, uses a private PostgreSQL cluster, and records real old/new HTTP reads
and writes across expansion, backfill, Worker restart, managed-index work,
rejected Contract, repair, retirement and post-Contract restarts. It checks every
acknowledged hot-row value and scans all final rows for retained-field and
conversion errors. Resource and observation-budget refusals are explicit; they
do not establish successful completion.

## Baseline on the shared cloud host

The immutable baseline is ae7bb3efe98c85a4d3a916ceca0e45796bfc0ef3. The 10,000-row
case passed correctness, full-row validation, Worker restart, rejected Contract
without changing floors, old-writer repair and final Contract/restart. It recorded
228,565 HTTP observations without load failures.

Backfill took 81.529 seconds including startup/restart. The sampled steady interval
advanced 9,000 rows in 71.18 seconds (126.44 rows/second). Contract took 87.740 seconds.
These fixture results cannot be extrapolated as a production throughput guarantee.

Original acceptance budgets remain at no more than 1% additional read p99 and
5% additional write p99. All four observed baseline comparisons failed. V2 overlap
read p99 was 46.945 ms versus 10.838 ms plain; write p99 was 57.934 ms versus 12.058 ms.
The controls had more than 5,600 samples per operation, unlike the earlier
1,000-row pilot, whose controls were insufficient for the minimum sample count.

There were 34,413 lock samples, with a maximum gap of 103.98 ms. Granted table
AccessExclusiveLock spans reached 227.4 ms. A keyed advisory-lock observation
spanned 86.88 seconds during Contract. These are sampled spans: releases and
reacquisitions between polls, and short unobserved locks, prevent claims about
exact continuous hold duration. Older pilot advisory samples conflated keys and
must not be used as continuous-lock evidence.

This host used PostgreSQL 17 with shared cloud CPUs. It did not supply pinned
PostgreSQL 16 hardware, replica/pooler variants, controlled 1 ms network latency,
ten-table histories or a cold operating-system cache. Release acceptance remains
incomplete. The following candidate results retain those limitations.

## Candidate comparison and bounded scale

A fresh sequential pair used the same application, schema, conversion and index
source with 10,000 rows, 2/8 clients, and the baseline plus the transaction-local
backfill processing latch. Migration headers have the required compiler ABI seal
updates; every other source byte matched. Both runs passed full-row checks,
Worker restart, rejection/repair, Contract and post-Contract restart. This is one
shared-host pair, not a confidence interval or an acceptance result.

| Observation | Baseline | Candidate |
|---|---:|---:|
| Backfill including startup/restart | 80.808 s | 58.165 s |
| Sampled steady backfill | 134.87 rows/s | 185.70 rows/s |
| Contract | 62.315 s | 94.716 s |
| V2 overlap read p99 | 44.603 ms | 41.875 ms |
| V2 overlap write p99 | 56.022 ms | 53.267 ms |

Backfill was 1.39 times faster in this pair. Contract was slower; the measurements
do not establish an overall rollout speedup. All four original read/write p99
budget comparisons still failed. The compiler's separate source-discovery phase
improvement must not be described as a database or whole-build speedup.

The 100,000-row and 1,000,000-row candidate cases each exhausted the explicit
180-second backfill observation budget. Neither completed migration validation.
The 10M/100M cases were refused before seeding because the conservative disk
estimate plus the reserved 2 GiB exceeded available space. These outcomes are
limits, not passing scale evidence. An extended 100,000-row run was interrupted
to isolate investigation of a CI queue-test failure; it is not completion evidence.

[The compact measurement evidence](migration-rollout-candidate-measurements.json)
records executable/compiler hashes, exact source differences, both control and
migration quantiles, unchanged budget verdicts, raw-result hashes and scale
refusals. Complete raw observations remain in the review workspace's
`rollout/restarted-baseline-10k`, `rollout/candidate-10k` and `rollout/candidate-scale`
artifacts.
