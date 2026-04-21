# Time Module — PosixMillis and POSIX Milliseconds

> **Implemented** — `Tesl.Time` exports `PosixMillis` newtype and a full suite of time functions.

## What was built

### PosixMillis newtype

```tesl
import Tesl.Time exposing [PosixMillis, nowMillis, formatTime, ...]
```

`PosixMillis` is a nominal newtype wrapping `Int`. It is the canonical Tesl timestamp type.

- **Database**: `PosixMillis` entity fields automatically map to `BIGINT` — no `@db(bigint)` annotation needed.
- **Constructor**: `PosixMillis(ms)` where `ms` is a plain `Int`.
- **Accessor**: `.value` extracts the raw integer.
- **DB auto-coercion**: the SQL layer wraps bigint values in `PosixMillis` on read and unwraps on write.

### Functions

| Function | Signature | Notes |
|---|---|---|
| `nowMillis()` | `→ PosixMillis` | Current time in ms (requires `time` capability) |
| `now()` | `→ Int` | Legacy: current time in seconds |
| `formatTime(ms, tz, fmt)` | `→ String` | strftime-style formatting |
| `durationMs(pastMs)` | `→ Int` | ms elapsed since pastMs |
| `addMs(ts, delta)` | `→ PosixMillis` | timestamp + delta ms |
| `subtractMs(ts, delta)` | `→ PosixMillis` | timestamp − delta ms |
| `diffMs(a, b)` | `→ Int` | b − a in ms |
| `Time.posixToSeconds(ms)` | `→ Int` | ms → seconds |
| `Time.secondsToPosix(s)` | `→ PosixMillis` | seconds → ms |

### Entity field pattern

```tesl
entity Post table "posts" primaryKey id {
  id:          String
  publishedAt: PosixMillis    # BIGINT automatically — no @db annotation needed
}

handler createPost(...) requires [dbWrite, time] =
  insert Post { id: newId, publishedAt: nowMillis() }
```

### Why BIGINT not TIMESTAMPTZ

Both are 8-byte columns. BIGINT/epoch:
- No timezone surprises (always UTC-relative milliseconds)
- Pure integer arithmetic for comparisons and durations
- Portable across database backends
- Convert when needed: `to_timestamp(ts / 1000.0)` and `extract(epoch from ts) * 1000`

### Function parameter convention

Function parameters that receive timestamps use `Int` (not `PosixMillis`) so that test code can pass plain integer literals. In Tesl handler code, `PosixMillis` values are auto-unwrapped to `Int` when passed to `Int` parameters via the `*name` raw-access mechanism.

### Tutorial

See `example/learn/lesson26-time-and-posix.tesl`.
