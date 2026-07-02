# D9 + D12 — machine-applicable fixes & proof-free bindings-hash (deferred from B5)

**Status:** DEFERRED to `later` 2026-07-02 (`stability_wave`). The high-value, low-risk parts of
`docs_and_small_features_backlog` (D6 dead-keyword removal, D8 idiom-transfer diagnostics) landed;
D11 was discarded. D9 and D12 are lower-value and each needs more than a message tweak, so they are
deferred rather than rushed at the end of a soundness-focused wave.

## D9 — structured machine-applicable fixes beyond Boolean→Bool
Only the `Boolean→Bool` migration emits a structured `Replace_line` `diagnostic_fix`
(`compile.ml`); ~170 diagnostics carry `fix = None`. Extend structured fixes to the highest-
frequency AI-hit diagnostics — the new D8 hints are the obvious first targets: `+`→`++` (replace the
operator), `return x` removal, single-line-`if` → indented form.
**Why deferred:** the checker's `add_error` is message-only; `diagnostic_fix` lives in the
`compile.ml` diagnostic layer. Emitting a structured fix from a checker/parser diagnostic requires
threading a `fix` field through the checker's error representation into the compile diagnostics — a
plumbing change across `checker.ml`/`compile.ml`, not a local edit. The prose hints (D8) already
give humans/AI the guidance; the machine-applicable *auto-fix* is the incremental win.
