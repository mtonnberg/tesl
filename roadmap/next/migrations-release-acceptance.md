# Migrations: release-scale acceptance

Status: open, 2026-11-25. Split out of
[`completed/database-migrations.md`](../completed/database-migrations.md) when the
migration release cut shipped in main (PRs #116–#127).

## What

Evidence that migrations behave as designed on production-sized data and on every
supported PostgreSQL major, not only on the small fixtures the local gate runs today.
The migration PR deliberately deferred these (`PR-SCALE` in
[`dev-docs/migration-pr-scope.md`](../../dev-docs/migration-pr-scope.md)); they are
what separates "the protocol is correct" from "it is safe to run on a big table
under traffic".

## Why

The bar set on 2026-09-02 was "a solved problem, not a toy". Today the claims rest on:

- the full local `./ci.sh` gate (24 phases, 60 migration subphases) passing on
  `60b0b3a`;
- a calibrated base-versus-candidate latency **regression** comparison
  (`PR-LATENCY`), which says "no slower than before", not "the overhead is small";
- a 1,000-extra-row experiment, which is not the large-table gate.

None of these measures backfill duration, WAL volume, lock waits or request p99 on
10M/100M-row tables while a rolling deploy is in progress.

## Remaining work

1. **Large-table sweep.** Run the prescribed 10M- and 100M-row workloads
   (design §9 "Behaviour under load", the table near "100 M rows") with rolling
   writes during expand, backfill, Contract and catch-up, with kills at every
   failpoint. Record backfill rate, WAL, lock waits and the ETA that `status` shows.
2. **Absolute p99 overhead.** Pinned read/write p99 measurements of the admission
   kernel (fence + `tesl_admit`) against the reference workload. The design's
   targets were 1% read / 5% write p99 overhead; the PR chose the regression
   comparison instead, so absolute overhead is still unreported.
3. **Hosted supported-major matrix.** The workflow is configured (PostgreSQL 14/18
   on PRs, 14–18 nightly) but fresh hosted results and timings have not been
   recorded. A local run or an isolated retry does not count; the evidence is one
   complete hosted invocation per major.
4. **Traceability.** `python3 scripts/check-migration-pr.py` reports
   "Roadmap reconciliation: INCOMPLETE" with 646 unmapped design blocks. Either map
   each block to code and a witness, or classify it as not built (and point at the
   roadmap file that owns it).

## Acceptance

- Measurements and logs for items 1–2 are retained and linked from
  [`dev-docs/migration-delivery-status.md`](../../dev-docs/migration-delivery-status.md).
- Item 3: a green hosted run per supported major, linked from the same file.
- Item 4: `scripts/check-migration-pr.py --roadmap-reconciled` passes.
