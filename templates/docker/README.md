# Tesl Docker Templates

Templates package the Go application emitted by `tesl build`.

## Context

```text
context/
  Dockerfile
  generated/
    go.mod
    cmd/app/
    internal/
```

The generated module owns the Tesl runtime and application entrypoint. The
image does not contain Racket, `raco`, `.rkt` files, or `PLTCOLLECTS`.

## Database

Both templates use an external PostgreSQL service through the standard
`TESL_POSTGRES_*` environment variables. Embedded PostgreSQL is intentionally
not packaged in a single application image; use `tesl db` or a separate
PostgreSQL container.

## Build

```sh
tesl build --container
tesl build --container --no-docker --out ./context
docker build -t myorg/my-app:latest ./context
```

`__APP_NAME__` and `__PORT__` are substituted when a template is instantiated.
