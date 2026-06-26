# tesl-mcp

A [Model Context Protocol](https://modelcontextprotocol.io) (MCP) stdio server that
exposes the Tesl compiler's agent query surface as first-class, discoverable
**tools**. Any MCP-capable agent (Claude Code, etc.) gets the Tesl agent API for
free — type-checking, diagnostics with fixes, type/signature/completion queries,
go-to-definition, references, proof obligations, and a headless step-debugger.

It is a thin JSON-RPC-over-stdio wrapper around the `tesl` compiler binary, built
on the same framing and compiler-discovery as the Tesl LSP
(`editor/tesl-lsp/tesl-lsp.rkt`).

## Tools

| Tool | Args | Wraps | Notes |
|------|------|-------|-------|
| `tesl.agent_context` | `{file}` | `--agent-context-json` | **PRIMARY** — read after every edit. `{ok, summary, diagnostics, symbols, proof_obligations}` in one compact snapshot. |
| `tesl.check` | `{file}` | `--check-json` | Coded diagnostics + suggested fixes. |
| `tesl.type_at` | `{file, line, col}` | `--type-at-json` | line 1-based, col 0-based. |
| `tesl.signature` | `{file, line, col}` | `--signature-help-json` | |
| `tesl.completions` | `{file, line, col}` | `--completions-json` | |
| `tesl.definition` | `{file, line, col}` | `--definition-json` | |
| `tesl.references` | `{file, line, col}` | `--occurrences-json` | Same-file occurrences. |
| `tesl.proof_obligations` | `{file}` | `--agent-context-json` (sliced) | Just the `proof_obligations` array. |
| `tesl.debug_inspect` | `{file, breakpoints \| break_at, mode?}` | `tesl debug-inspect` | Headless debugger — **you set the breakpoints**, incl. conditional & hit-count. |

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
first breakpoint that fires (stop-the-world), and returns
`{stopped, source, locals, domain, sql, breakpoint}`.

Example arguments:

```json
{ "file": "example/learn/lesson61-step-debugging.tesl",
  "mode": "test",
  "breakpoints": [ { "line": 191, "condition": "n == -10" } ] }
```

## Running it

The server needs the Tesl compiler binary. It is discovered (in order) via:

1. `TESL_COMPILER` — absolute path to `main.exe`, or
2. `TESL_REPO_ROOT` — repo root containing `compiler/_build/default/bin/main.exe`, or
3. two directories up from this server (`editor/tesl-mcp/` → repo root).

Build the compiler first:

```sh
cd compiler && dune build
```

Run the server (it speaks JSON-RPC over stdin/stdout; logs go to stderr):

```sh
TESL_REPO_ROOT="$PWD" racket editor/tesl-mcp/tesl-mcp.rkt
```

## Registering with an MCP client

The launch command is `racket <abs path>/editor/tesl-mcp/tesl-mcp.rkt` with
`TESL_REPO_ROOT` pointed at your Tesl checkout.

### Claude Code

```sh
claude mcp add tesl -e TESL_REPO_ROOT=/abs/path/to/tesl -- \
  racket /abs/path/to/tesl/editor/tesl-mcp/tesl-mcp.rkt
```

### Generic MCP config (`mcpServers` JSON)

```json
{
  "mcpServers": {
    "tesl": {
      "command": "racket",
      "args": ["/abs/path/to/tesl/editor/tesl-mcp/tesl-mcp.rkt"],
      "env": { "TESL_REPO_ROOT": "/abs/path/to/tesl" }
    }
  }
}
```

## Tests

```sh
racket editor/tesl-mcp/tests/protocol-smoke.rkt
```

The smoke test spawns the server, drives a full JSON-RPC session over stdio, and
asserts: `initialize` → `serverInfo`; `tools/list` carries every tool with an
`inputSchema`; `tesl.agent_context` on a real lesson parses as the agent-context
JSON; `tesl.debug_inspect` with a conditional breakpoint on lesson61 stops with
the expected local; unknown method → JSON-RPC error `-32601`.

## Not yet wrapped

- `tesl.run_function` (run a single function with concrete inputs) is **deferred**:
  the compiler currently has no per-function runner CLI, and running a compiled
  program requires the `tesl/*` Racket collection to be registered. Use
  `tesl.debug_inspect` with `mode: "test"` to observe values inside `test` blocks
  in the meantime.
