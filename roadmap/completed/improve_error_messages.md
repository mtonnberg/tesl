# Improve Error Messages

## Goal

Improve compiler error messages with three tiers of information:
1. **What went wrong** (one-line summary, always shown)
2. **Why it's wrong** (expanded explanation, shown on flag or in LSP hover)
3. **How to fix it** (actionable guidance with code examples)

Also reduce compilation noise — make the Racket compilation step invisible to users.

## Current state (2026-03)

### Implemented ✅

**Proof requirement not met — actionable error + hint (2026-03-17)**
- When a caller passes a value without the required proof, error now includes:
  - Which argument requires which proof (with instantiated subject names)
  - The value's type and which predicate is missing
  - A concrete `check` function suggestion to fix it
  - For cross-param cases: "does not carry a proof satisfying" + hint
  - For untracked subjects: a "bind to a named variable" hint
- 7 new Python tests covering all cases in `TestProofRequirementErrors`
- All 631 Racket tests still pass

**Racket noise suppression (2026-03-17)**
- `tesl run` and `tesl test` now filter `raco setup:/make:/link:` lines from stderr
- Full output still shown when `TESL_VERBOSE=1`
- Implemented in both the `tesl-cli` bin and the shellHook `tesl()` function in `shell.nix`

**Line-accurate compiler errors in the LSP**
- `ParseError` now carries a `line` field (0-indexed source line)
- `_current_source_line` context variable + `source_context(line)` context manager
- `parse_module` stores `source_line` in each form dict (accounting for the `#lang` offset)
- `collect_module_references`, `validate_module_body_semantics`, and `emit_forms` all wrap
  per-form work in `source_context(form["source_line"])` — errors land at the function/record
  declaration line instead of line 0
- `--check-json` emits `exc.line` so the LSP squiggle appears at the right location

**Unknown name → nearest match suggestion**
- `validate_module_references` uses `difflib.get_close_matches` to suggest corrections
- Example: `"missing \`bogusNam\` (did you mean \`bogusName\`?)"`

**Single-line function body → corrected form**
- `parse_function_block` now shows the corrected indented form inline:
  ```
  single-line function bodies are not supported; move the body to the next indented line:
    fn foo(x: Int) -> Int =
    x + 1
  ```

**LSP-side record field access validation**
- `_field_access_diagnostics` in the LSP scans for `var.field` on typed parameters
  and reports unknown fields with accurate line/column numbers
- Complements the compiler (which defers record field errors to runtime via `field-access-ref`)

### Still to do

#### 2. Runtime proof failures
Translate raw GDP fact lists to human-readable messages:
`"expected IsNonZero n, but value 0 does not satisfy this proof — use check Int.nonZero(n) first"`
This is a Racket runtime layer concern (dsl/trusted.rkt, dsl/check.rkt).

#### 4. Statement-level accuracy within function bodies
Currently errors point to the function declaration line. Getting per-statement accuracy
requires threading absolute line numbers through `to_structured_lines` (which currently
drops blank lines, making line mapping lossy). Low priority — the function line is usually
close enough.

#### 5. Show errors as squigglies in the correct spot in vscodium
There is some code for showing build errors but it seem like it does not work as intended

## Scope

The Python compiler already has all the information needed for items 1–2; items 3–4 are
UX / formatting passes.
