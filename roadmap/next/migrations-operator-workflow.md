# Migrations: operator and editor workflow

Status: open, 2026-11-25. Split out of
[`completed/database-migrations.md`](../completed/database-migrations.md) when the
migration release cut shipped in main (PRs #116–#127). The maintainer classified
these as non-blockers for that release (`PR-CONVENIENCES` in
[`dev-docs/migration-pr-scope.md`](../../dev-docs/migration-pr-scope.md)).

## What ships today

The application binary has the verbs `status`, `install`, `deploy`, `worker`,
`catch-up`, `contract` and `close-epoch`
([operator manual](../../manual/migration-operations.md)). The native CLI has
generation, plan, Contract and source-write recovery, and its previews are
non-mutating, so CI can run them. A Contract is always explicit.

## Remaining work

Each item names the design section that specifies it. None of them changes the
proof, fencing or data-loss rules already implemented; they are new commands and
editor flows on top.

1. **Contract lifecycle modes** — `contract: WhenDrained | NextVersion` (design §6,
   "Lifecycle of one migration"). Today only the explicit mode exists: an operator
   runs `contract`. `WhenDrained` would run it once no older version has heartbeats
   or fenced transactions for the grace period; `NextVersion` at the next deploy,
   refusing while retiring versions are still live.
2. **Offline path** — `apply-offline --wait-for-drain`, shadow-table copy and
   `--suggest-online` ("The downtime path"). For changes a team prefers to apply
   during a maintenance window rather than online.
3. **Prune** — `tesl migrate prune` with per-target evidence (§11). Removes frozen
   snapshots and legacy decoders that no database can still need; today history only
   grows.
4. **Source scaffolds** — `tesl migrate rebase` (regenerate snapshot and record after
   a merge conflict, §1) and the generated `Repair` skeleton (§6).
5. **General data dry-run** — `--schema dry-run` with per-entity/per-job counts of
   what a transformation would change or reject. `close-epoch --dry-run` exists but
   covers only epoch closure.
6. **Editor apply** — *Tesl: Change Schema* with preview, dirty-buffer policy and
   cross-file diagnostics ("Diagnostics and editor workflow"). The editor can show
   previews; applying from the editor is not built.
7. **Embedded topology with versioned queues.** `topology: Embedded` (migrations run
   in the app process) still refuses versioned queues; only `Worker` topology
   supports them.
8. **JSONB codec-list integration** (design phase 5, §10): plan awareness of
   `fromJson [current, legacy]` fallback lists and "may be removed at V<n>"
   tracking. Partly overlaps item 3; confirm the current state against the
   [implementation ledger](../../dev-docs/migrations-implementation.md) before
   starting.

## Suggested order

1 and 5 first: they remove the most manual operator steps and reuse existing
fencing and preview code. 6 depends on the editor work in
[`gold-standard-lsp.md`](gold-standard-lsp.md). 2 is the largest and least requested.
