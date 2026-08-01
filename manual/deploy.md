# Deploying a Tesl web API

> Audience: Tesl users deploying an app — `tesl build`, the generated Docker image, and the `[database]` deployment flavours.

Use `tesl help manual deploy` to access this from the CLI.

## `tesl build` has two modes — `[deploy].target` picks one

| `[deploy].target` | What `tesl build` does | Needs Docker |
|---|---|---|
| `"local"` (what `tesl init` scaffolds) | Type-checks and compiles the `[project].entrypoint` into `.tesl-stuff/build/`, then tells you to `tesl run`. | no |
| `"container"` | Stages a Dockerfile + the Tesl runtime and builds the image (the rest of this page). | yes |
| key absent | `"container"` (the behaviour that predates the key). | yes |

Override the manifest per invocation with `tesl build --local` /
`tesl build --container`. The container-only flags below
(`--app-only`, `--with-postgres`, `--tag`, `--out`, `--no-docker`) imply
`--container`, so asking for an image variant always builds one.

A local build produces no artifact to ship — `tesl run` executes the compiled
program in place. The rest of this page is the **container** mode.

## The container mode

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

# --- local: compile + run in place ([deploy].target = "local", the default) ---
tesl build                            # → .tesl-stuff/build/app.rkt (no Docker)
tesl run                              # serve it

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
  freshly compiled `app.rkt` into its own build context (it never touches your
  source tree or `.tesl-stuff/`), instantiates one of the templates in
  [`templates/docker/`](../templates/docker/), and runs `docker build`. The
  Racket base image is matched to the compiler's Racket (`racket/racket:9.2-full`
  by default; override with `TESL_RACKET_BASE`).
- The deployment story is deliberately **just an image** — the app serves HTTP
  the same way it does locally. Health-check endpoints, graceful-shutdown
  signalling, a reproducible Nix `dockerTools` image, multi-arch builds, and
  PaaS-specific adapters are **not** part of this; add them per platform if you
  need them.

### Building on Apple Silicon / arm64

The default base image, `racket/racket:9.2-full`, publishes only a
`linux/amd64` manifest. `tesl build --container` still succeeds on an arm64
host — Docker transparently pulls the amd64 layers — but the resulting
image runs Racket under emulation, which can abort at boot (`Error: error
reading from ~a ("petite")`) depending on your Docker Desktop/QEMU version.
`docker build --platform linux/arm64 ...` on the staged context does not fix
this: it just falls back to the same amd64 base with an
`InvalidBaseImagePlatform` warning, since no arm64 manifest exists to select.

`tesl build` warns at build time when it detects this mismatch (host is
arm64 and the base image's manifest is amd64-only), so the amd64 fallback is
never silent. If you have a Racket base image with a native arm64 manifest
(self-built or from another registry), point `TESL_RACKET_BASE` at it:

```bash
TESL_RACKET_BASE=ghcr.io/you/racket:9.2-full-arm64 tesl build --container
```

There is currently no first-party native-arm64 base image; producing one
(e.g. from the Nix flake's `aarch64-linux` package via `dockerTools`) is
tracked as future work, not shipped today.

## See also

- [`tesl.toml` project manifest](tesl-manifest.md) — the manifest `tesl build` reads
- [Getting Started](GETTING-STARTED.md) — build your first API before deploying it
- [Manual Index](MANUAL.md) — back to the main manual
