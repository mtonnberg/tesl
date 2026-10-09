# Twenty releases of a project-tracking application

This simulation deploys **twenty ordinary compiled applications, in order, onto
one PostgreSQL database**. Projects, Tasks and Members start at V1; Audit arrives
at V6. The HTTP API stays stable while storage and proof requirements evolve.

Every release has Tesl `api-test` blocks. There are **95 API tests** in the complete
run: four per release at V1–V5, five per release at V6–V20. They exercise the actual
generated router, request validation, handlers and PostgreSQL storage under the
Request role. They read retained history, create that version's data cohort, check
duplicate/malformed/invalid input, update tasks, and verify selective deletion.

## Run

From the repository root, inside `nix develop`:

```sh
dune build --root compiler bin/main.exe
python3 example/db-twenty-releases/run.py --output .tesl-stuff/tracker-twenty
```

Use a new output directory. `--build-only` builds releases, and `--run-built` runs
the existing binaries against a new private PostgreSQL cluster. `--through N`
bounds a development probe; the default and acceptance target are 20.
`--resume-build` resumes from the last complete archived source release, preserving
incomplete artifacts. `--recompile-from OLD_OUTPUT` re-emits hash-verified source
snapshots with the current compiler; it does not modify emitted identities.

The runner owns its PostgreSQL cluster and roles. Data/WAL live under the output
directory; only a short socket path is allocated under `/tmp`. It never
reuses a developer's application database. Heavy runs on a shared host can use
`GOMAXPROCS=2 GOFLAGS=-p=2` and a disk-backed `TMPDIR`/`GOTMPDIR`.

## Release history

| Version | Change |
|---|---|
| V1 | Projects, Tasks and Members baseline; structured task metadata |
| V2 | Task optional priority |
| V3 | Project optional color and timezone |
| V4 | Member optional role |
| V5 | Project `name` → `title` |
| V6 | Add Audit table |
| V7 | Task metadata Retype/WriteBack: text → text + kind |
| V8 | Member optional active flag |
| V9 | Remove Project memo with an explicit Legacy value |
| V10 | Task optional due date |
| V11 | Member `name` → `displayName` |
| V12 | Project optional archived flag |
| V13 | Task metadata Retype/WriteBack: body + kind + revision |
| V14 | Audit optional category |
| V15 | Strengthen Task title proof through Revalidate |
| V16 | Member optional contact |
| V17 | Project `timezone` → `zone` |
| V18 | Audit `event` → `message` |
| V19 | Add Project external code and Member note together |
| V20 | Rename Project `title` → `label` and remove Member role with LegacyWith |

`scenario.py` is the deterministic source recipe; every generated `.tesl` file is
archived under `vN/source/`. Frozen schemas, migration closures and Contracts are
produced through compiler previews with checked file/directory preconditions.
Every changed source is checked with `agent-context`, and full application emission
revalidates its complete history. Pure converter fixtures run before deployment.

## What is checked during deployment

- The database UUID stays constant through all twenty releases.
- A historical seed survives every transition. Each release adds another cohort
  in Projects, Tasks and Members, plus Audit once introduced.
- Both predecessor and successor binaries serve retained cohorts during overlap;
  both write/read the same seed task before the predecessor is stopped.
- V7/V13 deliberately reject old metadata, and V15 rejects an old title. Contract
  refuses, the admitted predecessor repairs the value, and the rollout resumes.
- Transforming releases use their exact generated Contract and replay it.
- Additive releases close their epoch after old processes stop. `--force` bypasses
  heartbeat recency only; real version/compatibility fences still apply.
- API tests run **before retirement**; the surviving Request binary restarts and
  reads all cohorts again after retirement/epoch closure.
- Valid non-default optional-field fixtures are seeded by the independent SQL
  observer **after** finality. Later releases must preserve them through retyping,
  renaming and unrelated-table changes. These fixture writes are distinct from the
  application's ordinary HTTP cohort creation and edits.
- Final counts are 21 Projects, 21 Tasks, 21 Members and 16 Audit rows. Deleted
  temporary tasks and rejected/duplicate requests must not add rows.

The generated test launcher has one reviewed test-only change: its `m.Run()` call
is wrapped by `runBoundAPITests`, which binds the real compiled database. The
generated `TestTeslApi*` bodies, production handlers, runtime and metadata are not
patched. Memory resets therefore do not erase PostgreSQL history, and the runner
requires the binding marker, every expected API pass, and no skipped API cases.

## Evidence and limits

`rollout.json` records per-version results and the retained database UUID.
Each `vN/build.json` records compiler, application, API-test and source hashes.
`vN/api-postgres.log` and `vN/fixtures.log` retain test output; Worker/Request logs
and `postgres.log` remain beside them.

This is a long-history correctness simulation at modest row counts. It does not
establish high-volume throughput, unrestricted mixed row/queue non-additive
histories, or old-catalog adoption. See the migration operator guide and review 11
for those separate scope and recovery questions.
