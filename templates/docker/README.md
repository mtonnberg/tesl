# Tesl Docker Templates

Templates package the Go application emitted by `tesl build`.

## Context

```text
context/
  Dockerfile
  tesl-app
```

The host build owns Go compilation. The image contains only the resulting
binary; it does not contain Go, compiler sources, or generated Go sources.
The production base is `gcr.io/distroless/static-debian12:nonroot`: no shell,
package manager, or coreutils are present. The generated context also contains
a strict `.dockerignore` that permits only the binary and Dockerfile.

Run generated images with defense-in-depth flags where supported:

```sh
docker run --read-only --tmpfs /tmp --cap-drop=ALL \
  --security-opt=no-new-privileges IMAGE
```

Pin the distroless base by digest in a release build and scan/sign the result
with the deployment system's approved tools. OCI revision, creation time, and
source labels are emitted into every generated Dockerfile.

## Database

Both template names use an external PostgreSQL service through the standard
`TESL_POSTGRES_*` environment variables. Embedded PostgreSQL is intentionally
not packaged in the image; `Dockerfile.all-in-one.tmpl` is retained as a legacy
name. Use `tesl db` or a separate PostgreSQL container.

For checked Worker-topology histories, `compose.worker.yml.example` and
`deploy-worker.sh` provide a drained rollout using the same latest image:

```sh
TESL_IMAGE=myorg/my-app:RELEASE_COMMIT sh deploy-worker.sh compose.worker.yml
```

Copy the Compose example to `compose.worker.yml` and provide `.env.deploy`,
`.env.worker` and `.env.request`. The deployment job gets Worker configuration and
`TESL_SCHEMA_INSTALLER_DSN`; each long-running service gets only its own credential
scope. `--schema deploy` finishes installation, staging, catch-up and reviewed
target finality. Its successful exit gates service startup. See
[the deployment guide](../../manual/deploy.md#automatic-migration-job-worker-topology).

## Build

```sh
tesl build --container
tesl build --container --no-docker --out ./context
docker build -t myorg/my-app:latest ./context
```

`__APP_NAME__` and `__PORT__` are substituted when a template is instantiated.
