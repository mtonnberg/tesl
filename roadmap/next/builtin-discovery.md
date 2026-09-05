# Builtin discovery and playground adoption

Status: first implementation available locally; follow-up work remains below.
Location: compiler, CLI/MCP, playground. Adoption strategy and editorial content
remain in the separate `tesl-adoption` repository.

The compiler owns one bounded search implementation, shared by native and browser
builds. Developers can find `String.length` from `String -> Int`, copy its import,
and open the maintained validation-title example without losing their current
program. Known capabilities and unavailable proof metadata remain explicit.

Implemented: text/name/module/family lookup; exact structural type shapes and
generic renaming; versioned catalog; CLI and Go MCP commands; lazy accessible
search dialog; checked example links; content identities/integrity checks; shared
source-link codec; relevance/negative/parity/browser tests. See
[`playground/SEARCH.md`](../../playground/SEARCH.md) for the API and constraints.

The production [Elm application and optional Monaco editor](../../playground/ARCHITECTURE.md)
now preserve the native editor's adoption flows and offer compiler squiggles,
quick fixes and catalog suggestions in IDE mode. Type search also accepts
unfinished suffixes (`Float ->`, `Float -> F`) with explicit completion labels.
Ordinary compiler builds do not require Elm or npm.

Remaining before calling the broader discovery initiative complete:

- Confirm real mobile IME and screen-reader behavior; measure representative
  device/network performance rather than extrapolating from desktop loopback.
- Retain versioned checker deployments before offering compiler-pinned links.
- Expand verified examples beyond the initial three and improve ranking from
  observed failed queries collected only with an explicit privacy design.
- Export structured proofs/callback capabilities before adding requirement
  filters or extending shape matching to prose-only special forms.
- Audit unquantified variables in builtin schemes (`Dict.map` uses `_k` but
  quantifies `_r3_abc`). Search labels these `incomplete-scheme` and excludes them
  from structural matching until the compiler metadata is corrected and tested.
- Keep project/current-buffer symbol indexing a separate scoped design.

The main `./ci.sh` remains the authoritative repository gate. The publishing
workflow additionally runs full native/browser parity and real Chromium checks;
no publishing action has been performed as part of this local implementation.


The welcoming workbench starts with working code and offers **Build with Tesl**,
sharing and source download. Production browser tests cover those paths. A local
content-free observation hook distinguishes install intent and explicit sharing;
actual installation/first-project confirmation and aggregate collection remain
an integration task with the installation workstream.
