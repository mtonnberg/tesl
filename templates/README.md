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
```

## Placeholder

* `__APP_NAME__` — the only substitution token. It appears in `tesl.toml`
  (`[project].name`), in the telemetry `service "..."` string, and in the
  README heading. It is a *display* name, **not** a Tesl identifier: the module
  header stays `App` because `tesl build` resolves imports by file name and the
  entrypoint is always `app.tesl`.

## Template metadata

| name      | based on                      | database | features |
|-----------|-------------------------------|----------|----------|
| `minimal` | `example/admin-task-api.tesl` | none     | cookie `auth`, telemetry, one **input** proof (`Positive` via `capture`), one **output** proof (`Int ? Positive`) |
| `api`     | `example/todo-api.tesl`       | managed PostgreSQL | `entity` + `database`, JSON `codec`, cookie `auth`, one **input** proof (`TitleSafe` via codec), one **output** proof (`Todo ? FromDb`), `test` blocks |

## Verifying a template

After substituting the placeholder, the entrypoint must `tesl --check` clean:

```sh
tmp=$(mktemp -d)
sed 's/__APP_NAME__/demo/g' templates/minimal/app.tesl > "$tmp/app.tesl"
TESL_REPO_ROOT="$PWD" tesl --check "$tmp/app.tesl"
```

Both `minimal` and `api` are checked this way in CI.
