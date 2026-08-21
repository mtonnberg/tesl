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

## Database

Both template names use an external PostgreSQL service through the standard
`TESL_POSTGRES_*` environment variables. Embedded PostgreSQL is intentionally
not packaged in the image; `Dockerfile.all-in-one.tmpl` is retained as a legacy
name. Use `tesl db` or a separate PostgreSQL container.

## Build

```sh
tesl build --container
tesl build --container --no-docker --out ./context
docker build -t myorg/my-app:latest ./context
```

`__APP_NAME__` and `__PORT__` are substituted when a template is instantiated.
