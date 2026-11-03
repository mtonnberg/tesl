# Guarded staged-uniqueness window

> Audience: compiler and runtime contributors reviewing guarded writes during staged promotion.

The connected window is **V1 ordinary → V2 staging → V3 declares unique with a
write guard**. V3 can start and repair data without a UNIQUE index. It cannot use
`onConflict` on a promoted key. The connected
[Contract/enforcement lifecycle](stage-lifecycle.md) now supplies the reviewed
handoff, UNIQUE build/recovery, V4 reliance and pending-stage cancellation.

Use a distinct name for the target unique index. For example:

```tesl
# V2
staging unique index [email] as "email_preparation"
# V3
unique index [email] as "email_unique"
```

## Source and activation

The compiler's `tesl-retained-physical-version-v10` contains each complete pending
preparation descriptor and its unique target descriptor. The target is absent
from the window's physical index inventory and concurrent-index jobs. The runtime
binds the descriptor to the preceding preparation, current sealed unique source
declaration, exact typed field/dependency closure, retained columns and index name.
Historical application schema imports cannot circumvent the V3 reliance check.

During publication, the Worker drains the predecessor compatibility plans, grants
the no-login control Owner SELECT/TRIGGER on affected tables, and calls protected
publication with the version only. Its owner-only activation helper derives the
trigger names and bodies from direct descriptor membership in the protected
physical plan. It accepts no caller-supplied SQL body, table name or index name.
It verifies the exact pending preparation record, durably valid preparatory job,
and actual index catalog. Trigger creation, protected activation records and V3
publication occur in one protected SQL statement and commit together. Worker
cannot invoke activation separately. Admission refuses an incomplete activation.

The preparation identity in `tesl_schema_stages` remains immutable. Its state stays
`pending` until a reviewed lifecycle transition.
`tesl_schema_stage_guards` records the active window separately; it is not an
enforcement receipt. Owner, body, configuration, ACL and complete trigger inventory
are checked by ordinary catalog observation, including from older binaries.

## Actual mutation values

Owner-controlled BEFORE INSERT OR UPDATE triggers inspect actual `NEW` values.
There is no UPDATE-column-list shortcut. They cover bulk SQL, computed expressions,
ordinary generated applications and explicit transactions. Trigger names sort by
stable stage ID; guards never modify `NEW`. Missing admitted transaction identity
fails even when a key would otherwise skip its probe.

An admitted older release skips the guard deliberately. For the guarded release,
NULL skips the key guard (`NULLS DISTINCT`), and an unchanged update key does not
create a new duplicate. Every changed non-NULL key uses its concrete builtin send
function and byte-length-prefixed database UUID, stage ID and key bytes to derive
the one-bigint transaction advisory lock. This lock domain is separate from the
two-integer version fences. The update probe excludes the OLD non-null primary
key with `IS DISTINCT FROM`, including when the update changes the primary key.

The volatile trigger executes the probe in a separate SQL statement after any
key-lock wait, obtaining a fresh READ COMMITTED snapshot. Same-statement earlier
rows are visible to this probe. A violation raises SQLSTATE `23505` with the target
unique-index constraint name. Savepoint rollback undoes the mutation and its
acquired locks. There is no key-reservation table or table-wide per-write lock.

This is admission identity, not executable authentication: a shared-credential
caller claiming an older, still-admitted release has that release's permissions.
After actual floor retirement, fresh admission rejects that old release; forged
settings and pooled-connection leftovers cannot select its mode.

## Managed indexed probe

Supported keys are Bool, Int32 with int4/int8 storage, and builtin TEXT under the
verified deterministic database-default libc C/POSIX collation, optionally nullable.
The non-null primary key must use bool/int4/int8/text/numeric storage. UUID/bytea,
custom opclasses/collations, composite staged keys and NULLS NOT DISTINCT remain
unsupported.

Each actual probe is replanned using typed builtin equality, constant LIMIT and a
function-scoped zero-cost profile: force custom planning, enable index/index-only
scans, disable sequential/bitmap scans and parallel gathering/JIT, and set both
page costs and all three CPU costs to zero. Caller settings are restored before
return; the exception subtransaction restores them on error. An earlier EXPLAIN
does not authorize or pin execution.

The catalog check requires valid/ready/live preparatory B-trees with
`indcheckxmin=false`, exact single-column keys, default builtin opclasses and
collations. The permitted index family is the ordinary single-column PK plus
valid single-column stage preparations. Covering, nonleading, partial, expression,
and unrelated secondary indexes are refused. Exact reviewed promotion targets are
also admitted while building and after validation; the valid preparation remains
available. Table and index tablespace page-cost
options must inherit the zero profile or explicitly be zero; tablespace OID zero
is resolved through the actual database default.

This profile is for the stock PostgreSQL planner and builtin equality semantics.
Administrative replacement planner hooks and raw Worker DROP/ALTER are outside
the managed protocol. Request does not receive administrative privileges. Managed
successor physical registration requires enforced reliance; unreviewed index paths
and unrelated Contract DDL refuse while this window is active. Valid preparation jobs remain
absorbing, so invalid-remnant cleanup cannot reclaim a valid guard index.

## Executed evidence

`compiler/test/test_migration_row_indexes.ml` builds real, separate V1/V2/V3
executables with the race detector and runs `TestPgStageGuardCompiledWindow` and
`TestPgStageGuardActivationBoundary` through the mandatory migration compiler
suite. The PostgreSQL version exercised was 17.10. Passing scenarios cover:

- Ready V3 with five guards, five preparatory jobs and no secondary UNIQUE index;
  ordinary compiled insertMany calls, older V2 duplicate-producing updates, restart
  inspection and finite V1→V3 catch-up.
- All supported key domains, distinct C/POSIX text values, multiple NULLs,
  same-statement bulk duplicate insert/update, computed keys, non-key repairs,
  primary-key changes, transactions and savepoints.
- A second same-key writer demonstrably waiting on the key lock, observing the
  first writer's committed row and raising the target `23505`; a different-key
  writer commits while that lock remains held.
- Profile restoration inside the caller's transaction on success and error,
  forged/missing context, unsafe indexes, `indcheckxmin`, tablespace overrides,
  protected source/activation tampering and direct Worker lifecycle attempts.
- Actual close-epoch retirement through V3 followed by raw V2 admission refusal;
  compiler refusal of V3 onConflict and premature V4 reliance.

Separate lifecycle witnesses cover reviewed Contract, index recovery, durable
enforcement readiness, deployment and pending-stage cancellation. The later
[major verification](stage-major-verification.md) passed the selected compiled/race
subsets on PostgreSQL 14.23, 17.10 and 18.4. No full CI pass is claimed.
