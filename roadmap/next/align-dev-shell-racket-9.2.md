# Align the dev shell to Racket 9.2 (match nix profile + Docker)

**Status:** proposed (2026-07-03) — flagged by maintainer: "we should only use Racket 9.2".

**Problem.** The distributed/production toolchain is Racket **9.2** (`nix profile install`
ships 9.2; the build image is `racket/racket:9.2-full`, nix/tesl-cli-body.sh:664).
But the dev shell (direnv `use nix` → the flake.lock-pinned nixpkgs) resolves
`pkgs.racket` to **8.18** (`racket --version` → 8.18). shell.nix:4 already documents
this mismatch and the pin was intended to fix it, but the locked nixpkgs rev still
provides 8.18. Consequences:
- The dev shell compiles `.zo` for 8.18; anything expecting 9.2 (or a sibling
  workspace that ran 9.2) hits `version mismatch: expected 8.18 found 9.2` in the
  HttpClient/DAP integration suites — a stale-bytecode symptom, not a code bug.
- Local runtime testing does not exercise the same Racket the product ships on, so
  a 9.2-only runtime behavior could pass here and fail in production.

**Task.** Make `pkgs.racket` in shell.nix + flake.nix resolve to 9.2:
1. Bump the `nixpkgs` node in `flake.lock` to a rev that packages Racket 9.2 (or add
   a small overlay pinning `racket = racket_9_2`). Verify `nix develop`/direnv then
   yields `racket --version` → 9.2.
2. Rebuild the `tesl-racket` collections derivation (flake.nix:72) against 9.2 and
   confirm the pre-compiled `.zo` load cleanly (PLTCOLLECTS ordering note at
   flake.nix:181 already mentions "Racket 9.x").
3. Clear stale caches once (`find dsl tesl lang -type d -name compiled -exec rm -rf {} +`)
   and re-run the full `./ci.sh` under 9.2 (phases 7–11 are the Racket-runtime gate).
4. Update shell.nix:4's comment to reflect the resolved alignment.

**Cross-workspace hygiene.** `dsl/compiled/` (and `dsl/private/compiled/`,
`tesl/compiled/`) are gitignored build caches. Two agent workspaces sharing one
checkout path clobber each other's `.zo`. Consider per-workspace compile roots
(`PLTCOMPILEDROOTS`) or separate checkouts so a 9.2 workspace and an 8.18 workspace
don't corrupt each other's cache during the transition.

**Note.** The compiler is OCaml and Racket-version-independent, so this does not
affect the soundness fixes; it is a toolchain-fidelity + test-reliability item.
