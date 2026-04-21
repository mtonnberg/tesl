# Dead-Letter Queue API

## Current state

Dead jobs (failed after `maxAttempts`) remain in `tesl_jobs` with `status = 'dead'`. They can only be inspected and replayed via raw SQL.

## Proposed design

```tesl
# Inspect dead jobs
fn listDeadJobs(queue: EmailQueue) -> List DeadJob
  requires [queueRead] =
  deadJobs EmailQueue

# Replay a single dead job
fn replayJob(job: DeadJob ::: FromDeadQueue (Id == job.id) job) -> Bool
  requires [queueWrite] =
  requeue job
```

The `deadJobs` and `requeue` built-ins would be backed by SQL queries against `tesl_jobs`.

The `FromDeadQueue` proof ensures only genuinely dead jobs can be requeued — the proof is introduced at the `deadJobs` boundary, parallel to `FromQueue` at the dequeue boundary.

## Scope

Small-medium. Requires:
1. `deadJobs` built-in in compiler and runtime
2. `requeue` built-in to reset status → pending
3. `FromDeadQueue` proof predicate (analogous to `FromQueue`)
4. Tests and lesson material

## Related

- `future-roadmap/add_standard_modules.md` — the dead-letter API could live in `Tesl.Queue` alongside `FromQueue`.

## Open questions

How would the the code trigger that looks/handles the dead-letter?