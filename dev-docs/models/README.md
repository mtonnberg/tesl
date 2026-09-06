# Migration admission kernel

`bash scripts/check-migration-models.sh` runs TLC from the locked Nix toolchain.
It exhaustively explores two finite instances and requires seven broken protocols
to yield their specific invariant counterexamples. A syntax error, timeout or JVM
failure cannot count as a successful negative test.

| Checked property | Meaning | Deliberately broken protocol |
|---|---|---|
| `INVFloors`, `Monotone` | Floors stay ordered, and committed floors, versions and attempt numbers never decrease. | — |
| `INVWriter` | A retiring writer cannot survive the floor's commit. | Omit the exclusive writer fence. |
| `INVReadLock` | Contract cannot remove columns while an old transaction buffers or has admitted its query. | Omit the reader's table lock. |
| `ReadAdmissionSafe` | A query cannot be admitted after its version is retired. | Bypass the read's floor check. |
| `INVFinal` | Retirement cannot certify a dirty generation. | Skip the final pass. |
| `INVQueueFloor` | Pending, delayed, processing and dead jobs cannot retain a retired stamp. | Skip restamping. |
| `INVAttempt` | An old attempt cannot complete, retry or dead-letter a newer attempt's row. | Omit the attempt/claimant comparison. |
| `SurvivorAttemptPreserved` | Restamping preserves a surviving claimant's status, token and lease. | Turn its processing row back into pending work. |
| `INVContract` | Contract intent and completion require the compatibility floor. | — |

The admission instance has three versions and no live jobs. It includes additive
epochs, a transforming expansion, provisional backfill, final retirement,
query-before-admission, contract intent/DDL/completion, actor termination and
coordinator restart. The queue instance has two versions, one durable job and two
attempts. The model retains both attempt identities so it explores a stale worker
resuming after reclamation, including two attempts by the same version.

Retirement and restamping are separate durable actions: a coordinator can die
between them. A surviving claimant is restamped without changing its processing
status, claimant, sequence or lease. A retiring claimant must expire first; renewal
requires an admitted version outside the exclusive fence. Pending and dead rows
restamp without waiting for handlers. Delayed work is represented by arbitrarily
postponing its claim. Lease time is abstracted into explicit expiration; renewal
while live is a stuttering step.

Read admission is the linearization point. A read admitted before retirement may
commit afterwards because its transaction keeps the table lock. A buffered read
whose admission sees the new floor is refused and releases its lock without
delivering rows. The model assumes PostgreSQL READ COMMITTED, transaction-duration
ACCESS SHARE locks and advisory-lock exclusion. Real PostgreSQL interleavings in
`runtime/go/internal/migrationtest/read_ordering_test.go` test those assumptions;
the model does not establish PostgreSQL's implementation of them.
The [read-admission argument](read-admission.md) connects these ordering cases to
the PostgreSQL lock and snapshot rules and names the executable interleavings.

These are finite safety checks, not a proof of unbounded behavior, fairness,
eventual progress, SQL expressions, transformation correctness, replica routing,
schema privileges, uniqueness guards or external-effect deduplication. Numeric
overflow has separate Go oracle tests. The model is independent of production SQL
and generated runtime code. Its correspondence to the eventual production
implementation, complete INV/TR traceability and the required two reviews are
still delivery gates; passing TLC alone does not complete a migration phase.
