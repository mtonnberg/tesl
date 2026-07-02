# Deploying a Tesl web API

> Audience: Tesl users deploying an app — `tesl build`, the generated Docker image, and the `[database]` deployment flavours.

Use `tesl help manual deploy` to access this from the CLI.

A Tesl project ships as a **Docker image you can just run** — `tesl build`
compiles the app, stages the Tesl runtime, generates a Dockerfile, and builds
the image. No runtime code changes, no hand-written Dockerfile.

There are two flavours, chosen by a flag (or by `[database].mode` in `tesl.toml`):

| Image | Command | What it contains | Use when |
|---|---|---|---|
| **All-in-one** | `tesl build --with-postgres` | app **+ an embedded PostgreSQL** + an entrypoint that starts the DB then the app | demos, self-contained deploys, "just run it" — **no external database** |
| **App-only** | `tesl build --app-only` | app only; connects to a database you run | production with a managed/external PostgreSQL |

With no flag, `tesl build` picks all-in-one when `[database].mode = "managed"`
and app-only otherwise.

## Worked example

```bash
# scaffold (api template = a DB-backed CRUD service with proofs + auth + tests)
tesl init myapi --template api --yes
cd myapi

# --- all-in-one: runs anywhere, no external database ---
tesl build --with-postgres            # → image tagged "myapi" (the [project].name)
docker run -d -p 8086:8086 myapi
curl -s localhost:8086/todos/todo-1 -H 'Cookie: user=demo'
#   → 200 {"id":"todo-1","ownerId":"demo","title":"Read the Tesl tutorial",...}
curl -s localhost:8086/todos/todo-1                 # no auth   → 401
curl -s localhost:8086/todos/todo-1 -H 'Cookie: user=alice'   # not owner → 403
```

The proof boundaries you wrote in `app.tesl` (auth, ownership, input validation)
are enforced inside the running container exactly as they are at compile time.

## Runtime configuration

The app is configured entirely through environment variables — set them with
`docker run -e` (or your orchestrator):

| Variable | Meaning |
|---|---|
| `PORT` | port the HTTP server binds (default from `tesl.toml [env]`) |
| `TESL_POSTGRES_HOST` / `_PORT` / `_DATABASE` / `_USER` / `_PASSWORD` | database connection (app-only image, or to override the all-in-one defaults) |

The Tesl runtime **creates its own tables on first boot** (`ensure-database-ready!`),
so there is no separate migration step for the system tables.

```bash
# app-only image against your own PostgreSQL:
tesl build --app-only
docker run -d -p 8086:8086 \
  -e TESL_POSTGRES_HOST=db.internal -e TESL_POSTGRES_DATABASE=myapi \
  -e TESL_POSTGRES_USER=myapi -e TESL_POSTGRES_PASSWORD=… \
  myapi
```

For the all-in-one image, mount a volume at `/var/lib/tesl-postgres` to persist
the embedded database across restarts.

## Continuous deployment (GitHub Actions)

A ready-to-adapt workflow that builds the image and pushes it to the GitHub
Container Registry lives at
[`templates/docker/github-deploy.yml.example`](../templates/docker/github-deploy.yml.example).
Copy it to your project's `.github/workflows/deploy.yml` and set `APP_NAME`.

## How it works (and what is intentionally not here)

- `tesl build` stages the Tesl runtime collections (`dsl`/`tesl`/`lang`) and your
  compiled `app.rkt` into a build context, instantiates one of the templates in
  [`templates/docker/`](../templates/docker/), and runs `docker build`. The
  Racket base image is matched to the compiler's Racket (`racket/racket:9.2-full`
  by default; override with `TESL_RACKET_BASE`).
- The deployment story is deliberately **just an image** — the app serves HTTP
  the same way it does locally. Health-check endpoints, graceful-shutdown
  signalling, a reproducible Nix `dockerTools` image, multi-arch builds, and
  PaaS-specific adapters are **not** part of this; add them per platform if you
  need them.

## See also

- [`tesl.toml` project manifest](tesl-manifest.md) — the manifest `tesl build` reads
- [Getting Started](GETTING-STARTED.md) — build your first API before deploying it
- [Manual Index](MANUAL.md) — back to the main manual
