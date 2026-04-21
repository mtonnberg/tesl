# Verbose Ambient Logging

> **Implemented** — `TESL_VERBOSE=1` enables runtime logging with zero overhead when disabled.

## What was built

### `tesl/logging.rkt`

Central logging module. `tesl-verbose?` is a boolean evaluated once at module load time from `TESL_VERBOSE`. All logging functions are standard Racket functions with a cheap `(when tesl-verbose? ...)` guard at each call site.

### Instrumented locations

| Location | What is logged |
|---|---|
| `dsl/web.rkt` `dispatch-request` | `→ METHOD /path` on entry; `← STATUS METHOD /path (Nms)` on exit with elapsed ms |
| `dsl/sql.rkt` postgres functions | SQL string (condensed to one line) + bound parameters in `[p1, p2, ...]` |
| `tesl/queue.rkt` `enqueue!` | `enqueue JobType id=job-id` |
| `tesl/queue.rkt` `process-next-job!` | `dequeue`, `done`, or `fail` with attempt count |
| `tesl/queue.rkt` `publish-event!` | `publish ChannelName(key)` |
| `tesl/queue.rkt` `call-in-memory-listeners` | `deliver outbox#N ChannelName(key) → N listener(s)` |

### Usage

```bash
TESL_VERBOSE=1 racket compiled-app.rkt
```

Example output for a chat message:
```
[TESL][HTTP] → POST /rooms/room-1/messages
[TESL][SQL] insert into "chat"."messages" ("id", "room_id", ...) values ($1, $2, ...) [msg-abc, room-1, ...]
[TESL][SQL] select pg_notify($1, $2) [tesl_pubsub, 42]
[TESL][QUEUE] enqueue NotifyJob id=job-xyz
[TESL][PUBSUB] publish RoomMessages(room-1)
[TESL][PUBSUB] deliver outbox#42 RoomMessages(room-1) → 2 listener(s)
[TESL][HTTP] ← 200 POST /rooms/room-1/messages (18ms)
```

### Zero overhead guarantee

- `tesl-verbose?` is a module-level boolean, computed once at program start.
- Every log call site is `(when tesl-verbose? ...)` — one boolean read.
- String formatting only executes when `tesl-verbose?` is `#t`.
- No runtime parameters, no locks, no allocation when disabled.

## Design notes

- All output goes to **stderr** — doesn't interfere with stdout/HTTP responses.
- SQL parameters are shown but are NOT interpolated into the SQL string (the parameterized query remains safe).
- The NOTIFY queries from the outbox pattern also appear as SQL lines so you can trace the full event flow.

## shell.nix

The `tesl help` output now documents the env var.

## LANGUAGE-SPEC.md

Section A.4 added in Appendix A documenting the feature.
