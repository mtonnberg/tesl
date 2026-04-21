# Language Distribution Bundle Alternative

## Goal
Assess whether Tesl can ship as a single downloadable artifact for developers
who do not want to install Nix or clone the repository.

## Relationship to the main roadmap
This document is a focused follow-up to `roadmap/next/language_distribution.md`.
It does not replace the main distribution roadmap. Instead, it narrows in on the
"single downloadable artifact" question that sits inside Path B.

The current recommendation from the main roadmap still stands:
1. get Tesl into an installable Nix package first;
2. publish editor tooling once the install story is stable;
3. only then spend time on a standalone bundle.

## Current repo reality
The current repository is not yet set up for a bundle-first release:
- the repo has `shell.nix`, but no `flake.nix` or installable package output;
- the `tesl` command defined in `shell.nix` exports `TESL_REPO_ROOT` and points
  directly at `compiler/_build/default/bin/main.exe` inside a checkout;
- `TESL.md` still documents Docker + generated Racket files as the standard
  deployment path;
- `critical-review-50.md` still lists a standalone binary as roadmap work, not
  as an implemented distribution mode.

That means the immediate blocker is not "which bundler should we pick?". The
real blocker is that Tesl does not yet build as a relocatable installed product.

## Feasibility assessment
A single-file bundle is not a realistic next implementation step in the current
repo state.

Before any AppImage or `nix-bundle` experiment can be meaningful, Tesl needs:
1. a proper package output (`flake.nix` or equivalent Nix packaging entrypoint);
2. an installed `tesl` wrapper that does not assume a live repo checkout or an
   already-built `_build/default/bin/main.exe` path;
3. explicit runtime wiring for the Racket side (wrapper env, collections, and
   any other runtime paths that currently come "for free" from the dev shell);
4. a packaging test that runs the installed CLI outside the repository tree.

Without those prerequisites, a bundle attempt would only prove that the dev
shell can launch the compiler, which is already known.

## Candidate bundle paths once packaging exists
### Path A: AppImage
Use AppImage as the first real "single download" experiment once Tesl has a
package output that can run outside the repo.

Why this is attractive:
- matches the user goal of "download one file and run it";
- keeps the bundle step downstream of normal packaging work;
- is a clearer Linux distribution story than a repo-specific shell wrapper.

What it still depends on:
- a packaged CLI;
- a wrapped Racket runtime layout;
- end-to-end verification that generated Tesl/Racket programs run correctly from
  the packaged environment.

### Path B: `nix-bundle`
Keep `nix-bundle` as a secondary experiment, not the primary plan.

Why it is still interesting:
- it can produce a single executable from a Nix package output;
- it may be useful as a fast experiment once the packaged CLI already works.

Why it is not the first move:
- it still depends on having a proper package output first;
- it does not remove the need to solve Tesl's relocatable Racket runtime story.

## Recommended sequence
1. Implement the main roadmap's packaging prerequisite: add `flake.nix` and a
   real installable Tesl package.
2. Replace the repo-relative shell wrapper with an installed wrapper that sets up
   the runtime explicitly.
3. Verify the installed package outside the repo tree.
4. Attempt an AppImage build from that package output.
5. If AppImage is awkward or too large, evaluate `nix-bundle` as a follow-up
   experiment.

## Status
Deferred for now.

The bundle path is blocked on packaging prerequisites, not on missing research.
Once Tesl has an installable package output, this document should be revisited as
an implementation note for Path B rather than as a speculative design memo.
