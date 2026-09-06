# Staged-uniqueness runtime guard (dependent on database-migrations)

## What

A runtime guard that prevents the *new* version from creating duplicate keys while a
`staging unique index` is pending and the old version is still admitted — so that the
promotion build in the next version cannot fail on duplicates the new version itself
created.

## Why it was withdrawn from v1

`database-migrations.md` §7 keeps `staging unique index` as a compiler-enforced
two-release recipe with **no** runtime guard: the index is built at promotion, after the
predecessor is retired, and duplicates the staging version created in the window are
reported and resolved by hand. A reservation-table guard was designed and withdrawn
(review, 2026-09-03) because, as drafted, it was incomplete in four ways that together
make it a subsystem rather than a convenience:

1. An initially empty reservation table enforces nothing against **pre-existing rows**;
   reservations must be populated for every live row, with an owner primary key, before
   the guard means anything.
2. A **table trigger fires for the old version's writes too**, and a staging change
   bumps no row generation, so `tesl.writer.<entity>` cannot tell the two writers apart.
   The chosen model, when built, is a **trusted stage GUC gating the trigger** —
   `set_config('tesl.stage.<entity>', …, true)` set by the new version's transactions
   — the same trust model as `tesl.writer.<entity>` already relies on, with the same
   two-role privilege boundary (only `tesl_app` connections of a fenced, admitted
   transaction set it). Generated reservation DML was rejected: it would reference the
   reservation table from request SQL and fail once the table is dropped while that
   binary is admitted, the exact problem the window/settled plan split exists to avoid.
   The GUC-gated trigger alone is still **not** sufficient: an old writer's key inserted
   concurrently and not yet reserved is invisible to the new writer's reservation check,
   so the design must also read the base table under the same lock discipline (or
   reserve on behalf of old rows in the same statement) — the base-table race is part of
   the protocol, not a population detail.
3. **Population under concurrent writes is a backfill of its own**: keyset scan,
   conditional writes, dirty keys touched by the old version, stale reservations after
   deletes and key changes, pre-existing duplicates, crash resumption, and a final
   reconciliation under the old version's exclusive fence at retirement — provisional
   until then, exactly like the generation backfill.
4. The **invariant** must be stated and checked before promotion: for every stage in
   `guarded_complete` or `promoting`, every non-null key in the entity table has exactly
   one reservation owned by that row; every reservation points to one live row with the
   same typed key; no two rows share a non-null key. States needed: `preparing`,
   `provisional`, `blocked_duplicates`, `guarded_complete`, `promoting`, `enforced`,
   `cancelled`.

## Design constraints carried over

- Equality is PostgreSQL's: the reservation table has one column per key column with
  the same types and collations and a **real unique index**; the compiler never hashes
  or re-implements collation equality.
- The preparatory index and reservation key must also satisfy the old-key domain
  rule in `database-migrations.md` §7. Nonuniqueness does not remove B-tree key-size
  limits: a guard or preparatory index over an unbounded old-written key can reject
  previously valid writes. Without a proof of safe old-key operations and width,
  the plan is window-narrowing and carries the corresponding rolling-window risk.
- Deadlocks between multi-row statements remain possible and are handled by the
  runtime's whole-transaction retry (LANGUAGE-SPEC).
- Cleanup order after promotion: confirm the exact expected index is `VALID`; record
  `enforced`; drop the maintenance trigger (or generated DML path) **before** the
  reservation table (a table dropped while writes still target it fails every write; a
  trigger dropped while the table remains is harmless garbage); record cleanup complete;
  recovery identifies the intermediate state from the catalog.
- The guard is dropped the moment the promoted index is `VALID`, never at a later
  contract.

## Acceptance (when built)

Concurrent inserts of one key with the second paused mid-statement while the first
commits; key swaps between two rows — the guard must enforce **exactly the promoted
index's semantics**, and Tesl's `unique index` is immediate and `NULLS DISTINCT`, so a
swap that the final index rejects in one statement is rejected during staging too; a
`DEFERRABLE INITIALLY DEFERRED` reservation index was considered and is **rejected**,
because it would allow during staging what promotion then forbids — a behaviour change
at the very moment the recipe promises none; the compiler emits the canonical two-step
(release both, then reserve both) for swaps, which the final index accepts as well;
deferrability and null semantics are part of the stage identity in the main design;
multi-row statements in opposite key order with bounded retry; `NULL`s never conflicting; collation-equal strings colliding; pre-existing
duplicates reported before promotion; a V7 write dirtying a reserved key after
population; reconciliation at retirement; crash at each cleanup step.
