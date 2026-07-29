---
description: Break into a running Tesl HTTP server — arm a breakpoint in a handler, then curl the endpoint to trigger it and inspect the live request state.
---

# Debug a Tesl server by curling it into a breakpoint

Goal: pause inside a request handler of a running Tesl server, with the **full live
runtime state** (locals + queues/caches/SSE-clients/email/workers + the exact SQL),
triggered by an HTTP request you send yourself — "curl the app to hit a breakpoint".

## Preferred flow: ATTACH to an already-running server (no relaunch)

If the server was started with `tesl run --debug <file.tesl>`, attach to it live —
arm/re-arm breakpoints as often as you like, the server keeps serving throughout:

```bash
tesl run --debug path/to/server.tesl &          # once; keep it running all session
until curl -sf -o /dev/null "http://localhost:PORT/health"; do sleep 0.2; done

# arm a breakpoint, wait for the stop, print it, auto-resume + detach:
tesl debug-attach --break-at path/to/server.tesl:HANDLER_LINE --once \
     --timeout-ms 30000 > /tmp/tesl-bp.json &
sleep 0.5
curl -s "http://localhost:PORT/users/alice"     # triggers the breakpoint
wait; jq . /tmp/tesl-bp.json                    # {event:"stopped", locals, domain, sql}
```

Repeat the `debug-attach` step with a *different* line/condition — **no server
relaunch**. Other verbs: `--snapshot` (paused state + live domain right now),
`--ping` (endpoint alive?), `--detach` (recovery: disarm everything, resume). No
flags at all = an NDJSON bridge on stdin/stdout for interactive stepping
(`{"cmd":"continue"}`, `{"cmd":"step-over"}`, `{"cmd":"snapshot"}`, …). The file in
`--break-at FILE:LINE` is matched as the compiler saw it — absolute, or relative to
the project root (where `tesl run --debug` was started). From VSCodium, the same
session is one F5 away: the "Attach to running app" launch config. MCP agents: the
`tesl.debug_attach` tool wraps exactly this.

## Fallback flow: launch-under-inspector (server NOT started with --debug)

A plain `tesl run` server has its checkpoints erased at expansion time — nothing to
arm. Relaunch it under `tesl debug-inspect` (the gated headless inspector): in
`--mode program` it starts the server in-process and **blocks until the first
breakpoint fires**. A breakpoint on a handler line only executes when a request
reaches it — so your `curl` is what activates it.

## Flow

1. **Find the handler line** you want to pause on (e.g. with `tesl agent-context
   <server.tesl>` to list symbols, or read the file). Optionally add a condition so you
   only stop on the request you care about, e.g. only when a path param has a value.

2. **Launch the server under the inspector in the background** — it serves and waits:
   ```bash
   # start PostgreSQL first if the server is DB-backed:  bash scripts/postgres-start.sh
   TESL_REPO_ROOT="$PWD" \
     tesl debug-inspect path/to/server.tesl \
       --break-at "HANDLER_LINE: userId == \"alice\"" \
       --mode program  > /tmp/tesl-bp.json 2>/tmp/tesl-bp.err &
   INSPECT_PID=$!
   ```
   (`tesl` = `compiler/_build/default/bin/main.exe`.) Use a plain `--break-at HANDLER_LINE`
   for "stop on the next request", or a conditional / `--hit N` spec to target a specific one.

3. **Wait for the server to be listening**, then curl the endpoint to drive the request:
   ```bash
   until curl -sf -o /dev/null "http://localhost:PORT/health" 2>/dev/null; do sleep 0.2; done
   curl -s "http://localhost:PORT/users/alice"        # this request hits the handler breakpoint
   ```

4. **Read the captured state** — the inspector dumps one JSON object and exits when the
   breakpoint fires:
   ```bash
   wait "$INSPECT_PID" 2>/dev/null
   cat /tmp/tesl-bp.json | jq .     # { stopped, source, breakpoint, locals, domain, sql }
   ```
   `locals` is the handler's bindings (proof-unwrapped); `sql` is the exact parameterized
   statement that handler ran; `domain` is every live queue/cache/SSE-client/email/worker.

## Notes & caveats

- **One-shot:** the inspector captures the first matching hit, dumps, and exits (which
  stops the server). Re-launch to inspect another request. Use a **conditional**
  breakpoint to skip uninteresting requests rather than restarting.
- **Startup race:** always poll the port (step 3) before curling; the breakpoint won't
  arm until the server thread is serving.
- **DB-backed servers:** `bash scripts/postgres-start.sh` first (`scripts/init.sh` to set
  up the schema); `scripts/postgres-stop.sh` after.
- **Stop-the-world:** while paused, all other Tesl background threads (workers/timers/SSE)
  are frozen, so the captured `domain`/`sql` is a consistent snapshot.

## History

Live attach used to be the deferred gap here ("arming a breakpoint on an
already-running server without relaunching it"). It landed 2026-07-29 as the
control channel in `dsl/debug/control-channel.rkt` + `tesl run --debug` +
`tesl debug-attach` — see the preferred flow above and
`roadmap/completed/attach_debugger_running_process.md`. The only case still
requiring the launch-under-inspector fallback is a server that was started
*without* `--debug` (its checkpoints were erased at expansion time).
