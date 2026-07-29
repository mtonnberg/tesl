# Debugger value lenses, the Copy button, and quick-fix titles

Status: **done**.

Three editor-facing complaints, reported together:

1. Breakpoint value lenses were "sometimes just a JSON string instead of an
   expandable value tree".
2. The **Copy** button on the SQL preview did nothing — suspected to be general.
3. Domain values (queues, caches, SSE channels) were "non-expandable sometimes",
   possibly only when **attached** rather than launched.
4. (Added mid-wave.) Quick-fix menu entries almost always read
   `Apply fix for W010`.

Each turned out to have a distinct root cause, and each is now closed by making
one thing authoritative rather than by patching the symptom.

## 1 + 3. Value lenses: expandability was decided independently of display

The debugger had **three** surfaces rendering a paused frame's values, and they
had grown three different notions of what a value's children are:

| surface | before |
|---|---|
| `dap-server.rkt` launch mode | a lazy `variablesReference` tree |
| `dap-server.rkt` attach mode | flat rows, `variablesReference: 0` hardcoded |
| `headless-inspect.rkt` (→ control channel, `tesl debug-inspect`, MCP) | flat `{name,value,type}` strings |

Two independent roots:

**R1 — wrappers were not unwrapped before deciding expandability.** Launch mode
tested the *outer* Racket representation: `record-value?`, `list?`, `hash?`,
`domain-object?`. But Tesl values routinely arrive wrapped — a proof-carrying
binding is a `named-value` around the record, a `check`ed one a `check-ok`, a
Money/units one a `newtype-value` — and an ADT payload (`Ok(record)`,
`Some([...])`) matched **no branch at all**. `safe-display` unwraps all of those,
so the value column showed inner structure next to a variable that claimed to
have no children. This affected launch mode too, not just attach.

**R2 — the flat surfaces discarded structure at the source.** The control channel
streamed one flat row per local, so attach mode had nothing to build a tree from
even in principle, and its `rendered->variables` hardcoded ref `0`.

**Fix.** `dsl/debug/value-tree.rkt` is now the single answer to both questions —
`value-children` (what expands) and `value-display` / `value-type` (how it
reads) — and both unwrap identically. Launch mode stays lazy and walks
`value-children` one level per request; the flat surfaces serialise the same
enumeration eagerly as a bounded nested `children` tree, which attach mode
rebuilds refs over. Six duplicated child-builders in `dap-server.rkt` and two
copies of `infer-type-string` collapsed into it.

**What prevents recurrence.** `tests/dap-value-tree-tests.rkt` pins:

> **COMPOSITE-IMPLIES-EXPANDABLE** — if `value-display` renders a value with
> inner structure, `value-children` must return at least one child.

It is measured from the **display string**, so it cannot be satisfied by teaching
both sides the same wrong answer; and the same suite asserts the eager wire tree
equals the lazy launch-mode tree node-for-node, so the two panels cannot diverge
again. `tests/dap-attach-value-tree-smoke.rkt` covers the wire JSON itself.

Also fixed along the way:

- **ADT field ordering** — `checkpoint.rkt` now exports `adt-field-keys-ordered`,
  shared by `safe-display-adt` and the expanded child list, so the value column
  and the tree cannot order fields differently.
- **`safe-display` recursed without bound.** A self-referential value made it
  recur forever — which does not raise, so no `with-handlers` caught it: it
  *hung the paused debuggee*. Now depth-bounded (12, far above real nesting),
  emitting `…` past the cap.
- **JSON-document strings are drillable.** Tesl stores ADTs and job payloads as
  JSON text, so a local (especially a bound SQL param) can be a string that is
  really a document. Tightly guarded: must open with `{`/`[`, parse, and be a
  non-empty object/array.

## 2. Copy Value: a silent-success dispatch default

VSCodium does not copy the `value` string it already holds — it resolves the
variable's `evaluateName` through an **`evaluate`** request (with context
`clipboard`, once the adapter advertises `supportsClipboardContext`) and copies
that response.

The adapter implemented **no `evaluate` handler**, and its dispatch default
answered every unknown command with `success: true` and an empty body "to keep
the session alive". So the client received a cheerful empty success and copied an
empty string — with no error anywhere to hint the request was unimplemented. The
user's guess that it was general was right: it broke copy on *every* variable,
and hover and watch expressions too.

**Fix.**

- Every emitted variable carries a stable dotted `evaluateName`
  (`job.payload.amount`, `xs[0]`, `sql.preview`, `sql.params.$1`), registered per
  stop with both the displayed text and the **complete untruncated** text — so
  copying a summarised wide hash or a long SQL preview yields the whole value.
- `evaluate` is a **pure lookup** in that registry, not an expression evaluator:
  a debugger that can run arbitrary code inside a paused live process is a hazard
  none of these features need.
- `supportsClipboardContext` + `supportsEvaluateForHovers` advertised.
- **The dispatch default is now truthful**: unimplemented commands respond
  `success: false` naming the command, with an explicit allowlist for the setup
  commands clients send unconditionally. This is the design change — it is why
  the next missing command will be loud instead of invisible.
- The SQL `preview` row's name was shortened (the "not executed" caveat moved to
  the type column); a name long enough to push the value out of the panel was
  unreadable.

## 4. Quick-fix titles

The LSP synthesized `Printf.sprintf "Apply fix for %s" code` itself, so every
action read `Apply fix for W010`. A diagnostic code is not a description of an
edit: the menu said nothing about what would change, and simultaneous actions
were indistinguishable.

`Diag_fix.title ~code fix` now derives a specific imperative title from the
diagnostic's **code** (the producing pass's intent) plus the edit's kind and
content, and `Compile.fix_to_json` ships it on the wire so every client agrees:

| before | after |
|---|---|
| `Apply fix for W010` | `Remove trailing whitespace` |
| `Apply fix for W011` | `Re-indent to a multiple of 2 spaces` |
| `Apply fix for W050` | `Remove this unused import` / `Remove the unused names, keeping Int from Tesl.Prelude` |
| `Apply fix for T001` | `Import map from Tesl.List` · `Change \`+\` to \`++\`` · `Remove \`return\`` |
| `Apply fix for E002` | `Delete the obsolete \`#lang tesl\` line` |
| `Apply fix for E000` | `Move the body onto its own indented line` |

The LSP adds one refinement the compiler cannot: for a column-precise
`replace_range` it holds the buffer, so it can name **both** sides
(`Change \`+\` to \`++\``, `Remove \`return\``) where the fix alone carries only
the new text.

**What prevents recurrence.** `test/test_fix_titles.ml` runs the real pipeline
over a corpus covering every fix producer and asserts each shipped title is
specific, imperative, menu-sized, and mentions no diagnostic code — plus
**completeness**: every code observed shipping a fix must appear in
`Diag_fix.titled_codes`, so a new fix-shipping diagnostic fails the suite until
its title is written. The string `"Apply fix for"` no longer exists in the tree.

## Incidental

`editor/tesl-lsp/tesl-lsp.rkt`'s ~400-assertion in-module suite was **not gated
anywhere**. It is now in `ci.sh`'s Racket phase.

## Delivery

`dsl/debug/*` and `editor/tesl-lsp/tesl-lsp.rkt` ship via the **nix flake**
(`tesl-lsp` / `tesl-full`), and the DAP launcher resolves `dap-server.rkt` from
the nix profile or `TESL_REPO_ROOT`. The VSCodium extension itself is unchanged,
so **no `.vsix` re-publish is needed** — a `nix profile upgrade` delivers all of
this.

## Files

- new `dsl/debug/value-tree.rkt`
- `dsl/debug/dap-server.rkt`, `dsl/debug/headless-inspect.rkt`,
  `dsl/debug/checkpoint.rkt`, `dsl/types.rkt`
- `compiler/lib/diag_fix.ml`, `compiler/lib/compile.ml`
- `editor/tesl-lsp/tesl-lsp.rkt`
- tests: new `tests/dap-value-tree-tests.rkt`,
  `tests/dap-attach-value-tree-smoke.rkt`,
  `compiler/test/test_fix_titles.ml`; updated `tests/dap-server-test.rkt`,
  `dsl/debug/dap-server.rkt` (in-module), `editor/tesl-lsp/tesl-lsp.rkt`
  (in-module)
- `ci.sh`
