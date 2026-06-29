# Tesl Docker image templates

Generated, parameterized Dockerfile templates that `tesl build` instantiates to
produce a runnable image of a compiled Tesl app. Two flavors:

| Template | Postgres | Use it for |
|---|---|---|
| `Dockerfile.all-in-one.tmpl` + `entrypoint.sh.tmpl` | **embedded** (apt-installed, managed by the entrypoint) | the "just `docker run` it" demo / single-box deploy — no external DB needed |
| `Dockerfile.app-only.tmpl` | **none** (connects to an external Postgres via env) | production: small image, DB lives elsewhere |

These templates do **not** touch the Tesl runtime or compiler. They package the
*output* of `tesl compile` (a `.rkt`) together with the Tesl Racket runtime
collections, and run it with `racket`.

---

## How a Tesl app becomes a runnable `.rkt`

`tesl compile app.tesl` emits `app.rkt` whose header is `#lang racket` and which
`(require …)`s the runtime under the **`tesl` collection**:

```racket
(require tesl/dsl/sql tesl/dsl/web tesl/tesl/prelude tesl/lang/reader …)
```

So at runtime Racket must be able to resolve a collection named `tesl` that
contains `dsl/`, `tesl/`, `lang/`. We expose it through `PLTCOLLECTS`, exactly
as the Nix `tesl-racket` derivation and `raco pkg install --link` do:

```
PLTCOLLECTS = <racket-collects>:/opt/tesl/collections
/opt/tesl/collections/
  tesl/
    dsl/   ← copy of repo dsl/
    tesl/  ← copy of repo tesl/
    lang/  ← copy of repo lang/
```

`<racket-collects>` (here `/usr/share/racket/collects`) **must** come first so
the base image's own `racket`/`raco`/reader resolve before the package link.

---

## The build CONTRACT `tesl build` must satisfy

### 1. Placeholders to substitute

Every `__PLACEHOLDER__` is a literal, greppable token. `tesl build` replaces all
occurrences (e.g. with `sed`) in both the `.tmpl` Dockerfile and
`entrypoint.sh.tmpl` before building:

| Placeholder | Meaning | Example |
|---|---|---|
| `__RACKET_BASE__` | official Racket base image tag (Debian-based, CS variant). Match the Racket version used to compile. | `racket/racket:9.2-full` |
| `__APP_NAME__` | human-readable app name (OCI label only) | `todo-api` |
| `__APP_RKT__` | path of the compiled entrypoint `.rkt`, **relative to the build context** | `app.rkt` |
| `__PORT__` | TCP port the Tesl web server binds (the `serve … on <port>` value / `PORT` env the app honors) | `8086` |

> The all-in-one entrypoint also references `__PORT__`/`__APP_RKT__` only as
> fallback defaults; at runtime it reads `PORT` and `TESL_APP_RKT` env vars that
> the Dockerfile sets, so substitution and env stay in sync.

### 2. Build-context layout `tesl build` must stage

Create a staging directory and populate it before `docker build`:

```
<context>/
  Dockerfile                      # instantiated from the chosen .tmpl
  entrypoint.sh                   # all-in-one only; from entrypoint.sh.tmpl
  __APP_RKT__                     # output of `tesl compile <app>.tesl`  (e.g. app.rkt)
  <dependency>.rkt                # any imported .tesl compiled to .rkt, same relative paths
  collections/
    tesl/
      dsl/                        # copy of repo dsl/
      tesl/                       # copy of repo tesl/
      lang/                       # copy of repo lang/
```

Which collections to copy: **always all three** — `dsl/`, `tesl/`, `lang/`.
They are the Racket runtime the app `require`s (NOT the OCaml compiler). Strip
any in-repo `compiled/` caches when copying (the image recompiles `.zo` itself).

### 3. Environment variables each image honors

Both images honor `PORT` (web server bind; defaults to `__PORT__`).

The Tesl runtime's `database … { postgres { … env("TESL_POSTGRES_*") } }` block
reads these (only relevant for DB-backed apps):

| Env var | Meaning |
|---|---|
| `TESL_POSTGRES_HOST` | Postgres host |
| `TESL_POSTGRES_PORT` | Postgres port (default `5432`) |
| `TESL_POSTGRES_DATABASE` | database name |
| `TESL_POSTGRES_USER` | role |
| `TESL_POSTGRES_PASSWORD` | password |
| `TESL_POSTGRES_SOCKET` | optional unix socket path (overrides host/port) |

- **app-only**: you supply `TESL_POSTGRES_*` at `docker run` to point at an
  external DB. (Apps with no `database` block need none.)
- **all-in-one**: the entrypoint sets `TESL_POSTGRES_*` itself to point at the
  in-container cluster (`TESL_POSTGRES_HOST=127.0.0.1`, db/user/password = `app`).
  `TESL_PG_DATA` (default `/var/lib/tesl-postgres`) is the cluster path — mount a
  volume there to persist data across runs.

The Tesl runtime auto-creates its tables on boot (database `auto-migrate?`
defaults to `#t` → `ensure-database-ready!`), so no manual migration step is
needed: the schema appears on first boot / first request.

---

## Exact build & run commands

### all-in-one (embedded Postgres — "just works")

```sh
# in the staged <context>/ :
docker build -t myorg/todo-api:aio .
docker run -p 8086:8086 myorg/todo-api:aio
# → serves on http://localhost:8086 with an internal Postgres, no external DB.

# persist the embedded DB across runs:
docker run -p 8086:8086 -v todo-pgdata:/var/lib/tesl-postgres myorg/todo-api:aio
```

### app-only (external Postgres)

```sh
docker build -t myorg/todo-api:app .
docker run -p 8086:8086 \
  -e TESL_POSTGRES_HOST=db.internal \
  -e TESL_POSTGRES_PORT=5432 \
  -e TESL_POSTGRES_DATABASE=appdb \
  -e TESL_POSTGRES_USER=appuser \
  -e TESL_POSTGRES_PASSWORD=secret \
  myorg/todo-api:app

# app with no database block: nothing extra needed
docker run -p 8088:8088 myorg/admin-task-api:app
```

---

## Proven

Both templates were instantiated and built with the local Docker (v28.4) against
`racket/racket:9.2-full` (Debian 13, racket 9.2 CS):

- **app-only** with `example/admin-task-api.tesl` (no DB): built, ran, and
  `GET /tasks/admin/2` (admin cookie) returned `200` with the task JSON;
  non-admin returned `403`.
- **all-in-one** with `example/todo-api.tesl` (Postgres-backed): built, ran with
  **no external DB**; the entrypoint did `initdb` → `pg_ctl start` → created the
  `app` role/db; the app booted, auto-created its tables, seeded data, and
  `GET /todos/mine`, `GET /todos/todo-1`, and `POST /todos` all returned `200`
  (the POST persisted a new row to the embedded Postgres).
