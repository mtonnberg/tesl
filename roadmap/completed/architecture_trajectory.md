# Architecture & trajectory — correct claims now, carve the big work to later

## Why
- **ARCH-SEAM (high):** spec §150 says the Racket runtime is "an implementation detail
  … perhaps Rust or Zig later." No backend seam exists: `emit_racket.ml` writes ~321
  raw Racket forms; three emitters re-derive lowering from the surface AST; the
  enabling item is in `roadmap/discarded`. Claim is false today.
- **ARCH-CAP-NARROW (med):** runtime capability grant is the whole-app union, not
  per-handler (narrowing attempted + reverted). Per-handler least privilege is an
  illusion at runtime.
- **ARCH-ADOPTION (high):** stated goal is mainstream adoption, but package manager,
  library support, playground, homepage, and non-Nix distribution are all discarded.
- **SEC-TELEMETRY (med):** telemetry OTLP egress grants `httpClient` ambiently — an
  unaccounted network side channel.

## Fix
- Now: correct the false/aspirational claims in `LANGUAGE-SPEC.md` (mark the
  backend-swap as a non-goal-for-now / aspirational, and stop calling `ir.ml` a
  lowering IR — it's a JSON tooling export).
- Later (`roadmap/later/`): a real lowering IR seam (`lowering_ir_seam.md`);
  per-handler capability narrowing design (`per_handler_capability_narrowing.md`); a
  telemetry egress opt-out/allowlist (`telemetry_egress_control.md`); an adoption-path
  decision (`adoption_path.md` — non-Nix install / playground / minimal package story).

## Status: PARTIAL — 2026-07-02
DONE (honest-claims edits): the stale OTLP "not implemented" text was corrected
(DOC-OTLP, docs pass). CARVED → `roadmap/completed/review_2026_07_deferred.md` §10: the
`ir.ml`/backend-swap claim correction in the spec, the lowering-IR seam
(ARCH-SEAM), per-handler capability narrowing (ARCH-CAP-NARROW), adoption path
(ARCH-ADOPTION), telemetry egress control (SEC-TELEMETRY). These are architectural
/ strategic and each needs its own dedicated pass.
