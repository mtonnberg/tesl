# __APP_NAME__

A minimal Tesl web service — cookie auth + telemetry, **no database**. Generated
by `tesl init` from the `minimal` template.

## Files

| file        | what it is |
|-------------|------------|
| `app.tesl`  | the application: one HTTP route, cookie auth, two proofs (see below) |
| `tesl.toml` | the project manifest (`[database].mode = "none"`, `[deploy].target = "local"`) |

## The two proofs (the point of Tesl)

1. **Input proof — `Positive taskId`.** The route parameter `:taskId` is run
   through the `isPositive` check (wired in via `capture`). The handler only
   ever sees a `taskId` that is *proven* positive; a non-positive id is rejected
   with `400` before the handler runs.
2. **Output proof — `Int ? Positive`.** The handler returns the still-proven id
   using the `?` return spec. The positivity guarantee survives the round trip
   instead of being silently dropped. (A `handler` can never *mint* a new proof;
   it can only carry one it received — that is what makes the proof trustworthy.)

## Run it

```sh
tesl build        # type-check + compile (proofs are enforced here)
tesl run          # serve on $PORT (default 8088)

# in another shell:
curl -b 'user=alice' localhost:8088/tasks/2
```

Edit `app.tesl` and add a second route or a new `fact` — the type checker tells
you exactly which proofs are still missing.
