# Row-level policies and the Citus profile (dependent on database-migrations)

Status: not started. Moved here 2026-11-25 from the migration design
([`completed/database-migrations.md`](../completed/database-migrations.md)), where
both were listed as dependent items after its phase 4. Neither is needed for the
shipped migration release. The text below is the original design sketch, copied
unchanged; verify it against the current language before building.

## Row-level security policies (companion, from Acadia)

Acadia's strongest idea is that a table **cannot be touched without a policy**, and
that the policy is a record of four predicates. Tesl already has the two halves a
policy needs: a proof-carrying actor (`user: User ::: Authenticated user`, `&& Admin
user`) arriving through the `auth … via` line, and entity-scoped capabilities
(`roadmap/next/entity_scoped_db_capabilities.md`) for the **table-level** question
"may this code touch `Note` at all". A policy is the **row-level** layer under that.

Sketch, deliberately close to Acadia's shape:

```tesl
entity Note table "notes" primaryKey id {
  id:      String
  ownerId: String
  body:    String

  policy for actor: User {
    read   actor row          = row.ownerId == actor.id
    insert actor row          = row.ownerId == actor.id
    update actor before after = before.ownerId == actor.id && after.ownerId == before.ownerId
    delete actor row          = row.ownerId == actor.id
  }
}
```

- Every query form on a policied entity names the actor
  (`select n from Note as actor where …`, `insert Note as actor { … }`; exact
  syntax open). Omitting it is a compile error: there is no way to write the query
  without going through the policy. `policy unrestricted` is the explicit opt-out
  and is what a `Session` table declares.
- **Erasure through proofs** is Tesl's version of Acadia's "static symbolic
  evaluation". A clause is discharged at compile time when the call site already
  holds a fact that implies it — `row ::: OwnedBy actor row`, or `actor ::: Admin
  actor` with an `Admin` arm in the policy — and no code is emitted for it. A clause
  not discharged is compiled into the `WHERE` (for `read`/`update`/`delete`) or a
  pre-write check (for `insert` and the `after` side of `update`) that aborts the
  transaction. Fail closed, like every other checker judgment.
- `update` seeing **before and after** gives immutable columns for free
  (`after.ownerId == before.ownerId`), which is the most common policy in practice
  and the one people forget in hand-written `WHERE` clauses.
- Policies live in the snapshot. A policy change appears in the plan header as
  `Note POLICY CHANGED (update: ownerId no longer immutable)`, so a security
  relaxation is reviewed in the same place as a dropped column. A policy change is
  itself subject to the two-version rule only trivially (it is code, not schema), but
  a **tightening** means V7 instances still accept what V8 rejects for the roll
  window; the header says so.
- Backfill and the lazy read path run as the system, not as an actor; policies do
  not apply to them, and the plan header says so when a policied entity is migrated.
- Whether a policy is **mandatory** on every entity (Acadia) or only once the program
  declares any `auth` line is the main question for the row-policy roadmap file. Acadia's answer is right for a
  database language; for Tesl, a lint that becomes an error one release later is the
  likely path.

This deserves its own roadmap file once the migration snapshot exists, because the
snapshot is what makes a policy change auditable. It is included here so the two are
designed together rather than retrofitted.


## Citus profile (from design §12, PostgreSQL topologies)

  **Citus** is a different case: a coordinator in front of the shards *is* a single
  lock manager, and nothing in the protocol depends on single-node-only behaviour, so
  there is a credible **future path** as a "Citus profile" after phase 4 rather than a
  redesign (all of this from documentation as of the design date; verify before
  building):
  - unchanged: advisory fences and leases on the coordinator (a profile forbids
    Citus 11's query-from-any-node); Go row functions (shard-agnostic); `_tesl_v`;
    keyset backfill through the coordinator; coordinator-propagated `ADD COLUMN`,
    `NOT VALID`/`VALIDATE`, `CREATE INDEX CONCURRENTLY`; row triggers on distributed
    tables (Citus 10+), since ours touch only `NEW`/`OLD` and a GUC;
  - profile changes: the writer GUC is set with `SET LOCAL` under
    `citus.propagate_set_commands = 'local'` so the worker-side trigger sees it;
    retirement's index-progress wait runs `pg_stat_progress_create_index` via
    `run_command_on_workers`; `tesl_schema*` and the lease table become **reference
    tables** (which the server-side trigger-fence alternative may read);
  - the one language addition: Citus requires the distribution column in the primary
    key and in every unique index, so an entity gains `distributedBy <field>` (and
    `reference` for lookup tables), with compile-time checks that the key and every
    `unique index` include it and that `innerJoin` is co-located or against a
    reference table — a compile error where Citus would otherwise fail at runtime, and
    the same check that keeps `onConflict` valid there;
  - a Citus cluster in the compatibility-suite matrix.
  Queues and pub/sub (`tesl_jobs`, `LISTEN/NOTIFY`) have their own Citus questions,
  independent of this item.
