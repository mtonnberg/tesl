# First-touch surface, docs honesty, and tooling drift

## Why (each verified against the live compiler)
- **DOC-TEMPLATES (high):** both `tesl init` scaffolds (`templates/minimal/app.tesl`,
  `templates/api/app.tesl`) fail `--check` (V001: `main` reads env without `envRead`;
  + W050 unused imports). The generated starting point doesn't typecheck.
- **DOC-FAQ (high):** `manual/FAQ.md` teaches non-compiling syntax (`requires [db]`,
  chained `::: A ::: B`, `forall x in xs, p`); `best-practices.md` uses obsolete
  `test "x" = ...`.
- **DOC-COST (med):** best-practices "Proof Cost Model" says proof annotations cost
  "Zero / no allocation"; a proof-annotated param actually retains one `named-value`
  allocation (spec §4.3 fine-print admits it). Correct the summary.
- **DOC-OTLP (low):** spec §5.2 / product-goals say the OTLP exporter is "not yet
  implemented / aspirational" but it IS implemented (`dsl/otel.rkt`). Remove stale text.
- **DOC-SPEC-COMMENTS (low):** §7.13 example uses `--` comments; Tesl uses `#`.
- **TOOL-AGENTCTX (high):** `agent-context` (the documented primary agent loop) drops
  ALL linter warnings; only `--check-json` includes lint. Include lint in agent-context.
- **TOOL-FMT-HINT (med):** fmt-check / V-code hints say run `tesl fmt <file>` — no bare
  `fmt` subcommand exists. Fix the hint (or add the alias).
- **TOOL-DBG-HELP (med):** `debug-inspect` is absent from `tesl --help`. Add it.
- **TOOL-MCP-COORD (med):** MCP README says `type_at` line is 1-based; CLI is 0-based.
- **SEC-SSE-CORS (low):** SSE responses hardcode `Access-Control-Allow-Origin: *` on a
  credentialed stream. Make the origin configurable / not wildcard with credentials.

## Fix
Edit each artifact; then gate the human-facing code so it can't rot again: compile the
`tesl` code blocks in templates, FAQ, best-practices, and the spec in CI (see
verification_methodology).

## Status: DONE — 2026-07-02
Templates compile (2/2); FAQ + best-practices non-compiling syntax fixed; proof
cost claim corrected to match §4.3; stale OTLP "not implemented" text removed; spec
`tesl` blocks use `#`; agent-context includes lint (TOOL-AGENTCTX); debug-inspect in
`--help` (TOOL-DBG-HELP); MCP coord convention corrected. `embedded_docs.ml`
re-synced from the manual.
**Carved:** SEC-SSE-CORS (runtime `ACAO:*` config) and TOOL-FMT-HINT (verify the
Nix-wrapped `tesl fmt` alias) → `roadmap/completed/review_2026_07_deferred.md`.
