# `tesl.toml` — project manifest

> Audience: Tesl users authoring a project — the `tesl.toml` schema read by `tesl build` / `tesl db` and written by `tesl init`.

Use `tesl help manual tesl-manifest` to access this from the CLI.

The project manifest is the single shared seam between `tesl init` (which
**writes** it) and `tesl build` / `tesl db` (which **read** it). It is a small,
deliberately constrained TOML file at the project root next to the entrypoint
`.tesl` file.

This document is the source of truth for the schema and for the TOML subset the
bash CLI reader (`scripts/tesl-manifest.sh`) understands.

## Schema

```toml
[project]
name       = "my-app"      # human-facing project name; seeds telemetry service + image name
entrypoint = "app.tesl"    # the application .tesl file `tesl build` compiles

[env]
# Environment variables the app reads at runtime, with their default values.
# Every key here is a string; consumers may interpret it as int/bool.
PORT                   = "8086"
TESL_POSTGRES_DATABASE = "app"        # only meaningful when [database].mode != "none"
TESL_POSTGRES_HOST     = "localhost"
TESL_POSTGRES_PORT     = "5432"
TESL_POSTGRES_USER     = "app"
TESL_POSTGRES_PASSWORD = "app"

[database]
mode = "managed"   # "managed" | "existing" | "none"

[deploy]
target = "local"   # "local" | "container"
```

### `[project]`

| key          | type   | required | meaning |
|--------------|--------|----------|---------|
| `name`       | string | yes      | Human-facing project name. Used for the telemetry `service` string and the container image name. Does **not** have to be a valid Tesl module identifier — the module header is always `App` because the entrypoint file is `app.tesl`. |
| `entrypoint` | string | yes      | Path (relative to the manifest) of the application `.tesl` file `tesl build` compiles. |

### `[env]`

Flat table of `KEY = "default"` string pairs. These are the environment
variables the app reads (via `env`/`envInt` in the `.tesl` source). `tesl build`
and `tesl db` use this table to know what to export at runtime and what the
defaults are. The canonical Postgres keys are `TESL_POSTGRES_DATABASE`,
`TESL_POSTGRES_HOST`, `TESL_POSTGRES_PORT`, `TESL_POSTGRES_USER`,
`TESL_POSTGRES_PASSWORD`, plus the conventional `PORT`.

### `[database]`

| value        | meaning |
|--------------|---------|
| `"managed"`  | `tesl db` provisions and runs a local PostgreSQL, exporting the `TESL_POSTGRES_*` env from `[env]`. |
| `"existing"` | Connect to a database you already run; you supply the `TESL_POSTGRES_*` values in the environment. |
| `"none"`     | No database. The app declares no `database` block. |

### `[deploy]`

| value         | meaning |
|---------------|---------|
| `"local"`     | Run the compiled binary directly. |
| `"container"` | Build an OCI image (Dockerfile produced under the build output). |

## The reader: `scripts/tesl-manifest.sh`

A dependency-free (`awk` + POSIX shell only) reader the bash CLI sources:

```sh
. scripts/tesl-manifest.sh
name=$(tesl_manifest_get tesl.toml project name)        # -> my-app
port=$(tesl_manifest_get tesl.toml env PORT)            # -> 8086
mode=$(tesl_manifest_get tesl.toml database mode)       # -> managed
```

### Signature

```text
tesl_manifest_get <file> <section> <key>
```

* Prints the value to stdout and returns `0` when the key is found.
* Prints nothing and returns `1` when the section or key is absent.
* Returns `2` (with a message on stderr) on usage error or missing file.

The script is also directly invocable: `scripts/tesl-manifest.sh <file>
<section> <key>`.

### Supported TOML subset

The reader intentionally implements only what the manifest needs:

* `[section]` headers with bare names (no dotted/nested tables, no `[[arrays]]`).
* `key = value` pairs, one per line.
* Double-quoted string values — the surrounding quotes are stripped; a `#`
  inside the quotes is preserved.
* Bare values (numbers, booleans) taken verbatim.
* `#` comments: a whole-line comment, or a trailing comment after an *unquoted*
  value.
* Leading/trailing whitespace around keys, values, and headers is trimmed.

**Not supported** (the manifest never uses them): multi-line strings,
single-quoted/literal strings, arrays, inline tables, dotted keys, and escape
sequences.

## See also

- [Deploying a Tesl web API](deploy.md) — `tesl build` reads this manifest
- [Manual Index](MANUAL.md) — back to the main manual
