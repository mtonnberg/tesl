# Adding an index while the application keeps serving

[Lesson 84](lesson84-worker-migrations.tesl) separates the schema worker from
request processes. The [todo application](../db-migration-example/README.md)
extends that arrangement across a saved history. Its concurrent-index change
shows why the schema worker needs to keep running after startup.

The user still creates and completes a todo through the same HTTP handlers and
Elm interface. The public response remains `{ id, title, completed }`. An index
changes how PostgreSQL can find rows; it does not require a new HTTP contract or
a different database connection in each entity module.

## The source change

Start from the todo app's V7 release in a new directory, since today's example
already contains this index:

```sh
bash example/db-migration-example/deploy/build-revision.sh 7 /tmp/todo-index-lesson --prepare-only
cd /tmp/todo-index-lesson/source
```

Its `Todo` already has a `completed: Bool` field. V8 adds a plain index on that
field while the deployment regression retains V7 rows. The ordinary editing
workflow is the same as for a nullable field:

```sh
tesl migrate todo-app.tesl
```

The command freezes the accepted current schema and points you to
`schema/todo/v-current.tesl`. Add this declaration inside `entity Todo`:

```tesl
index [completed]
```

Save and continue the guided session. Review the generated migration and plan. Keep
the application handlers and API tests unchanged; the example's regression
compares those bytes across every release.

An index on an existing populated table needs background work. A new table's
initial index, such as the Project index introduced earlier in the history, can
be created with its table. The source plan distinguishes these operations.

## What runs during deployment

| Process | Responsibility |
| --- | --- |
| Temporary installer | Provision or explicitly upgrade protected migration metadata |
| New schema worker | Expand supported storage, register the index job and run PostgreSQL's concurrent build |
| Old and new request processes | Check their schema readiness, then serve ordinary reads and writes |
| Deployment system | Keep healthy processes available, route traffic, replace instances and drain requests |

Run the new binary with the worker login as `./app --schema worker --json`. Run
ordinary `./app` request processes with the request login. The example's scripts
under `deploy/` arrange these processes and their proxy. Python does not interpret
the migration or execute its DDL; those operations belong to the compiled worker.
The same separation applies if your deployment system uses Helm.

A plain index can keep building after `schema-worker-ready`. New request
processes can serve because the index is not required to make their rows valid.
For a required unique index, readiness waits for PostgreSQL's valid index and
Tesl's recorded completion. In either case, leave the schema worker supervised.

Do not infer compatibility from the word “plain.” PostgreSQL can reject a wide
indexed text value even without a uniqueness constraint. The compiler's plan
checks old writers too. The todo index uses a bounded Boolean field, so it cannot
introduce that wide-key failure for an admitted older application.

## An interruption is part of the scenario

An ordinary old writer can hold a transaction open when the new worker begins
the index. PostgreSQL may wait for that writer before building. Meanwhile, the
app can continue serving other requests. A waiting index is not evidence that
its worker is dead.

If the worker process stops, PostgreSQL may still be finishing its statement.
The replacement checks the previous executor's actual database connections and
the physical index before taking ownership. It preserves an already valid
result, waits for active work, and rebuilds only a confirmed invalid remnant of
the recorded job. The database record fences competing worker attempts.

Restart the ordinary worker binary; do not edit the job's database metadata or
manually mark an index complete. An unfinished job keeps the compiler build
that created it. Use that build to finish the job before replacing it with a
different compiler build. A request observer does not execute the job and can
continue serving compatible completed storage.

## Run the regression

```sh
bash scripts/run-migration-tests.sh -run '^TestCompiledTodoShowcaseRollingUpgrade$'
```

The test compiles the saved releases into standalone binaries, runs their unit
and API tests, then removes their source and build trees. It uses real PostgreSQL
with separate request, worker and installer identities. During V8 it holds an
old writer transaction open until PostgreSQL reports an active concurrent build,
kills the worker process, and starts a replacement.

Assertions require continued old/new HTTP reads and writes, an oldest-version
request restart, a new fencing token after the old executor disappears, an exact
valid index, and unchanged immutable migration receipts. Later nullable-field
evolution must preserve that completed index. The test observes actual work and
recovery; it does not substitute a sleep for evidence that a build started.

This scenario covers an additive index under Worker topology. Embedded runs the
same index service inside `WithDatabase`; its compiled full-app regression extends
lesson 83 with an index while preserving the application code. Typed row or JSONB
transformations, epoch closure and physical contraction still have separate
implementation work. Use the
[short database-change guide](../db-migration-example/how-to-update-the-db.md)
for the everyday edit steps and [deployment guide](../db-migration-example/deploy/README.md)
for the local cluster commands.
