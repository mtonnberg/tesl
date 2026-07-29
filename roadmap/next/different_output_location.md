# Separate output location (`.tesl-stuff/build/`)

## Background

Today the compiled Racket files are siblings to the corresponding Tesl files. That makes a user's project folder noisy: a developer building an app in Tesl never interacts with Racket, yet sees a `.rkt` next to every `.tesl`, plus Racket's `compiled/` bytecode dirs. `tesl init` papers over this with a blunt `*.rkt` + `compiled/` gitignore.

## Goal

Emit compiled `.rkt` files (and their `compiled/` bytecode + `.tesl.srcmap.json` sidecars) into a hidden `.tesl-stuff/build/` folder inside the user's project. `tesl init` gitignores `.tesl-stuff/` by default. It must *always* be safe to delete `.tesl-stuff/` and rerun any command (at the cost of a fresh compile).

## Verdict: worth doing

**Recommended — good change, moderate cost, well contained.**

Upsides beyond tidiness:

* The `tesl init` gitignore becomes precise: one line (`.tesl-stuff/`) instead of `*.rkt` + `compiled/`. `*.rkt` today would also silently ignore any hand-written Racket a user adds; `compiled/` is a generic name that can collide with unrelated tooling.
* "Safe to delete" becomes trivially true and obvious — everything transient lives under one directory.
* `.tesl-stuff/` gives a durable home for future per-project machinery: build cache (the compiler already emits `content_hash` in JSON for exactly this, `compiler/lib/compile.ml:3550-3556`), test-runner artifacts for the VS Code extension, debug-session output, and possibly relocating `.tesl-postgres/` data (optional, see Non-goals).

Why the cost is low: the compiler binary never chooses an output path for normal compilation — `tesl <file>` writes Racket to **stdout** (`compiler/bin/main.ml:1418-1422`). The sibling `.rkt` decision lives entirely in the CLI wrapper `nix/tesl-cli-body.sh`. This repo's own committed `.rkt` regression snapshots are produced/verified via `main.exe` stdout + diff in `ci.sh` (Phase 6, `ci.sh:843-892`) and dune tests, **not** via the wrapper — so they are unaffected and stay committed as siblings.

Main risk (the crux): generated inter-module requires are basename-relative — `(file "Basename.rkt")`, resolved against the requiring module's own directory (`compiler/lib/emit_racket.ml:4462-4489`). The relocation must preserve the relative layout between emitted modules. The mirrored-tree layout below does this with **zero emitter changes** and therefore zero snapshot churn.

## Design decisions

### 1. Layout: mirror the source tree under the build root

`<project-root>/.tesl-stuff/build/<path-of-.tesl-relative-to-root>.rkt`

* Preserves today's relative relationships between modules exactly, so basename requires `(file "X.rkt")` keep resolving. (Local imports are same-directory only by language design — `resolve_local_import_path` probes only the importing file's own directory, `compiler/lib/validation_common.ml:850-854` — so basename requires are always correct; the mirrored layout keeps that invariant.)
* No basename-collision problem (a flattened single build dir would collide on two same-named `.tesl` in different folders).
* Racket drops `.zo` bytecode into `compiled/` next to each `.rkt`, so bytecode automatically lands under `.tesl-stuff/build/.../compiled/` — no extra work.

### 2. Project root discovery

Nearest ancestor of the entry `.tesl` containing `tesl.toml` (templates already ship one); fallback to the entry file's directory. Implemented as a small helper in `nix/tesl-cli-body.sh`. Deps that resolve outside the root should be a hard error with a clear message (local imports can't escape the project).

### 3. Collection requires unaffected

Runtime requires (`tesl/dsl/*`, `tesl/tesl/*`) are collection paths via `PLTCOLLECTS` (`emit_racket.ml:4311-4320`, `flake.nix:195`) — location-independent, nothing to do.

### 4. This repo keeps sibling snapshots

`example/learn/` (73 files), `example/` (107 total), `tests/` (48 generated interleaved with 41 hand-written suites), `tesl/either-derived.rkt` + `tesl/list-derived.rkt` all stay committed where they are. `ci.sh` and `compiler/test/test_integration.ml` continue to derive `${f%.tesl}.rkt` sibling paths for the snapshot diff — unchanged. `scripts/gen-stdlib-rkt.sh` unchanged.

### 5. Escape hatch

Env var `TESL_BUILD_DIR` overrides the build root (absolute or root-relative). No `--sibling` compat mode — old projects just gain a `.tesl-stuff/` dir; their stale sibling `.rkt` are already gitignored by the old scaffold and can be deleted by hand.

## Implementation plan

All in `nix/tesl-cli-body.sh` unless noted. (This file is spliced verbatim into both `flake.nix` and `shell.nix` — edit only the one source.)

### Phase 1 — wrapper output relocation

1. Add `_tesl_project_root <file>` (walk up for `tesl.toml`) and `_tesl_out_path <tesl-file>` (map to `$ROOT/.tesl-stuff/build/<rel>.rkt`, honor `TESL_BUILD_DIR`, `mkdir -p` parent).
2. Replace the four `OUT="${FILE%.tesl}.rkt"` sites with `_tesl_out_path`:
   * `compile)` — `nix/tesl-cli-body.sh:994`
   * `run)` — `:1074`
   * `test)` — `:1142`
   * `watch)` — `:1191`
3. `_tesl_emit_dep_rkts()` (`:95-108`): map each dep from `tesl --deps` through `_tesl_out_path` instead of `DEP_RKT="${DEP%.tesl}.rkt"` (`:100`).
4. `_tesl_freshen_bytecode` (`:67-88`) takes the `.rkt` path and derives its `compiled/` dir — works unchanged once callers pass the new paths. Verify the `.tesl-buildid-*` marker and mtime-preservation logic (`:1083-1087`) still hold.
5. `compile)` verb: print the output path it wrote (it's no longer next to the source, so say where).

### Phase 2 — `tesl init` + new `clean` verb

6. `_tesl_init` gitignore (`:679-689`): replace `compiled/` + `*.rkt` lines with `.tesl-stuff/`. Keep `.tesl-postgres/`, `.env`, `result`.
7. Add `tesl clean`: `rm -rf "$ROOT/.tesl-stuff/build"` (leave room for other `.tesl-stuff/` subdirs to survive, e.g. future cache with its own policy). Register in dispatch + help (`:1306-1345`).

### Phase 3 — secondary emitters (small, independent)

8. `tesl --exe` (`compiler/lib/compile.ml:4164-4171`) writes a sibling `.rkt` next to the source before building the executable. Either leave as-is (documented internal step) or route through a temp dir like `debug_inspect` already does (`compile.ml:4265-4275`). Recommendation: temp dir, then no stray file. Note the comment at `compile.ml:4140-4148` about relative requires — flatten like `debug_inspect` does.
9. `tesl-sourcemap` (`compiler/bin/tesl_sourcemap.ml:42-46`) defaults to sibling `.rkt`/`.tesl.map`; it already has `--rkt-out`/`--map-out`. Update its default to the `.tesl-stuff/build/` path only if it's invoked on user projects by tooling; otherwise leave and document.
10. DAP debug (`dsl/debug/dap-server.rkt:287-329`) and `debug-inspect` already use temp dirs — no change.

### Phase 4 — tests + CI

11. `ci.sh` Phase 9b CLI smoke (`:1026-1070`) exercises the wrapper in a temp multi-module project: update assertions to expect `.tesl-stuff/build/` output, fix the stale "`*.rkt` gitignored" comments (`:1028`; also `nix/tesl-cli-body.sh:92-93`), and add: delete `.tesl-stuff/`, rerun `tesl test`, must pass (the "always safe to delete" guarantee).
12. Add a smoke case for a multi-module project with a subdirectory module to lock the mirrored-tree layout.
13. Full gate: `./compile-examples.sh` must stay green with zero snapshot diffs (proves the emitter was untouched).

### Phase 5 — docs

14. `manual/GETTING-STARTED.md:31,34` — gitignore advice + "next to it" wording.
15. `manual/tour.md:929`, `manual/examples.md:145`, `manual/deploy.md:75` — output-location wording.
16. `LANGUAGE-SPEC.md:3989` (srcmap sidecar "alongside the compiled `.rkt`" — still true, but the pair now lives in `.tesl-stuff/build/`), `:4057` (`racket your-compiled-app.rkt` example path).
17. Note: docs are anchor-guarded — never move an anchor-backed heading without migrating the anchor.

## Acceptance criteria

* `tesl run/test/compile/watch` on a fresh `tesl init` project leave **no** generated files outside `.tesl-stuff/`.
* Multi-module project (incl. a subdirectory module) runs and tests green from the new layout.
* `rm -rf .tesl-stuff && tesl test` succeeds (slower, no errors).
* `tesl init` project's `git status` stays clean after `tesl run`.
* `./compile-examples.sh` green, zero committed-snapshot diffs.
* Docker `tesl build` unaffected (already stages into its own `$CTX`, `nix/tesl-cli-body.sh:764-778`).

## Non-goals / explicitly out of scope

* Adding cross-directory imports to the language. Imports are same-directory only today (`validation_common.ml:850-854`), which is exactly why basename requires (`emit_racket.ml:4487-4489`) are sound. If subfolder imports are ever added, the emitter must emit relative require paths — separate feature, but the mirrored build tree already accommodates it.
* Moving this repo's committed `.rkt` regression snapshots — they are load-bearing for ci.sh Phase 6, `compiler/test/test_integration.ml`, and `test_racket_discover.ml`.
* Relocating `.tesl-postgres/` into `.tesl-stuff/` — possible future consolidation, but it holds data that is *not* safe to delete, which conflicts with the directory's core guarantee. If ever moved, put it under `.tesl-stuff/state/` and scope `tesl clean` to `build/` only (already the plan above).
* On-disk build cache keyed by `content_hash` — natural follow-up living in `.tesl-stuff/cache/`, separate roadmap item.
