# Query-first read admission

This argument concerns the protocol's ordering. It assumes the compiler's window
and settled SQL decode their respective schema correctly; it does not prove row
transformations, proof transport or external-writer safety.

The read runs on the primary in one READ COMMITTED transaction: execute the entity
query, buffer its entire result, execute a separate admission command, then commit
before delivering the buffer. PostgreSQL gives each command a fresh snapshot, so
the admission command can see a retirement committed after the entity query began.
A transaction snapshot at REPEATABLE READ or SERIALIZABLE cannot provide that
refresh. Those paths require the version fence before their first snapshot or must
be refused; silently inheriting a stronger server default would invalidate this
argument. [PostgreSQL transaction isolation](https://www.postgresql.org/docs/17/transaction-iso.html#XACT-READ-COMMITTED).

The entity query takes ACCESS SHARE on its referenced tables. That lock conflicts
with the ACCESS EXCLUSIVE lock used for column-removing contract DDL and remains
held until transaction completion. Rolling back a savepoint can release locks
acquired inside it: a runtime must discard that savepoint's buffer as well, rather
than carry it into a later admission. These are requirements for the generated
runtime, not assumptions about its current implementation.
[PostgreSQL explicit locking](https://www.postgresql.org/docs/17/explicit-locking.html#LOCKING-TABLES).

There are two relevant orderings:

1. Retirement commits before admission's snapshot. An old reader sees the new
   floor and refuses, discarding even an empty or aggregate result. A surviving
   reader is admitted. Its existing table lock still prevents contract from
   invalidating the buffered query before commit.
2. Admission's snapshot precedes retirement's commit. The reader may be admitted
   against the earlier floor. Admission is its linearization point; it may finish
   later. Contract still waits for its table lock. Requiring that no old response
   finish after retirement would be a different protocol.

`TestPostgresTemplateQueryFirstAdmissionAcrossRetirement` interposes retirement and
DDL between query and admission for both versions. It covers rows, a missing key,
constant-false predicates, LIMIT 0, an empty aggregate and EXISTS. It observes the
actual waiting DDL lock, then checks refusal/discard or successful delivery and
eventual DDL completion. The TLA+ `ReadAdmissionSafe` action property and
`INVReadLock` invariant model the two obligations separately, with a required
counterexample when either guard is removed.

`TestOwnedLaggedReplicaHasStaleAdmissionAndSchema` pauses physical WAL replay across
retirement and DDL. The replica still admits the old version and exposes removed
storage until replay resumes. This is a concrete counterexample to using a
replica's floor for Strict admission; replica routing remains unsupported.
