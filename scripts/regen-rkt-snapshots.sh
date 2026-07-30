#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/regen-rkt-snapshots.sh — regenerate every committed .rkt snapshot
# ═══════════════════════════════════════════════════════════════════════════════
#
# The gate diffs `example/learn/*.rkt`, `example/*.rkt` and `tests/*.rkt` against
# a fresh compile, BYTE FOR BYTE.  Any emitter change — and any edit that shifts a
# line number, including adding a comment, because `thsl-src!` bakes line numbers
# into the snapshot — invalidates the affected files.
#
# The regeneration command is one line per file
# (`main.exe <f>.tesl > <f>.rkt`) and was previously only documented in prose, so
# a sweep was retyped from scratch each time
# (roadmap/completed/rkt_snapshot_regen_sweep.md did 98 files that way).  This is
# that sweep, scripted, with the two things the prose version kept getting wrong:
#
#   * an ORPHAN CHECK — the gate fails on a `.rkt` with no `.tesl`, so a rename
#     that leaves a stale snapshot behind must be caught here rather than in CI;
#   * a WRITE-ONLY-ON-SUCCESS rule — a compile failure must NOT truncate the
#     committed snapshot, or one broken file turns into a corrupt diff across the
#     whole corpus and the real error scrolls away.
#
# Usage:
#   scripts/regen-rkt-snapshots.sh              # every snapshot
#   scripts/regen-rkt-snapshots.sh example/learn   # one directory
# Exit: 0 = all regenerated, 1 = at least one file failed to compile
#
# BSD-clean.

set -uo pipefail

REPO_ROOT="${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
export TESL_REPO_ROOT="$REPO_ROOT"
MAIN="$REPO_ROOT/compiler/_build/default/bin/main.exe"

if [ ! -x "$MAIN" ]; then
  echo "building the compiler first..."
  ( cd "$REPO_ROOT/compiler" && dune build bin/main.exe ) || exit 1
fi

# The directories holding committed .rkt snapshots are DISCOVERED, not listed.
#
# A hand-maintained list was wrong three times in one day: it started as
# "example/learn example tests", which silently skipped example/chat and
# example/kanel (`example/*.tesl` does not glob into a subdirectory), and after
# adding those it still skipped tests/bench. Each omission surfaced as exactly one
# confusing gate failure — `ASSERT proof_hot.tesl: exact output mismatch` — long
# after the sweep reported clean.
#
# So: find every directory that contains at least one committed `.rkt` with a
# sibling `.tesl`. That is the definition of "holds a snapshot", it cannot drift,
# and a new example subdirectory is picked up with no edit here.
#
# `tesl/` and `dsl/` are EXCLUDED, and this is the important exclusion.
# `tesl/list.rkt`, `tesl/list-prim.rkt` and `tesl/either.rkt` sit beside
# `tesl/list.tesl` / `tesl/either.tesl`, so the sibling test above matches them —
# but they are HAND-WRITTEN SHIMS that re-export a generated `*-derived.rkt`, NOT
# snapshots. Regenerating them replaces the shim with a compile of the Tesl source
# and the whole stdlib stops loading (`only-in: identifier 'ListPrim.head' not
# included in nested require spec`), which then fails ~48 lesson test blocks with
# an error that names none of this. Done exactly once, on 2026-07-29; restored
# from HEAD. Never blind-regenerate anything under tesl/ or dsl/.
#
# NOT covered here, and deliberately so: the LIFTED stdlib snapshots
# (tesl/list.tesl -> tesl/list-derived.rkt, tesl/either.tesl ->
# tesl/either-derived.rkt). Their generated file has a DIFFERENT BASENAME, so the
# sibling test above cannot see them, and they need a source-path normalisation
# this script does not do. `scripts/gen-stdlib-rkt.sh` owns them and ci.sh checks
# them in its own phase. After any EMITTER change, run BOTH:
#
#     scripts/regen-rkt-snapshots.sh && scripts/gen-stdlib-rkt.sh
#
# (Learned the hard way: the ordered-comparison fix changed the emitted `<`, and
# running only this script left ci.sh phase 4 red.)
#
# An explicit argument still overrides, for a fast single-directory loop.
if [ "$#" -gt 0 ]; then
  DIRS="$*"
else
  DIRS="$(
    find "$REPO_ROOT" -name '*.rkt' \
         -not -path '*/compiled/*' -not -path '*/_build*' \
         -not -path '*/.claude/*' -not -path '*/node_modules/*' \
         -not -path "$REPO_ROOT/tesl/*" -not -path "$REPO_ROOT/dsl/*" 2>/dev/null \
    | while read -r rkt; do
        [ -f "${rkt%.rkt}.tesl" ] && printf '%s\n' "$(dirname "${rkt#$REPO_ROOT/}")"
      done | sort -u | tr '\n' ' '
  )"
fi

changed=0
failed=0
orphans=0

for dir in $DIRS; do
  [ -d "$REPO_ROOT/$dir" ] || continue

  # Orphan check — ONLY in example/learn, which is the one directory the gate
  # holds to a strict 1:1 .tesl/.rkt pairing (ci.sh reports "NO .tesl FOR
  # SNAPSHOT: <name> (orphan .rkt)").  `tests/` legitimately mixes snapshots
  # (jwt-tests.rkt) with HAND-WRITTEN rackunit suites (tesl-test.rkt,
  # web-test.rkt, …), so applying the check there reports 53 false orphans and
  # trains the reader to ignore the warning — which is the same failure mode as
  # a noisy lint.
  if [ "$dir" = "example/learn" ]; then
  for rkt in "$REPO_ROOT/$dir"/*.rkt; do
    [ -f "$rkt" ] || continue
    if [ ! -f "${rkt%.rkt}.tesl" ]; then
      printf '  \033[33m⚠\033[0m  ORPHAN: %s has no .tesl (the gate will fail on this)\n' \
        "${rkt#$REPO_ROOT/}"
      orphans=$((orphans + 1))
    fi
  done
  fi

  for tesl in "$REPO_ROOT/$dir"/*.tesl; do
    [ -f "$tesl" ] || continue
    case "$(basename "$tesl")" in tesl-lsp-*) continue ;; esac   # LSP scratch copies
    rkt="${tesl%.tesl}.rkt"
    # Only files that ALREADY have a committed snapshot are in the gate's diff
    # set; compiling the rest would mint snapshots nobody asked for.
    [ -f "$rkt" ] || continue

    # Invoke with a REPO-RELATIVE path.  The emitter bakes the input path into
    # every `(thsl-src! "PATH" …)` checkpoint, so an absolute invocation commits
    # the regenerating machine's home directory into the snapshot — which is both
    # unreadable in a diff and guaranteed to churn on anyone else's checkout.
    # (The committed corpus proves it: example/learn/*.rkt carried
    # `/home/mikael/...` while example/*.rkt carried `example/...`, so whichever
    # style the script used, it rewrote the other half with pure path noise.)
    #
    # The gate and `dune test` both canonicalise the directory prefix
    # (ci.sh's canon_thsl, test_integration.ml's canonicalize_thsl_paths), so
    # relative is safe as well as correct. scripts/gen-stdlib-rkt.sh already
    # normalises for the same stated reason.
    rel="${tesl#$REPO_ROOT/}"
    tmp="$rkt.regen.$$"
    if ( cd "$REPO_ROOT" && "$MAIN" "$rel" ) > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      # Ratchet: never commit a machine-specific path.
      if grep -q "\"$REPO_ROOT/" "$tmp"; then
        rm -f "$tmp"
        printf '  \033[31m✗\033[0m  ABSOLUTE PATH baked into %s — refusing to write\n' \
          "${rkt#$REPO_ROOT/}"
        failed=$((failed + 1))
        continue
      fi
      if cmp -s "$tmp" "$rkt"; then
        rm -f "$tmp"
      else
        mv "$tmp" "$rkt"
        changed=$((changed + 1))
      fi
    else
      rm -f "$tmp"
      printf '  \033[31m✗\033[0m  FAILED TO COMPILE (snapshot left untouched): %s\n' \
        "${tesl#$REPO_ROOT/}"
      "$MAIN" "$tesl" 2>&1 >/dev/null | head -n 3 | sed 's/^/        /'
      failed=$((failed + 1))
    fi
  done
done

echo ""
echo "regen-rkt-snapshots: $changed snapshot(s) updated, $failed compile failure(s), $orphans orphan(s)"
[ "$failed" -eq 0 ] || exit 1
exit 0
