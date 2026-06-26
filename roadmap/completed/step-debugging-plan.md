# Step Debugging for Tesl — Implementation Plan

## Overview

A VSCode step debugger for Tesl using the Debug Adapter Protocol (DAP). Implements Phase 0 (source maps) and Phase 1 (function + statement level breakpoints, local variable inspection) together.

**Key insight:** The OCaml compiler already tracks `loc` (file, line, col) on every AST node. The emitter has full access to source positions. Phase 0 is therefore an emitter change to inject position annotations into the generated Racket — not a frontend refactor.

---

## Architecture

```
VSCode
  │  DAP JSON-RPC over stdio
  ▼
dsl/debug/dap-server.rkt    (new — handles DAP protocol)
  │  spawns user's .rkt with debug instrumentation
  ▼
dsl/debug/checkpoint.rkt    (new — thsl-checkpoint macro + display helpers)
  │  signals stopped events via Racket channels
  ▼
dap-server.rkt              (receives stopped events, serves variables/stackTrace)
```

The existing `editor/vscode-tesl` extension gains a `debuggers` contribution — no new extension package needed.

---

## Phase 0: Source Map Emission (in OCaml emitter)

The emitter (`compiler/lib/emit_racket.ml`) already receives `loc` on every AST expression. Add a `--debug` flag to the CLI (`compiler/bin/main.ml`).

When `--debug` is active:
1. Wrap each emitted expression with `(thsl-src "file.tesl" LINE expr)` using the `loc.start.line` of the AST node
2. Write a `.tesl.srcmap.json` sidecar alongside the compiled `.rkt`:
   ```json
   { "tesl_file": "foo.tesl", "entries": [{"tesl_line": 12, "rkt_line": 47}, ...] }
   ```

The sidecar allows the DAP server to translate VSCode breakpoint lines into the correct positions.

---

## Phase 1: DAP Server and Checkpoint Macro

### `dsl/debug/checkpoint.rkt` (new)

Global state shared between the executing program and the DAP server thread:
- `breakpoints`: hash of `file → set of lines`
- `event-ch`: channel — program sends stopped events to DAP server
- `paused-ch`: channel — DAP server sends 'continue to program
- `debug-enabled?`: parameter (default `#f`)

**`(thsl-src file line expr)` macro:** When `debug-enabled?`, check `breakpoints`, send stopped event on `event-ch` with locals, block on `paused-ch`, then evaluate `expr`.

**`thsl-display-value`:** Unwraps GDP proof wrappers to show user-level values:
- `named-value` → unwrap to raw value (with proof tags shown as annotations)
- `newtype-value` → unwrap to inner value
- `check-ok` → unwrap to inner value
- `record-value` → recurse on field values
- Plain Racket values → as-is

### `dsl/debug/dap-server.rkt` (new)

Standalone Racket script implementing DAP stdio protocol.

Key message handlers:
- `initialize` → return capabilities (`supportsSetBreakpoints: true`, `supportsVariablesRequest: true`)
- `setBreakpoints` → populate the `breakpoints` hash, return breakpoints array
- `configurationDone` → ready to launch
- `launch` → compile `.tesl` file with `--debug` flag, `(load compiled-path)` in new thread with `(parameterize ([debug-enabled? #t]) ...)`
- `threads` → return `[{id: 1, name: "main"}]`
- `stackTrace` → return one frame: currently paused function + source location
- `scopes` → return one scope: "Locals"
- `variables` → call the `locals-thunk` captured in the stopped event
- `continue` / `next` → `(channel-put paused-ch 'continue)`
- `disconnect` → kill program thread, exit

DAP framing: `Content-Length: N\r\n\r\n{JSON}` (same as LSP).

### VSCode Extension Wiring

In `editor/vscode-tesl/package.json`, add `debuggers` contribution:
```json
"debuggers": [{
  "type": "tesl",
  "label": "Tesl Debugger",
  "languages": ["tesl"],
  "program": "./debug/launch-dap.sh",
  "configurationAttributes": {
    "launch": {
      "required": ["program"],
      "properties": {
        "program": { "type": "string", "description": "Path to the .tesl file to debug" }
      }
    }
  },
  "initialConfigurations": [{
    "type": "tesl",
    "request": "launch",
    "name": "Debug Tesl Program",
    "program": "${file}"
  }]
}]
```

New `editor/vscode-tesl/debug/launch-dap.sh`: finds Racket binary and launches `dap-server.rkt`.

---

## What Phase 1 Leaves Out

**Phase 2 — Step semantics (step over vs step into):**
Phase 1 only has `continue`. `next` (step over) and `stepIn` (step into) require tracking call depth via a `step-depth` parameter. Deferred.

**Phase 4 — Conditional breakpoints:** Pause only when a user-provided expression is truthy. Deferred.

**Phase 4 — Watch expressions:** User-defined expressions evaluated at each pause. Deferred.

**Phase 4 — Edit-and-continue:** Not planned.

**Phase 4 — Remote debugging:** TCP transport instead of stdio. Easy to add once stdio works.

---

## Test Target

At least 80 tests across OCaml compiler tests (`compiler/test/test_debug.ml`), Racket unit tests (`tests/debug-test.rkt`), and integration tests (`tests/debug-tests.tesl`).
