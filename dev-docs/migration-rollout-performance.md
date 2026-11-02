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
incomplete. Candidate comparisons and larger bounded cases must report actual
results and resource/timeout limits separately.
