# Deploying a Tesl web API

> Audience: Tesl users deploying an app — `tesl build`, the generated Docker image, and the `[database]` deployment flavours.

Use `tesl help manual deploy` to access this from the CLI.

## `tesl build` has two modes — `[deploy].target` picks one

| `[deploy].target` | What `tesl build` does | Needs Docker |
|---|---|---|
| `"local"` (what `tesl init` scaffolds) | Type-checks and compiles the `[project].entrypoint` into `.tesl-stuff/go-build/`, including a runnable `tesl-app` binary when it is an application. | no |
| `"container"` | Compiles a Linux `tesl-app`, stages it with a runtime-only Dockerfile, and builds the image (the rest of this page). | yes |
| key absent | `"container"` (the behaviour that predates the key). | yes |

Override the manifest per invocation with `tesl build --local` /
`tesl build --container`. The container-only flags below
(`--app-only`, `--with-postgres`, `--tag`, `--out`, `--no-docker`) imply
`--container`, so asking for an image variant always builds one.

A local build leaves the compiled module and application binary in
`.tesl-stuff/go-build/`. The rest of this page is the **container** mode.

## The container mode

A Tesl project ships as a **Docker image you can just run** — `tesl build`
compiles the app, stages the Tesl runtime, generates a Dockerfile, and builds
the image. No runtime code changes, no hand-written Dockerfile.

There is one Go image flavour. The old flavour flags remain accepted as
compatibility aliases, but neither image embeds PostgreSQL:

| Image | Command | What it contains | Use when |
|---|---|---|---|
| **Runtime image** | `tesl build --container` | prebuilt app binary only; connects to an external PostgreSQL service when needed | deployments using a separate database |

`--app-only` and `--with-postgres` select the same runtime image for now.

## Worked example

```bash
# scaffold (api template = a DB-backed CRUD service with proofs + auth + tests)
tesl init myapi --template api --yes
cd myapi

# --- local: compile + run in place ([deploy].target = "local", the default) ---
tesl build                            # → .tesl-stuff/go-build (no Docker)
tesl run                              # serve it

# --- container: binary plus runtime image; PostgreSQL remains external ---
tesl build --container                # → image tagged "myapi" (the [project].name)
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
| `TESL_POSTGRES_HOST` / `_PORT` / `_DATABASE` / `_USER` / `_PASSWORD` | external PostgreSQL connection |

Unversioned databases use their ordinary startup initialization. Versioned
Worker-topology histories use the deployment job below to install and execute
their checked migration history.

```bash
# container image against your own PostgreSQL:
tesl build --container
docker run -d -p 8086:8086 \
  -e TESL_POSTGRES_HOST=db.internal -e TESL_POSTGRES_DATABASE=myapi \
  -e TESL_POSTGRES_USER=myapi -e TESL_POSTGRES_PASSWORD=… \
  myapi
```

## Continuous deployment (GitHub Actions)

A ready-to-adapt workflow that builds the image and pushes it to the GitHub
Container Registry lives at
[`templates/docker/github-deploy.yml.example`](../templates/docker/github-deploy.yml.example).
Copy it to your project's `.github/workflows/deploy.yml` and set `APP_NAME`.

## Automatic migration job (Worker topology)

Use the same immutable release image for a finite migration job, the schema Worker,
and the Request application. Copy
[`compose.worker.yml.example`](../templates/docker/compose.worker.yml.example)
and [`deploy-worker.sh`](../templates/docker/deploy-worker.sh) to the deployment
host. Create the three environment files using the names your application reads:

| File | Connection configuration |
|---|---|
| `.env.deploy` | Worker `ddlConnection`, plus `TESL_SCHEMA_INSTALLER_DSN` for the deployment-scoped administrative Installer |
| `.env.worker` | Worker credentials and the compiled migration role names |
| `.env.request` | Request credentials and ordinary application settings |

All connections target the same PostgreSQL database. Provision the distinct
control-owner, Worker and Request roles beforehand. Installer credentials belong
only to the finite deployment job. The images use the normal compiled application
entry point, so schema command arguments reach the same checked binary.

Run this from the deployment controller after publishing the release image:

```sh
export TESL_IMAGE=ghcr.io/your-org/your-app:RELEASE_COMMIT
sh deploy-worker.sh compose.worker.yml
```

The script validates configuration and pulls the image, stops the old application
and schema Worker, then runs `app --schema deploy --json`. That command installs
and stages as Installer, closes its Installer connection, and executes retained
history and reviewed finality as Worker. It waits for real heartbeat/claim expiry
within `TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS` (600 seconds by default). Include the
reviewed final Contract when the target transforms rows.

Only a successful migration-job exit starts the new Worker and Request services.
A failed job leaves the new services stopped and provides the blocker for repair
or retry. This is a drained rollout; it consumes all supported intermediate
revisions from the latest image. See [migration operations](migration-operations.md)
for source previews, repair policies and exact role requirements.

## Generate OpenAPI for security scanning

Before deploying to staging, generate a checked specification for the server being deployed:

```bash
tesl --check app.tesl
tesl generate-openapi app.tesl AppServer --output .tesl-stuff/build/openapi.json
```

Give that file to the DAST tool's OpenAPI import. The artifact contains the server's declared
routes, typed captures, request/response schemas, cookie authentication, and proof metadata.
It is a file-based input; the application does not need to expose a public documentation route.
See [OpenAPI and DAST](openapi-dast.md) for the CI workflow and credential-safety guidance.

## How it works

- `tesl build --container` compiles a Linux Go binary, stages a runtime-only
  container context, instantiates a template in [`templates/docker/`](../templates/docker/),
  and runs `docker build`.
- The image serves the same application as local execution. The Worker-topology
  Compose recipe adds a gated migration job, and the direct executable entry point
  receives normal container stop signals. Configure application health checks and
  platform-specific publishing in your deployment controller.

### Building on Apple Silicon / arm64

The Go/Debian base image supports the host architectures published by the Go
container template. `tesl build --container` stages the Dockerfile without
requiring a language-runtime image from the host.

The Go image remains ordinary Docker output, so platform-specific publishing
can use Docker Buildx or the registry workflow without a language-runtime
override.

## See also

- [`tesl.toml` project manifest](tesl-manifest.md) — the manifest `tesl build` reads
- [Getting Started](GETTING-STARTED.md) — build your first API before deploying it
- [Manual Index](MANUAL.md) — back to the main manual
