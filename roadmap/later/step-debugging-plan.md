# Step Debugging for Tesl — Implementation Plan

## Is this a suitable goal?

Yes, with caveats. The AI-generated outline in `support_step_debugging_vscode.md` identifies the
right protocol (DAP) and the right Tesl-specific concern (source maps). However, it understates
the difficulty of the source-map problem and glosses over several Tesl-specific complications
that make this substantially harder than a generic compiled-language debugger.

**This is a large project** — roughly 3–5 weeks of focused work for a production-quality
debugger. A minimal "function-level breakpoints + variable inspection" version is achievable
in 1–2 weeks.

---

## Fundamental challenges

### 1. No source positions in the compiler today

The Python compiler (`compile_thsl.py`) operates on `body_lines: list[str]` — plain strings with
no reference to the original `.tesl` line numbers. The `to_structured_lines` function further
strips blank lines and reduces each line to `(indent, text)`. By the time `BodyCompiler` emits
Racket, the original line numbers are gone.

**Without source maps, the debugger can only support function-granularity breakpoints**
(pause when entering function `foo`). Per-statement breakpoints require threading absolute
source line numbers through the entire body compiler — a significant refactor.

### 2. Two-stage compilation: .tesl → Racket → compiled bytecode

The user sees `.tesl` line 12. The Racket runtime executes a `.rkt` expression at some
generated line. The OS debugger only knows about bytecode positions. The chain requires:

```
.tesl line N  →  generated .rkt line M  →  Racket bytecode source location
```

Racket's syntax objects carry source location natively, so if we emit them correctly the
bytecode side is handled automatically. The hard part is the `.tesl → .rkt` mapping.

### 3. GDP value representation

Tesl values at runtime are wrapped:
- Named values: `(named-value subject val proof)`
- Newtypes: `(newtype-value 'UserId "hello")`
- Check results: `(check-ok val proof)`

The debugger must unwrap these to show `"hello"` or `42`, not Racket structs.

### 4. Compilation caching

Tesl caches compiled `.rkt` bytecode in temp directories. For debugging, we need to compile
in "debug mode" with checkpoint instrumentation enabled — bypassing the cache, or using a
separate debug cache.

---

## Architecture

```
VSCodium
    │  DAP JSON-RPC over stdio
    ▼
tesl-dap-server.rkt       (new: dsl/debug/dap-server.rkt)
    │  spawns + controls
    ▼
user's compiled .rkt        (recompiled with debug instrumentation)
    │  contains
    ▼
(thsl-checkpoint …)         (new: dsl/debug/checkpoint.rkt)
    │  signals paused/resumed via channels
    ▼
tesl-dap-server.rkt        (receives stopped events, serves variables/stackTrace)
```

The existing `vscode-thsl` extension gains a `debuggers` contribution pointing at
`tesl-dap-server.rkt` — no new extension package needed.

---

## Phased implementation plan

### Phase 0: Source map infrastructure (prerequisite for line-level debugging)

This is the hardest phase and a prerequisite for everything beyond function-level debugging.

**0a. Thread line numbers through `parse_function_block`**

`FunctionDecl` currently stores `body_lines: list[str]`. Change to `body_lines: list[tuple[int, str]]`
where the int is the 0-indexed absolute `.tesl` source line:

```python
@dataclass
class FunctionDecl:
    kind: str
    name: str
    args: list[Binding]
    return_spec: dict
    capabilities: list[str]
    body_lines: list[str | tuple[int, str]]  # (abs_line, text) when debug info present
```

In `parse_function_block`, after extracting `body_lines = dedent_lines(block[body_start:], 2)`,
also compute `body_abs_lines = [form_start_line + body_start + i for i in range(len(body_lines))]`.
Store as `body_lines_with_pos = list(zip(body_abs_lines, body_lines))`.

**0b. Thread through `to_structured_lines`**

`to_structured_lines` currently returns `list[tuple[int, str]]` = `(indent, text)`.
When source positions are available, extend to `list[tuple[int, str, int]]` = `(indent, text, abs_line)`.
Since blank lines are dropped, the mapping is approximate but good enough for breakpoints.

**0c. Emit source location in `BodyCompiler`**

In `BodyCompiler.compile_statement` and `compile_sequence`, when a source position is known,
wrap the emitted Racket expression with a syntax-location annotation:

```racket
; Option A: simple comment (sufficient for breakpoints if we parse the .rkt)
; thsl-src: foo.tesl:12

; Option B: racket/contract-style source location on the syntax object
; achieved by emitting: (thsl-src "foo.tesl" 12 (original-expr))
```

Option B is required for proper DAP source location reporting.

**0d. Emit source map sidecar**

During debug-mode compilation, write a `.tesl.srcmap.json` sidecar next to the compiled `.rkt`:
```json
{
  "thsl_file": "foo.tesl",
  "entries": [
    {"thsl_line": 12, "rkt_line": 47},
    {"thsl_line": 14, "rkt_line": 49}
  ]
}
```

The DAP server loads this to translate breakpoint lines.

---

### Phase 1: Minimal viable debugger (function-level, no source maps needed)

**Skip Phase 0 and ship something useful sooner.**

Tesl function boundaries are well-defined. We can pause at function entry/exit without
per-statement source maps.

**1a. `dsl/debug/checkpoint.rkt`**

```racket
#lang racket

; Global state shared between the executing program and the DAP server thread.
(define breakpoints (make-hash))        ; (hash "foo.tesl" (set 10 15))
(define paused-ch (make-channel))       ; DAP server sends 'continue or 'step
(define event-ch (make-channel))        ; program sends stopped events to DAP server
(define debug-enabled? (make-parameter #f))

(define (thsl-fn-entry! thsl-file thsl-line fn-name locals-thunk)
  (when (debug-enabled?)
    (define bp-lines (hash-ref breakpoints thsl-file (set)))
    (when (set-member? bp-lines thsl-line)
      ; Send "stopped" event to DAP server
      (channel-put event-ch
        (hasheq 'event "stopped"
                'body (hasheq 'reason "breakpoint"
                              'threadId 1
                              'description (format "~a line ~a" fn-name thsl-line)
                              'locals (locals-thunk))))
      ; Block until DAP server sends continue/next
      (channel-get paused-ch))))
```

**1b. Compiler instrumentation (debug mode only)**

Add `--debug` flag to `compile_thsl.py`. In debug mode, `emit_function_form` wraps each
function body with a call to `thsl-fn-entry!`:

```racket
(define (greet name)
  (thsl-fn-entry! "foo.tesl" 14 "greet"
    (lambda () (list (cons "name" (thsl-display-value name)))))
  ; ... rest of body
  )
```

The `locals-thunk` is a zero-arg lambda that, when called by the debugger, evaluates the
current values of all function parameters and returns them as an association list.

**1c. Value rendering: `thsl-display-value`**

```racket
(define (thsl-display-value v)
  (cond
    [(named-value? v)   (thsl-display-value (named-value-subject v))]
    [(newtype-value? v) (thsl-display-value (newtype-value-value v))]
    [(check-ok? v)      (thsl-display-value (check-ok-value v))]
    [(record-value? v)  (for/hash ([(k vv) (record-value-fields v)])
                          (values k (thsl-display-value vv)))]
    [else v]))
```

**1d. `dsl/debug/dap-server.rkt`**

A standalone Racket script implementing the DAP stdio protocol.

Key message handlers:
- `initialize` → return capabilities (`supportsSetBreakpoints`, `supportsVariablesRequest`)
- `setBreakpoints` → populate the `breakpoints` hash table
- `launch` → compile the `.tesl` file with `--debug` flag, then `(load compiled-path)` in
  a new thread with `(parameterize ([debug-enabled? #t]) ...)`
- `threads` → return `[{id: 1, name: "main"}]`
- `stackTrace` → return one frame: the currently paused function + line
- `scopes` → return one scope: "Locals"
- `variables` → call the `locals-thunk` captured in the stopped event
- `continue` / `next` → `(channel-put paused-ch 'continue)`
- `disconnect` → kill the program thread, exit

DAP stdio format (same as LSP):
```
Content-Length: <N>\r\n\r\n<N bytes of JSON>
```

**1e. VSCode extension wiring**

In `vscode-thsl/package.json`, add to `contributes`:

```json
"debuggers": [{
  "type": "tesl",
  "label": "Tesl Debugger",
  "languages": ["thsl"],
  "program": "./debug/launch-dap.sh",
  "configurationAttributes": {
    "launch": {
      "required": ["program"],
      "properties": {
        "program": {
          "type": "string",
          "description": "Path to the .tesl file to debug"
        }
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

`launch-dap.sh` finds the Racket executable and launches `tesl-dap-server.rkt`.

---

### Phase 2: Statement-level stepping (requires Phase 0)

Once source maps are in place, extend `thsl-fn-entry!` to per-statement checkpoints:

```racket
(define-syntax-rule (thsl-src file line expr)
  (begin
    (thsl-checkpoint! file line)
    expr))

(define (thsl-checkpoint! thsl-file thsl-line)
  (when (debug-enabled?)
    ; check breakpoints, emit stopped event, wait for continue/step
    ...))
```

The compiler emits `(thsl-src "foo.tesl" 12 original-expr)` around each statement.

Support for `next` (step over) vs `stepIn` (step into) requires tracking call depth —
achievable with a `step-depth` parameter and a depth counter in `thsl-fn-entry!`.

---

### Phase 3: Proof/capability display

Enhance the `variables` response to show GDP information:

```
▼ name : "Alice"   [IsTrimmed]
  age  : 30        [IsPositive age]
```

When `(named-value? v)`, extract the proof tag from `(named-value-proof v)` and display
it as a "tag" annotation. This makes the debugger GDP-aware and uniquely useful for
understanding proof flow.

---

## What the AI-generated spec got right

- DAP is the correct protocol
- The `debug-hook` / `thsl-checkpoint` macro approach is sound
- Continuation marks are a valid alternative (but compiler-assisted explicit locals are cleaner)
- The overall architecture (separate DAP server process, stdio communication) is correct

## What it got wrong / understated

- **Source maps are the hard part.** The AI glosses over this; it's actually the prerequisite
  that determines whether you get function-level or statement-level debugging.
- **The compiler doesn't track source positions today.** This needs to be fixed first.
- **GDP value unwrapping is non-trivial.** There are 4+ layers of wrapping to strip.
- **No separate extension needed.** The existing `vscode-thsl` extension can host the debugger
  contribution — no `yo code` scaffolding required.
- **Compilation caching conflict.** The debug build needs its own cache or must disable caching.

---

## Recommended starting point

**Phase 1d first** — build a standalone `dap-server.rkt` that handles the DAP protocol
without any Tesl integration (just "launch" a Racket script and handle continue/variables
with dummy data). This validates the plumbing before the Tesl-specific work begins.

Then **Phase 1b** — add `--debug` to the compiler and emit `thsl-fn-entry!` calls.
Function-level breakpoints with local variable inspection covers the most common debugging
use case and can be shipped before the source-map work is done.
