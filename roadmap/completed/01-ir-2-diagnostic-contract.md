# IR-2: Diagnostic Contract

## Status

This item is about stabilizing the boundary between the Tesl compiler and editor-facing tooling.

It began as a **now** task rather than a speculative rewrite note, and the core deliverables are now implemented in the current repository:

- `editor/protocol.md` exists as the normative protocol document
- the Python compiler emits a versioned `--check-json` response
- the LSP consumes the documented response directly for compiler-provided primary ranges
- regression coverage exists in `tests/test_editor_protocol.py`

Any future compiler implementation must adopt the same contract rather than inventing a new one.

## Problem

Today, the compiler/LSP boundary is real but implicit.

The current LSP:

- writes the current buffer to a temporary `.tesl` file
- shells out to `compile_tesl.py --check-json`
- assumes the compiler prints a bare JSON array of diagnostics
- reconstructs token ranges heuristically from the human-readable diagnostic message when the compiler does not provide enough location data
- injects additional editor-side diagnostics beyond what the compiler reports

The current compiler side is also narrower than what the editor needs:

- `--check-json` prints a bare array, not a versioned response envelope
- diagnostics use `line`/`col` but do not provide exact end ranges
- there is no explicit compatibility contract for `fix` payloads
- there is no written rule for what must remain stable across implementations

That is workable for a single in-repo implementation. It is not good enough for a language that wants a durable editor story, a future shared compiler service, or a compiler rewrite.

## Scope

IR-2 covers only the editor/tooling protocol for:

- diagnostics
- structured fixes
- formatting responses
- compatibility/versioning expectations

IR-2 does **not** define:

- typed semantic IR
- proof/capability/program representation
- API generation IR
- the internal architecture of the compiler

Those are separate concerns.

## Current implementation reality

The contract should be written against the implementation that exists now.

### Compiler side today

The current Python compiler emits diagnostics from `--check-json` near `tesl/private/compile_tesl.py:9961-9971`.

Broadly:

- linter failures become JSON objects with `line`, `col`, `severity`, `code`, and `message`
- parse failures become JSON objects with the same basic shape
- the final output is `json.dumps(diags)` of a bare array

### LSP side today

The current LSP integration in `editor/tesl-lsp/tesl_lsp.py:1353-1415`:

- runs the compiler as a subprocess with `--check-json`
- parses the returned JSON array
- tries to infer a better highlight range from names quoted in the message text
- falls back to line-leading indentation when no better token can be found
- adds local editor-side checks such as `_field_access_diagnostics(...)`
- returns a warning diagnostic on timeout (`Tesl: type-check timed out (> 15 s)`)

That means the actual diagnostic contract today is partly compiler-defined and partly LSP-invented. IR-2 should remove that ambiguity.

## Goal

Define and adopt a documented protocol so that:

1. the current compiler can emit diagnostics in a stable, versioned shape
2. the current LSP can consume that shape directly
3. future compilers must match the same contract before editor cutover
4. later work on a persistent compiler service can reuse the same payloads instead of redesigning them

## Deliverables

The deliverables for IR-2 are:

- `editor/protocol.md` as the normative protocol document
- a versioned `--check-json` response in the current compiler
- an LSP update that consumes the documented response directly
- tests that lock the response format and version behavior

## Required protocol

### 1. Response envelope

Compiler responses used by editor tooling must be wrapped in a top-level object with a version field.

Example:

```json
{
  "version": 1,
  "diagnostics": []
}
```

Why:

- it gives the LSP something explicit to validate
- it prevents silent drift in response shape
- it makes compatibility checks possible across compiler implementations

A bare JSON array is no longer sufficient.

### 2. Diagnostic object shape

Each diagnostic must include:

- `file`: absolute source path
- `start`: `{ "line": int, "col": int }` using 0-based coordinates
- `end`: `{ "line": int, "col": int }` using 0-based coordinates
- `severity`: `"error" | "warning" | "info"`
- `code`: machine-readable code such as `E000` or `W031`
- `message`: human-readable text
- `fix`: structured fix object or `null`

Optional fields may include:

- `source`: subsystem such as `parser`, `typecheck`, or `lint`
- `related`: secondary locations/messages

Important rule: the compiler must provide the primary range directly. The LSP should not need to recover the intended token by scraping message text.

### 3. Fix payload shape

The fix payload must be a tagged object with a stable `kind` field.

The first version should keep this intentionally small and editor-friendly. Prefer edit descriptions over semantic commands.

Example kinds:

```json
{ "kind": "replace_range", "start": { "line": 12, "col": 2 }, "end": { "line": 12, "col": 7 }, "replacement": "title" }
{ "kind": "replace_line",  "line": 12, "replacement": "  title: String" }
{ "kind": "insert_text",   "position": { "line": 7, "col": 0 }, "text": "  let checked = ...\n" }
```

Rules:

- unknown `fix.kind` values must be ignored by the LSP, not treated as fatal
- a diagnostic remains meaningful even when its fix is ignored
- fix payloads should describe edits that any compiler implementation can emit

### 4. Check request/response shape

IR-2 should define the payload shape for both one-shot CLI adapters and any future persistent compiler service.

Check request:

```json
{ "op": "check", "file": "/absolute/path.tesl", "content": "..." }
```

Check response:

```json
{ "version": 1, "diagnostics": [ ... ] }
```

Format request:

```json
{ "op": "fmt", "file": "/absolute/path.tesl", "content": "..." }
```

Format response:

```json
{ "version": 1, "formatted": "...", "diagnostics": [ ... ] }
```

Formatting failures should also come back as diagnostics. There should not be a second incompatible error envelope just for editor use.

### 5. Timeout and restart contract

For any persistent compiler service mode:

- the client sends one request at a time
- timeout is 15 seconds for `check`
- timeout is 10 seconds for `fmt`
- on timeout or crash, the client restarts the process and retries once
- if the retry fails too, the editor publishes one warning diagnostic at line 0 explaining that the compiler process is unavailable

For one-shot CLI mode, the same timeout expectations apply at the client level even though restart is naturally just “run the command again”.

### 6. Compatibility policy

The current Python compiler must be updated to the documented shape before any rewrite work depends on IR-2 being “done”.

That means IR-2 is **not** complete if it exists only as documentation for a future compiler.

Minimum compatibility steps:

- stop emitting a bare diagnostic array from `--check-json`
- emit the versioned response wrapper now
- add exact end positions now
- update the LSP to consume the documented fields directly
- keep the documented field names stable

A future compiler implementation may improve internals, startup time, caching, or language-server integration, but it must not casually change the editor contract.

## Rollout order

The work should happen in this order:

1. Write `editor/protocol.md`
2. Update the Python compiler’s `--check-json` output to match it
3. Update the LSP to consume the documented shape directly
4. Add tests for version, required fields, and unknown-fix handling
5. Only then treat IR-2 as a stable target for future compiler work

Persistent stdio/daemon mode is a follow-on optimization, not a prerequisite for IR-2.

## Non-goals

IR-2 is not trying to solve all editor/compiler architecture problems at once.

It is not:

- a demand to replace the one-shot CLI immediately
- a demand to stop all editor-side diagnostics immediately
- a full compiler-service design
- a proof/type/capability IR
- a commitment to any particular future implementation language

The point is narrower: make the tooling boundary explicit and durable.

## Success criteria

IR-2 is complete when all of the following are true:

- `editor/protocol.md` exists and is treated as the normative contract
- the current Python compiler emits the documented versioned `--check-json` response
- the LSP reads that response directly for primary diagnostic ranges instead of scraping message text to guess them
- unknown `fix.kind` values are ignored safely
- regression tests lock the response shape
- any future compiler implementation is required to match the same contract before editor cutover
