# `tesl init` templates

Each subdirectory is a project template. `tesl init` copies the chosen template
into the target directory and substitutes the placeholder `__APP_NAME__` with the
project name the user supplies.

## Layout (every template has the same three files)

```
templates/<name>/
  app.tesl     # the application; module header is always `App` (file is app.tesl)
  tesl.toml    # the project manifest (schema: dev-docs/tesl-manifest.md)
  README.md    # per-project getting-started, also placeholder-substituted
  app.rkt      # COMMITTED SNAPSHOT — not stray build output, see below
```

`tesl init` copies only the first three files, so the `app.rkt` snapshot never
lands in a user's project. **Do not delete it**: it is what puts the scaffold in
the gate (see *Verifying a template* below). `scripts/regen-rkt-snapshots.sh`
regenerates it, and re-mints it if it ever does go missing.

## Placeholder

* `__APP_NAME__` — the only substitution token. It appears in `tesl.toml`
  (`[project].name`), in the telemetry `service "..."` string, and in the
  README heading. It is a *display* name, **not** a Tesl identifier: the module
  header stays `App` because `tesl build` resolves imports by file name and the
  entrypoint is always `app.tesl`.

## Template metadata

| name      | based on                      | database | features |
|-----------|-------------------------------|----------|----------|
| `minimal` | `example/admin-task-api.tesl` | none     | signed-session `auth`, telemetry, one **input** proof (`Positive` via `capture`), one **output** proof (`Int ? Positive`) |
| `api`     | `example/todo-api.tesl`       | managed PostgreSQL | `entity` + `database`, JSON `codec`, signed-session `auth`, one **input** proof (`TitleSafe` via codec), one **output** proof (`Todo ? FromDb`), `test` blocks |

## Verifying a template

The templates are in the same `ci.sh` corpus as `example/` and `tests/` — they
are globbed as `templates/*/app.tesl`, so a new template subdirectory is covered
with no edit to the gate. Four phases apply:

| phase | what it asserts |
|---|---|
| Format | `tesl fmt` in place is a no-op |
| Validate | `tesl validate` (check + lint + fmt-check) is clean |
| Exact-match `.rkt` snapshots | the committed `app.rkt` is byte-identical to a fresh emit — an emit regression in the scaffold fails the gate, and so does editing `app.tesl` without re-running `scripts/regen-rkt-snapshots.sh` |
| Tesl test files (batch runner) | the `test` blocks in `app.rkt`'s test submodule actually run (`api` only — `minimal` has no `test` block, so it is classified "no test block" and skipped, not failed) |

Nothing substitutes `__APP_NAME__` first: the placeholder only ever appears
inside comments and inside the telemetry `service "..."` string literal, so the
raw template compiles and runs as committed. To check a substituted copy by hand:

```sh
tmp=$(mktemp -d)
sed 's/__APP_NAME__/demo/g' templates/minimal/app.tesl > "$tmp/app.tesl"
TESL_REPO_ROOT="$PWD" tesl --check "$tmp/app.tesl"
```
