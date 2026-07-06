# Fail-closed: `collect_import_parse_errors` — audited, NO ACTION

Sibling of [[fail_closed_checker_hardening]] (umbrella). Recorded for a complete
audit trail; no work item.

## Verdict (2026-07-06)

`collect_import_parse_errors` (`compiler/lib/proof_checker.ml:1106`) is
**fail-closed** for its concern: the parse-result match is total —
`| Ok _ -> None | Err e -> Some ...` (`:1118`).

Two silent skips exist but are **out of this pass's scope**, not fail-open holes:
- `is_tesl_module ... -> None` (`:1111`) — non-module imports are not parsed here.
- `if not (Sys.file_exists path) then None` (`:1114`) — a local import pointing at a
  missing file yields no error *here*; missing-import is reported by import
  resolution, not this pass.

## Action

None on this function. **One-line follow-up worth confirming** (not urgent):
verify the missing-file case (`:1114`) is in fact rejected by the import-resolution
pass, so the silent `None` here is genuinely backstopped and not a two-pass gap. If
it is not, that is a separate import-resolution bug, not a `proof_checker` fail-open.

> **Follow-up CONFIRMED 2026-07-06.** `import NoSuchLocalModule exposing [...]`
> against a nonexistent file is rejected by import resolution with
> `error[V001]: module `NoSuchLocalModule` not found: looked for <path>` (exit 1,
> fresh binary). The silent `None` at `:1114` is genuinely backstopped. CLOSED.
