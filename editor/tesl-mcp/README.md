# tesl-mcp

A [Model Context Protocol](https://modelcontextprotocol.io) (MCP) stdio server that
exposes the Tesl compiler's agent query surface as first-class, discoverable
**tools**. Any MCP-capable agent (Claude Code, etc.) gets the Tesl agent API for
free — type-checking, diagnostics with fixes, type/signature/completion queries,
go-to-definition, references, proof obligations, and a headless step-debugger.

It is a thin JSON-RPC-over-stdio wrapper around the `tesl` compiler binary. MCP
2024-11-05 messages are bounded, newline-delimited JSON; LSP/DAP `Content-Length`
framing is intentionally separate. The Go MCP and LSP share only the bounded
compiler-query client.

## Tools

| Tool | Args | Wraps | Notes |
|------|------|-------|-------|
| `tesl.agent_context` | `{file}` | `--agent-context-json` | **PRIMARY** — read after every edit. `{ok, summary, diagnostics, symbols, proof_obligations}` in one compact snapshot. |
| `tesl.check` | `{file}` | `--check-json` | Coded diagnostics + suggested fixes. |
| `tesl.type_at` | `{file, line, col}` | `--type-at-json` | 0-based line, 0-based col. |
| `tesl.signature` | `{file, line, col}` | `--signature-help-json` | 0-based line, 0-based col. |
| `tesl.completions` | `{file, line, col}` | `--completions-json` | 0-based line, 0-based col. |
| `tesl.definition` | `{file, line, col}` | `--definition-json` | 0-based line, 0-based col. |
| `tesl.references` | `{file, line, col}` | `--occurrences-json` | 0-based line, 0-based col. Same-file occurrences. |
| `tesl.proof_obligations` | `{file}` | `--agent-context-json` (sliced) | Just the `proof_obligations` array. |
| `tesl.debug_inspect` | `{file, breakpoints \| break_at, mode?, timeout_ms?}` | `tesl debug-inspect` | Headless debugger — **you set the breakpoints**, incl. conditional & hit-count. |
| `tesl.debug_attach` | `{project?, action?, break_at?, when?, hit?, timeout_ms?}` | `tesl debug-attach` | Live attach to a running `tesl run --debug` app — arm/re-arm with zero relaunches; the app keeps serving. Actions: `once` (default), `snapshot`, `ping`, `detach`. |

Every tool's text response is the compiler's already-compact JSON, passed through
verbatim — no re-pretty-printing (token economy).

### `tesl.debug_inspect`

You choose where to stop. Pass **either**:

- `break_at`: a list of raw SPEC strings, or
- `breakpoints`: a list of `{line, condition?, hit?}` objects.

SPEC syntax (same as `tesl debug-inspect --break-at`):

```
LINE                 bare, unconditional            e.g. 42
"LINE: <cond>"       conditional (boolean over locals)  e.g. "42: n == 100"
"LINE: <hit>"        hit-count (==|>=|<=|>|<|% N)    e.g. "42: %3"
L1,L2,L3             comma-separated bare lines      e.g. 10,22,40
```

Optional `mode` is `"program"` (default) or `"test"` (run inside the file's
`test` blocks). It compiles the file with debug instrumentation, runs to the
first breakpoint that fires, waits for every active instrumented Tesl execution
to rendezvous at its next debug boundary, and returns one execution-isolated
stack and SQL capture in
`{stopped, source, locals, domain, sql, breakpoint}`.
The long-lived `main` scope blocked in the HTTP server is quiescent: it does not
delay a handler breakpoint and cannot resume through an established stop.
`timeout_ms` defaults to 30000; the MCP subprocess deadline adds a small startup
and shutdown margin to that requested debugger timeout.

Example arguments:

```json
{ "file": "example/learn/lesson61-step-debugging.tesl",
  "mode": "test",
  "breakpoints": [ { "line": 191, "condition": "n == -10" } ] }
```

### `tesl.debug_attach`

Live attach to an **already-running** `tesl run --debug` process — the
counterpart of `tesl.debug_inspect` for long sessions: the app keeps serving,
its accumulated state (queues, caches, sessions) stays intact, and you can
re-arm different breakpoints on every call with zero relaunches.

- `action: "once"` (default; requires at least one `break_at`) — arm the `break_at` breakpoints (as
  `"FILE:LINE"` strings, file spelled as the compiler saw it), wait for the
  first stop (bounded by `timeout_ms`, default 30000), return it, resume, and
  detach.  Trigger the stop yourself — e.g. curl the app's endpoint — while
  the call waits.
- `action: "snapshot"` — the current paused snapshot; while running it reports
  `stopped: false` and does not expose an execution-scoped stack or SQL capture.
- `action: "ping"` — is the attach endpoint alive?
- `action: "detach"` — recovery hatch: disarm everything, resume.

The endpoint is discovered under `<project>/.tesl-stuff/`. When `project` is
omitted, the server walks upward from its working directory to the nearest
`tesl.toml`; discovery fails explicitly if none exists. The result is `{ok,
events: […]}` — the NDJSON
stream from the channel; the `{event: "stopped", locals, domain, sql}` entry
is the paused state.  Optional `when`/`hit` apply a condition / hit-count spec
to every breakpoint.

Example arguments:

```json
{ "project": "/home/me/my-app",
  "break_at": ["app.tesl:42"],
  "when": "userId == \"alice\"",
  "timeout_ms": 30000 }
```

## Running it

The server needs the Tesl compiler binary. It is discovered (in order) via:

1. `TESL_COMPILER` — absolute path to `main.exe`, or
2. `TESL_REPO_ROOT` — repo root containing `compiler/_build/default/bin/main.exe`, or
3. `tesl-compiler` or `tesl` on `PATH`.

Build the compiler first:

```sh
cd compiler && dune build
```

Run the server (it speaks JSON-RPC over stdin/stdout; logs go to stderr):

```sh
TESL_COMPILER="$PWD/compiler/_build/default/bin/main.exe" \
  go run ./runtime/go/cmd/tesl-mcp
```

## Registering with an MCP client

The launch command is `tesl-mcp`, with `TESL_COMPILER` set only when using a
checkout instead of the installed wrapper.

### Claude Code

**Installed via the Nix flake** (`nix profile install github:mtonnberg/tesl`) —
the `tesl-mcp` binary is on your PATH; no repo checkout or env needed (the wrapper
bakes in the compiler + runtime collections, so `tesl.debug_inspect` works too):

```sh
claude mcp add tesl -- tesl-mcp
```

Or run it on demand without installing:

```sh
claude mcp add tesl -- nix run github:mtonnberg/tesl#tesl-mcp
```

**From a repo checkout** (developing Tesl) — point it at your build:

```sh
claude mcp add tesl -e TESL_COMPILER=/abs/path/to/tesl/compiler/_build/default/bin/main.exe -- \
  go run /abs/path/to/tesl/runtime/go/cmd/tesl-mcp
```

Then restart Claude Code (MCP servers load at startup).

### Generic MCP config (`mcpServers` JSON)

```json
{
  "mcpServers": {
    "tesl": {
      "command": "tesl-mcp",
      "args": [],
      "env": {}
    }
  }
}
```

## Tests

```sh
go test ./runtime/go/cmd/tesl-mcp ./runtime/go/internal/protocol
```

The smoke test spawns the server, drives a raw newline-delimited JSON-RPC session
over stdio without sharing the server's framing helper, and
asserts: `initialize` → `serverInfo`; `tools/list` carries every tool with an
`inputSchema`; `tesl.agent_context` on a real lesson parses as the agent-context
JSON; `tesl.debug_inspect` with a conditional breakpoint on lesson61 stops with
the expected local; unknown method → JSON-RPC error `-32601`.

## Not yet wrapped

- `tesl.run_function` (run a single function with concrete inputs) is **deferred**:
  the compiler currently has no per-function runner CLI, and running a compiled
  program requires a generated Go module. Use
  `tesl.debug_inspect` with `mode: "test"` to observe values inside `test` blocks
  in the meantime.
