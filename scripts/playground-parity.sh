#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/playground-parity.sh — the browser checker must agree with the CLI
# ═══════════════════════════════════════════════════════════════════════════════
#
# THE DEFECT THIS EXISTS TO KILL.  playground/ ships the compiler compiled to
# JavaScript (js_of_ocaml).  It reuses the SAME Compile.check_source +
# Linter.lint_file pair and the SAME Compile.diag_to_json serializer as
# `tesl --check-json`, so its diagnostics are supposed to be byte-identical to
# the CLI's — and the whole value of the page rests on that.  The failure mode is
# not "the build broke" (loud); it is the browser build silently DIVERGING, which
# is exactly how the linter was once found to be contributing nothing in the
# browser (Sys_js.create_file raising under Node, swallowed by Linter.lint_file).
# "It builds" would not have caught that.  This does.
#
# WHAT IS COMPARED, per diagnostic, in order:
#     code · severity · source · start.line · start.col · message · fix
# `file` is deliberately excluded: the CLI reports the real path and the browser
# reports the virtual /tesl/<Module>.tesl it derives from the module header.
#
# THE KNOWN, NAMED EXCEPTION.  The playground checks ONE buffer, so a lesson that
# imports a sibling *local* module cannot resolve it and fails loudly.  That is
# correct behaviour, not tolerance to be fuzzed over, so it is named here and
# asserted to STILL differ:
KNOWN_DIFF="lesson07-consumer.tesl"
# If that file ever agrees with the CLI, this script FAILS on purpose — the
# single-buffer limit would have changed and three documents say it has not
# (playground/README.md, gen-lessons-page.py's cross_module flag, and the note
# rendered on lessons.html).
#
# Usage:
#   scripts/playground-parity.sh                 # build if needed, compare 30 files
#   scripts/playground-parity.sh --dist DIR      # reuse an already-built dist
#   scripts/playground-parity.sh --limit N       # compare the first N lessons
#   scripts/playground-parity.sh --verbose       # print every file, not just diffs
#
# Exit: 0 = parity holds, 1 = divergence, 77 = nothing to do (no node, no
# js_of_ocaml, no corpus, no compiler) — a missing optional tool is a SKIP, never
# a gate failure.
#
# BSD-clean: no GNU-only sed/grep/awk flags, no `readlink -f`, no `sed -i`.

set -uo pipefail

REPO_ROOT="${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
LEARN_DIR="$REPO_ROOT/example/learn"
LIMIT=30
DIST=""
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dist)    DIST="${2:-}"; shift 2 ;;
    --limit)   LIMIT="${2:-30}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "playground-parity: unknown argument: $1" >&2; exit 1 ;;
  esac
done

say()  { echo "playground-parity: $*"; }
skip() { say "$*  — nothing to do"; exit 77; }

[ -d "$LEARN_DIR" ] || skip "no example/learn"
command -v node >/dev/null 2>&1 || skip "node is not on PATH"

# ── The CLI side ─────────────────────────────────────────────────────────────
MAIN_EXE="${TESL_OCAML_COMPILER:-$REPO_ROOT/compiler/_build/default/bin/main.exe}"
[ -x "$MAIN_EXE" ] || skip "no compiler at $MAIN_EXE (run: cd compiler && dune build)"

# ── The browser side ─────────────────────────────────────────────────────────
# An existing dist is reused as-is; otherwise build one, which needs js_of_ocaml.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tesl-parity.XXXXXX")" || exit 1
BUILT=""
cleanup() { rm -rf "$TMP" "$BUILT"; }
trap cleanup EXIT INT TERM

if [ -n "$DIST" ]; then
  ART="$DIST/tesl_playground.js"
  [ -f "$ART" ] || { say "no artifact at $ART" >&2; exit 1; }
else
  command -v js_of_ocaml >/dev/null 2>&1 || skip "js_of_ocaml is not on PATH"
  BUILT="$(mktemp -d "${TMPDIR:-/tmp}/tesl-parity-dist.XXXXXX")" || exit 1
  say "building the playground into $BUILT"
  if ! "$REPO_ROOT/playground/build.sh" "$BUILT" >"$TMP/build.log" 2>&1; then
    say "playground/build.sh FAILED:" >&2
    sed 's/^/    /' "$TMP/build.log" >&2
    exit 1
  fi
  ART="$BUILT/tesl_playground.js"
fi

# ── The fixture set: the first N lessons in directory order ──────────────────
FILES="$(ls "$LEARN_DIR"/*.tesl 2>/dev/null | head -n "$LIMIT")"
[ -n "$FILES" ] || skip "no lessons under $LEARN_DIR"

n=0
for f in $FILES; do
  n=$((n + 1))
  base="$(basename "$f")"
  # The CLI's own JSON, straight to disk. A non-zero exit is normal here: files
  # with errors exit 1 while still printing the document.
  TESL_REPO_ROOT="$REPO_ROOT" "$MAIN_EXE" --check-json "$f" >"$TMP/$base.cli.json" 2>"$TMP/$base.cli.err"
  if [ ! -s "$TMP/$base.cli.json" ]; then
    say "FAIL: $base — \`--check-json\` printed nothing" >&2
    sed 's/^/    /' "$TMP/$base.cli.err" >&2
    exit 1
  fi
  echo "$f" >>"$TMP/files.txt"
done
say "comparing $n lesson(s) — CLI \`--check-json\` vs the browser's teslCheck"

# ── The comparison, in one node process ──────────────────────────────────────
# One process, not one per file: evaluating the 1.1 MB artifact costs ~70 ms and
# there is no reason to pay it 30 times.  `globalThis.window = globalThis` is
# what the browser driver's export expects (it sets window.teslCheck).
NODE_TMP="$TMP" NODE_ART="$ART" NODE_VERBOSE="$VERBOSE" NODE_KNOWN="$KNOWN_DIFF" \
node - <<'NODE'
const fs = require("fs"), path = require("path");
globalThis.window = globalThis;
require(path.resolve(process.env.NODE_ART));
if (typeof teslCheck !== "function") {
  console.error("playground-parity: FAIL: the artifact does not export teslCheck");
  process.exit(1);
}
const tmp = process.env.NODE_TMP;
const verbose = process.env.NODE_VERBOSE === "1";
const known = process.env.NODE_KNOWN;
const files = fs.readFileSync(path.join(tmp, "files.txt"), "utf8").trim().split("\n");

// The seven fields the verification bar names, and nothing else. `file` is
// excluded on purpose (real path vs the driver's virtual /tesl/<Module>.tesl).
const norm = d => ({
  code: d.code, severity: d.severity, source: d.source,
  line: d.start.line, col: d.start.col, message: d.message,
  fix: d.fix === null || d.fix === undefined ? null : d.fix
});
const key = ds => JSON.stringify(ds.map(norm));

let same = 0, exempt = 0, bad = 0, diagCount = 0;
for (const f of files) {
  const base = path.basename(f);
  const cli = JSON.parse(fs.readFileSync(path.join(tmp, base + ".cli.json"), "utf8"));
  let web;
  try { web = JSON.parse(teslCheck(fs.readFileSync(f, "utf8"))); }
  catch (e) {
    console.error(`  ✗ ${base}: teslCheck threw ${e}`);
    bad++; continue;
  }
  const a = key(cli.diagnostics || []), b = key(web.diagnostics || []);
  diagCount += (cli.diagnostics || []).length;
  if (base === known) {
    if (a === b) {
      console.error(`  ✗ ${base}: the KNOWN exception no longer differs.`);
      console.error(`    The one-buffer limit apparently changed. Update KNOWN_DIFF in`);
      console.error(`    scripts/playground-parity.sh, playground/README.md and the`);
      console.error(`    cross_module note in playground/gen-lessons-page.py.`);
      bad++;
    } else {
      // "Fails loudly" is the whole justification for the exemption, so assert
      // it: somewhere in the browser's output the unresolvable local module must
      // be named. Anything vaguer would let a silent misbehaviour hide in here.
      const loud = (web.diagnostics || [])
        .some(d => /module `[A-Za-z0-9_.]+` not found/.test(d.message || ""));
      if (!loud) {
        console.error(`  ✗ ${base}: differs from the CLI but never says the local module is missing.`);
        console.error(`    web: ${b}`);
        bad++;
      } else {
        exempt++;
        console.log(`  · ${base}: known exception — one buffer, so the local import fails loudly`);
      }
    }
    continue;
  }
  if (a === b) {
    same++;
    if (verbose) console.log(`  ✓ ${base} (${(cli.diagnostics || []).length} diagnostics)`);
  } else {
    bad++;
    console.error(`  ✗ ${base}: DIVERGED`);
    console.error(`    cli: ${a}`);
    console.error(`    web: ${b}`);
  }
}
console.log(`playground-parity: ${same}/${files.length} byte-identical, ` +
            `${exempt} known exception(s), ${bad} divergence(s); ` +
            `${diagCount} CLI diagnostics compared`);
process.exit(bad === 0 ? 0 : 1);
NODE
rc=$?
if [ "$rc" -eq 0 ]; then
  say "OK — the browser checker and the CLI agree"
else
  say "FAILED — the browser checker has diverged from the CLI" >&2
fi
exit "$rc"
