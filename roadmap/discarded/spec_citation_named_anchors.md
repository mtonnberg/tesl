# D11 — migrate spec `§`-citations to named anchors — DISCARDED

**Disposition:** discarded 2026-07-02 (`stability_wave`), by explicit user decision.

## What it was
Rewrite the ~72 raw `§<n>` LANGUAGE-SPEC citations in `compiler/lib` + `compiler/test` to
named-anchor references (a full migration, effort L), after settling a canonical citation
format (`§7.4` vs slug anchor vs stable ref key — a lock-in decision).

## Why discarded (not merely deferred)
Drift is **already guarded**: `test_spec_anchors.ml` fails the build if any cited `§<n>` does not
resolve to a real spec heading, and the anchor contract (`manual/anchors.md`) already landed. The
only additional benefit of a full named-anchor migration is robustness to section *renumbering* —
a marginal win against an L-effort, ~72-site doc churn that does **not** shrink the language surface
area (the wave's actual goal). This is pure documentation churn with no soundness or
surface-reduction payoff, so per the "stability / smaller surface / not features" objective it was
discarded rather than done or deferred.

If a renumbering pain ever materializes, the pre-req is still a citation-FORMAT lock-in decision;
revive from here.
