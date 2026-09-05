# Verified content exports for adoption

Status: first implementation slice, awaiting integration and publication use.

The main repository now owns the [content catalog and export contract](../../content/README.md),
one validation-proof example, its negative transformation and exact test expectations.
`scripts/content.py` builds and verifies the source/compiler pair and exports a
versioned JSON evidence bundle. The root gate verifies content; CI creates a
downloadable bundle after a successful gate. Consumers do not affect compiler builds.

The adoption repository owns editorial briefs, prose generation, critique,
rendering and later publication. No language claims or runnable tutorial code are
maintained there independently: consumers use a digest-locked official export.

Remaining before the broader foundation is complete:

- Expand selected reference queries into a compiler-owned bulk catalog for search.
- Correct the runtime/backend contradictions documented in the adoption audit.
- Add stable example/compiler permalinks and browser artifacts when the playground
  search and site contracts are implemented.
- Exercise a clean committed CI export and document artifact promotion/retirement.

Standalone installation and Windows support are separate workstreams. Hoogle-like
playground search and a time-boxed Elm feasibility check follow this foundation;
this change makes no frontend rewrite decision.
