# Dead-letter metadata boundary

`DeadJob` is an opaque snapshot returned by `deadJobs`. Its pure accessors are
`DeadJob.id : DeadJob -> String`, `DeadJob.reason : DeadJob -> DeadJobReason`,
`DeadJob.attempts : DeadJob -> Int`, `DeadJob.sourceVersion : DeadJob -> Maybe Int`,
and `DeadJob.typeName : DeadJob -> Maybe String`. The real four-constructor ADT
requires exhaustive handling of `AttemptsExhausted`, `PayloadInvalid`,
`MigrationRejected`, and `LegacyUnresolved`. No constructor, record field, or
payload accessor exists. Runtime metadata construction never invokes a codec.

Memory entries record actual attempts and `AttemptsExhausted`, with no source
version or wire type. Unversioned PostgreSQL entries retain their stored
`job_type`, never a reflected current Go name, and have no source version.
Its historical `dead` plus `next_attempt_at = infinity` marker conflates several
decode failures: report `LegacyUnresolved`, not an invented precise reason.
Finite exhausted entries remain retryable. Both the DTO reason guard and the
SQL predicate reject quarantine requeue: an earlier retryable listing cannot
override a later infinity marker. Existing claim/lease ownership rules remain
in force.

`deadJobFromMetadata` is the private bridge for a protected metadata query. It
accepts only the four exact hyphenated reason strings, nonempty IDs, nonnegative
attempt counts, and optional supported positive source versions. The query's
stored type identity and source version are copied into `Maybe` values. This
parser validates metadata representation; it does not authenticate arbitrary
callbacks, establish persisted schema authority, or enable protected dispatch.
`tesl_queue_dead_jobs` can use it when that candidate backend is integrated.

Regression coverage lives in `test_dead_job_metadata.ml` and
`dead_job_metadata_test.go`: exact import/type/opaque/exhaustiveness boundaries,
actual generated Go matches and accessor calls, Memory retry behavior, exact
reason parsing, and real PostgreSQL unknown-codec/invalid-payload quarantines plus
stale-handle requeue refusal. The generated test-only constructor feeds metadata,
not payloads; the emitted Tesl function executes every branch.
