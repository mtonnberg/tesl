# VSCode Step Debugging — Notes

See `step-debugging-plan.md` for the full, authoritative implementation plan.

## Summary

Building a debugger for Tesl requires bridging three systems:
1. The OCaml compiler (emit `(thsl-src ...)` wrappers using existing `loc` data — already tracked on every AST node)
2. A Racket DAP server (`dsl/debug/dap-server.rkt`) that speaks JSON-RPC over stdio
3. The VSCode extension (`editor/vscode-tesl`) gains a `debuggers` contribution pointing at the DAP server

## Key Protocol Facts

- DAP uses `Content-Length: N\r\n\r\n{JSON}` framing (same as LSP)
- VSCode sends: `initialize`, `setBreakpoints`, `configurationDone`, `launch`, `threads`, `stackTrace`, `scopes`, `variables`, `continue`, `next`, `stepIn`, `disconnect`
- The DAP server responds and also sends `stopped` events when a breakpoint is hit

## GDP Value Display

Tesl values are wrapped in runtime structs. The `thsl-display-value` function in `dsl/debug/checkpoint.rkt` unwraps them:
- `named-value` → show inner value + proof tags as annotations
- `newtype-value` (e.g. `JwtToken`) → show inner string/int/etc.
- `check-ok` → show inner value
- `record-value` → show as key/value dict with recursive unwrapping

## Approach Summary

Because the OCaml compiler already tracks `loc` on every AST node, Phase 0 (source maps) is much easier than it would be for a Python-based compiler. The `emit_racket.ml` emitter can inject `(thsl-src file line expr)` wrappers whenever `--debug` mode is active, using the `loc` information already present on each AST node.

This means Phase 0 and Phase 1 can be implemented together, delivering statement-level breakpoints from the start (not just function-level).
