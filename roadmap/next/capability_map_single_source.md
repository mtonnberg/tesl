# Single-source the effect→capability map; charge agent-block caps; UUID codegen (review §5.4)

**Status:** DEFERRED to `later` (2026-07-02, `stability_wave`). These are static-COMPLETENESS
holes with a runtime union backstop (NOT silent fail-opens), and the principled fix is a
single-source registry *refactor* (architecture, not a bug fix). Given the wave's "close the
silent-forgery holes" priority, the fail-open CRITICAL/HIGH items (guard escape §5.2, agent-config
leak §6.2) were fixed; this backstopped completeness work is deferred rather than rushed.

**Effort:** M.
These are static-COMPLETENESS holes (the whole-app capability *union* still catches them at
runtime — not fail-opens), which is why they're separated from the fixed §5.2/§6.2 CRITICAL/HIGH.

## A2-3 — `var_caps` is hand-keyed and has drifted from `type_system`
`var_caps` (`validation_capabilities.ml:96`) maps a referenced stdlib name → the capability it
introduces, by a hand-written list. It has drifted from `type_system`'s exports:
- `UUID.v4` / `UUID.v7` have no entry (compile clean with `requires []` though runtime-gated).
- the list carries dotted `Time.durationMs`/`Time.diffMs`/… while `type_system` exports the BARE
  `durationMs`/`diffMs`/… — the dotted forms are phantom and the bare forms are unmapped. (Note:
  the bare Time ops are pure Posix arithmetic and likely need NO capability — resolve authoritatively
  from the registry rather than guessing, to avoid over-rejecting pure code.)

**Fix:** annotate each capability-bearing stdlib fn with its capability at its single definition in
`type_system.ml` (alongside `stdlib_home_module_of`), and DERIVE `var_caps` from that registry, so
the effect→capability decision has one source (dedup-by-construction, generator G1). Add a
conformance test (like `test_agent_prim_registry`) pinning the derived map.

## A2-4 — declarative `agent = Agent {…}` `requires` not checked against tools' caps
A `DAgent` block's `requires` row is never verified against the capabilities its `tools` require
(`DAgent` is not a `DFunc`), so an agent declaring `[aiProvider]` can host a tool requiring
`[dbWrite]`. `ast.ml:395` documents `agent.capabilities` as "bounds the tools' authority" — an
unimplemented intent. The SAME `Agent {…}` built inside a function body IS charged. Charge the
declarative block's tools against its declared row.

## A2-7 — `UUID.v4`/`v7` codegen arity
`UUID.v4`/`v7` emit an argument to a nullary Racket function (arity mismatch); the path is exercised
nowhere in the corpus. Fix the emission and add a corpus example that exercises it.

## Refs
- Review `TESL-REVIEW-TECHNICAL.md` §5.4 (`A2-3`, `A2-4`, `A2-7`).
- Source: `validation_capabilities.ml` `var_caps`; `type_system.ml` stdlib registry;
  `checker.ml` agent capability handling; `emit_racket.ml` UUID emission.
