# Incremental validation cache

> **Status:** Later · **Effort:** L · **Origin:** split out of `roadmap/next/optimizations.md` (WS7).

## Why later

The other optimization workstreams (measurement, batch mode, parallel CI, parallel build,
startup, mutation speed) are bounded and low-risk. An incremental cache is the opposite: the
speedup is large on warm repeated runs, but it is only as good as its **invalidation key** — get
that wrong and the compiler silently validates stale inputs, which is far worse than being slow.
It needs a sound design before any code, so it is deliberately the last and most cautious bet.

## Goal

Skip parse / typecheck / validation for modules whose inputs are unchanged, so warm repeated runs
of `tesl validate` / `tesl --check-all` only do work for what actually changed.

## Approach (sketch)

- **Content-hash each module** and cache its validation result (diagnostics + derived env) keyed
  by a composite invalidation key.
- **Invalidation key = file content hash + transitive import hashes + compiler version**
  (+ any relevant flags/env). A change to the file, to anything it imports transitively, or to
  the compiler itself must miss the cache.
- **Store** content-addressed under a cache dir; cap size / evict LRU.
- **Soundness first:** ship in a read-only "shadow" mode initially (compute keys, log hit/miss,
  but always re-validate) to prove the key never reports a false hit across the corpus before it
  is trusted to actually skip work.

## Anchors

- `compiler/lib/compile.ml` (the `--check` entry path; composes with the WS4 batch mode).
- `compiler/lib/validation.ml` (the work being cached).

## Open questions

- Minimal sound key: is `file hash + transitive import hashes + compiler version` enough, or must
  CLI flags / env (e.g. the proof-erasure setting) also be in the key?
- Invalidation across stdlib/compiler upgrades — a version string vs a build hash.
- Interaction with `--check-all` batch mode (which already amortizes the shared stdlib env).

## Out of scope

- Cross-process / distributed caching. Single-machine, single-user warm cache only.
