#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  tests/doc-integrity.sh — the documentation must not lie about itself:
#  every relative link resolves, every cited #anchor is a real heading, the
#  manual section map round-trips against the compiler, no document is an
#  orphan, and no corpus size is hand-typed.
# ═══════════════════════════════════════════════════════════════════════════════
#
# `roadmap/next/revised_onboarding.md` reshuffles the docs spine, and NOTHING in
# the repo currently catches a broken link.  The concrete drifts this locks out
# (all measured 2026-07-29, all real at the time this script was written):
#
#   1. DEAD LINKS / DEAD ANCHORS.  manual/MANUAL.md alone carries ~30 relative
#      links, manual/examples.md ~90, example/intro/README.md 13 — none verified
#      by anything.  A `git mv` of one manual page silently breaks all of them.
#   2. SECTION-MAP DRIFT.  The section→file map is duplicated in SIX places:
#      compiler/bin/main.ml (`section_to_embedded_key`, `get_disk_path`,
#      `doc_pairs`, and the "Available sections:" error string),
#      manual/MANUAL.md's "Manual sections" table, and manual/anchors.md's
#      prose.  They disagreed: the CLI's own error string advertised
#      `ai-testing` and `intro`, which MANUAL.md's table did not list.  Both
#      directions are asserted here, so the next divergence fails the gate.
#   3. ORPHAN DOCUMENTS.  A `manual/*.md` nobody links to is unreachable for a
#      human even though `tesl help manual full` still prints it.
#   4. HAND-TYPED CORPUS COUNTS.  "50+ structured lessons" (MANUAL.md),
#      "70+ lessons" (tour.md), "73 `.tesl` lessons" (examples.md) and
#      "657+ Racket tests" (dev-docs, twice) — four different numbers for two
#      corpora, every one of them already wrong.  Counts must be generated or
#      not stated; they must never be typed.
#   5. THE PRODUCING SIDE OF THE ANCHOR CONTRACT.  compiler/lib/error_codes.ml
#      ships `manual = Some "<section>#<anchor>"` deep-links that a
#      markdown-only edit can break.  compiler/test/test_error_codes.ml covers
#      that for the compiler's own build; doing it here too means a docs author
#      running ONLY this script (2 seconds) gets the answer, instead of finding
#      out from the six-minute gate.
#
# The slug rule is the one documented in manual/anchors.md and implemented by
# Error_codes.slug_of_heading: lower-case, drop every character that is not
# [a-z0-9 -], collapse runs of spaces to a single '-', trim.  Both readings of
# how '-' interacts with spaces are accepted (the OCaml rule folds '-' to a
# separator, GitHub keeps it), so a heading is never reported dead over that
# one ambiguity.
#
# Fenced code blocks are skipped for BOTH links and headings: a `#` inside a
# ```tesl fence is a Tesl comment, not a heading, and a `[x](y)` inside a fence
# is illustrative markdown, not a live link.
#
# Usage:  tests/doc-integrity.sh
# Exit:   0 = pass, 1 = failure, 77 = skipped (compiler not built)
# Env:    TESL_REPO_ROOT, TESL_OCAML_COMPILER (both auto-detected)

set -uo pipefail

REPO_ROOT="${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
MAIN_EXE="${TESL_OCAML_COMPILER:-$REPO_ROOT/compiler/_build/default/bin/main.exe}"

FAIL=0
pass() { printf '  \033[32m✓\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m  %s\n' "$1"; FAIL=1; }
note() { printf '  \033[33m⚠\033[0m  %s\n' "$1"; }

[ -d "$REPO_ROOT/manual" ] || { echo "doc-integrity: missing $REPO_ROOT/manual" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tesl-doc-integrity.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/slugs"

cd "$REPO_ROOT" || exit 1

# ─────────────────────────────────────────────────────────────────────────────
#  The document set: tracked *.md at the repo root and in the doc folders.
#  (roadmap/ is deliberately excluded — it is a planning scratchpad whose links
#  point at files that do not exist yet by design.)
# ─────────────────────────────────────────────────────────────────────────────
DOCS="$WORK/docs.txt"
git ls-files -- '*.md' 2>/dev/null \
  | grep -E '^([^/]+\.md|manual/[^/]+\.md|manual/intro/[^/]+\.md|dev-docs/[^/]+\.md|example/[^/]+\.md|example/learn/[^/]+\.md|example/intro/[^/]+\.md)$' \
  > "$DOCS"

if [ ! -s "$DOCS" ]; then
  echo "doc-integrity: no tracked markdown found (is this a git checkout?)" >&2
  exit 1
fi

DOC_COUNT="$(grep -c . "$DOCS")"
echo "── scanning $DOC_COUNT tracked markdown documents"

# The doc list is passed to awk/grep unquoted, so a path with whitespace would
# silently split.  Refuse instead of half-scanning.
if grep -qE '[[:space:]]' "$DOCS"; then
  echo "doc-integrity: a tracked markdown path contains whitespace — rename it" >&2
  grep -nE '[[:space:]]' "$DOCS" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Extractors (awk only — POSIX features, no gawk extensions, no grep -P)
# ─────────────────────────────────────────────────────────────────────────────

# links.awk — emit "<file>\t<line>\t<target>" for every inline markdown link
# outside a fenced code block and outside an inline-code span.
cat > "$WORK/links.awk" <<'AWK'
FNR == 1 { fence = 0 }
{
  probe = $0
  sub(/^[[:blank:]]+/, "", probe)
  if (probe ~ /^```/ || probe ~ /^~~~/) { fence = 1 - fence; next }
  if (fence) next

  line = $0
  gsub(/`[^`]*`/, " ", line)          # inline code spans are not links

  while (match(line, /\[[^][]*\]\([^()]*\)/)) {
    tok  = substr(line, RSTART, RLENGTH)
    line = substr(line, RSTART + RLENGTH)
    p = index(tok, "](")
    target = substr(tok, p + 2, length(tok) - p - 2)
    sub(/^[[:blank:]]*</, "", target)                 # <auto-style> target
    sub(/>[[:blank:]]*$/, "", target)
    sub(/[[:blank:]]+["'"'"'(].*$/, "", target)       # strip a trailing "title"
    sub(/^[[:blank:]]+/, "", target); sub(/[[:blank:]]+$/, "", target)
    if (target != "") print FILENAME "\t" FNR "\t" target
  }
}
AWK

# slugs.awk — emit every ATX heading's slug, both readings of the '-' rule.
cat > "$WORK/slugs.awk" <<'AWK'
function keep(c) { return index("abcdefghijklmnopqrstuvwxyz0123456789", c) }
# fold: '-' is a word separator (the Error_codes.slug_of_heading rule)
function slug_fold(t,   i, c, out) {
  t = tolower(t); out = ""
  for (i = 1; i <= length(t); i++) {
    c = substr(t, i, 1)
    if (keep(c)) out = out c
    else if (c == " " || c == "-" || c == "\t") out = out " "
  }
  gsub(/  +/, " ", out); sub(/^ +/, "", out); sub(/ +$/, "", out)
  gsub(/ /, "-", out)
  return out
}
# keep: '-' is retained verbatim (the GitHub reading of the same rule)
function slug_keep(t,   i, c, out) {
  t = tolower(t); out = ""
  for (i = 1; i <= length(t); i++) {
    c = substr(t, i, 1)
    if (keep(c) || c == "-") out = out c
    else if (c == " " || c == "\t") out = out " "
  }
  gsub(/  +/, " ", out); sub(/^ +/, "", out); sub(/ +$/, "", out)
  gsub(/ /, "-", out)
  sub(/^-+/, "", out); sub(/-+$/, "", out)
  return out
}
FNR == 1 { fence = 0 }
{
  probe = $0
  sub(/^[[:blank:]]+/, "", probe)
  if (probe ~ /^```/ || probe ~ /^~~~/) { fence = 1 - fence; next }
  if (fence) next
  if (probe !~ /^#+[[:blank:]]/) next
  text = probe
  sub(/^#+[[:blank:]]+/, "", text)
  sub(/[[:blank:]]+#+[[:blank:]]*$/, "", text)           # closed ATX form
  sub(/[[:blank:]]+$/, "", text)
  if (text == "") next
  a = slug_fold(text); b = slug_keep(text)
  if (a != "") print a
  if (b != "" && b != a) print b
}
AWK

# Cache a file's heading slugs; echo the cache path.  Empty cache file for a
# target that is not markdown or does not exist.
slug_cache() {
  local path="$1" key
  key="$(printf '%s' "$path" | tr -c 'A-Za-z0-9' '_')"
  local cache="$WORK/slugs/$key"
  if [ ! -f "$cache" ]; then
    if [ -f "$path" ]; then
      awk -f "$WORK/slugs.awk" "$path" > "$cache" 2>/dev/null || : > "$cache"
    else
      : > "$cache"
    fi
  fi
  printf '%s' "$cache"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Part 1 + 2 — every relative link resolves, every cited #anchor is a heading
# ─────────────────────────────────────────────────────────────────────────────
echo "── links: every relative markdown link resolves to a file that exists"

LINKS="$WORK/links.txt"
# shellcheck disable=SC2046
awk -f "$WORK/links.awk" $(cat "$DOCS") > "$LINKS"

DEAD_LINKS="$WORK/dead-links.txt"
DEAD_ANCHORS="$WORK/dead-anchors.txt"
: > "$DEAD_LINKS"
: > "$DEAD_ANCHORS"
n_rel=0
n_anchor=0

while IFS="$(printf '\t')" read -r src lineno target; do
  [ -n "${target:-}" ] || continue
  case "$target" in
    http://*|https://*|mailto:*|tel:*|ftp://*|//*) continue ;;
  esac

  # split off the fragment (only the first '#'; slugs never contain '#')
  frag=""
  rel="$target"
  case "$target" in
    *'#'*)
      rel="${target%%#*}"
      frag="${target#*#}"
      ;;
  esac
  # percent-encoded spaces are the only escape that occurs in this corpus
  rel="$(printf '%s' "$rel" | sed 's/%20/ /g')"

  srcdir="$(dirname "$src")"

  if [ -z "$rel" ]; then
    # bare "#anchor" — resolves against the containing file
    resolved="$src"
  else
    case "$rel" in
      /*) resolved="$REPO_ROOT$rel" ;;
      *)  resolved="$srcdir/$rel" ;;
    esac
    n_rel=$((n_rel + 1))
    if [ ! -e "$resolved" ]; then
      printf '%s:%s -> %s\n' "$src" "$lineno" "$target" >> "$DEAD_LINKS"
      continue
    fi
  fi

  # anchor half
  [ -n "$frag" ] || continue
  case "$resolved" in
    *.md) ;;
    *) continue ;;                     # only markdown has headings we can slug
  esac
  n_anchor=$((n_anchor + 1))
  cache="$(slug_cache "$resolved")"
  if ! grep -Fxq "$frag" "$cache"; then
    printf '%s:%s -> %s   (no heading in %s slugs to "%s")\n' \
      "$src" "$lineno" "$target" "${rel:-$src}" "$frag" >> "$DEAD_ANCHORS"
  fi
done < "$LINKS"

if [ -s "$DEAD_LINKS" ]; then
  fail "$(grep -c . "$DEAD_LINKS") of $n_rel relative links do not resolve"
  sed 's/^/        /' "$DEAD_LINKS"
else
  pass "all $n_rel relative markdown links resolve"
fi

echo "── anchors: every cited #anchor is a real heading (anchors.md slug rule)"
if [ -s "$DEAD_ANCHORS" ]; then
  fail "$(grep -c . "$DEAD_ANCHORS") of $n_anchor cited anchors do not resolve"
  sed 's/^/        /' "$DEAD_ANCHORS"
else
  pass "all $n_anchor cited #anchors resolve to a real heading"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Part 3 — the manual section map round-trips against the compiler
# ─────────────────────────────────────────────────────────────────────────────
echo "── section map: manual/MANUAL.md ↔ tesl help manual <section>, both ways"

SECS="$WORK/sections.txt"
awk '
  /^### Manual sections/ { inb = 1; next }
  inb && (/^## / || /^### / || /^---[[:blank:]]*$/) { inb = 0 }
  inb && /^\|/ {
    n = split($0, f, "|")
    col = (n >= 2 ? f[2] : "")
    if (match(col, /`[a-z0-9][a-z0-9-]*`/)) {
      print "sec\t" substr(col, RSTART + 1, RLENGTH - 2)
      a = (n >= 3 ? f[3] : "")
      while (match(a, /`[a-z0-9][a-z0-9-]*`/)) {
        print "alias\t" substr(a, RSTART + 1, RLENGTH - 2)
        a = substr(a, RSTART + RLENGTH)
      }
    }
  }
' "manual/MANUAL.md" > "$SECS"

if [ ! -x "$MAIN_EXE" ]; then
  note "compiler not built ($MAIN_EXE) — skipping the section-map and"
  note "error_codes.ml anchor checks (they need 'tesl help manual')"
  SKIPPED_COMPILER=1
else
  SKIPPED_COMPILER=0
fi

n_secs="$(grep -c '^sec	' "$SECS" || true)"
if [ "${n_secs:-0}" -lt 5 ]; then
  fail "could not parse MANUAL.md's 'Manual sections' table (found $n_secs rows)"
elif [ "$SKIPPED_COMPILER" = 0 ]; then
  bad="$WORK/bad-sections.txt"; : > "$bad"
  # NB: the output goes to a FILE, never into a shell variable — `language-spec`
  # alone is 230 kB and a captured copy of it makes the very next fork fail with
  # E2BIG ("Argument list too long"), which reads like a broken section.
  while IFS="$(printf '\t')" read -r kind name; do
    [ -n "${name:-}" ] || continue
    "$MAIN_EXE" help manual "$name" > "$WORK/section.out" 2>/dev/null; rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$WORK/section.out" ]; then
      printf '%s "%s" is in MANUAL.md but "tesl help manual %s" fails (rc=%s)\n' \
        "$kind" "$name" "$name" "$rc" >> "$bad"
    fi
  done < "$SECS"
  if [ -s "$bad" ]; then
    fail "MANUAL.md names sections the CLI does not serve"
    sed 's/^/        /' "$bad"
  else
    pass "every section + alias in MANUAL.md's table is served by the CLI ($n_secs sections)"
  fi

  # reverse direction: the CLI's own advertised list must be documented.
  # NB: [[:space:]], not [[:blank:]] — BSD sed does not read \t inside a bracket
  # expression as a tab, it reads it as 't'.
  advertised="$("$MAIN_EXE" help manual __no_such_section__ 2>&1 >/dev/null \
                 | sed -n 's/^Available sections: //p' | tr ',' '\n' \
                 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -E '^[a-z0-9-]+$' || true)"
  if [ -z "$advertised" ]; then
    fail "could not read the CLI's 'Available sections:' list"
  else
    missing=""
    for s in $advertised; do
      grep -Fxq "$(printf 'sec\t%s' "$s")" "$SECS" \
        || grep -Fxq "$(printf 'alias\t%s' "$s")" "$SECS" \
        || missing="$missing $s"
    done
    if [ -n "$missing" ]; then
      fail "the CLI advertises sections MANUAL.md's table does not list:$missing"
    else
      pass "every section the CLI advertises is listed in MANUAL.md's table"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Part 4 — no orphan documents
# ─────────────────────────────────────────────────────────────────────────────
echo "── orphans: every manual/ and dev-docs/ page is linked from its index"

# orphan_scan <index-file> <dir> <exempt-basenames…>
orphan_scan() {
  local index="$1" dir="$2"; shift 2
  local exempt=" $* "
  local orphans="" f base
  [ -d "$dir" ] || return 0
  [ -f "$index" ] || { fail "missing index $index"; return 0; }
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$exempt" in *" $base "*) continue ;; esac
    grep -Fq "$base" "$index" || orphans="$orphans $base"
  done
  if [ -n "$orphans" ]; then
    fail "$dir: not linked by filename from $index:$orphans"
  else
    pass "$dir: every page is linked from $index"
  fi
}

orphan_scan "manual/MANUAL.md" "manual"       "MANUAL.md" "anchors.md"
[ -d "manual/intro" ] && orphan_scan "manual/MANUAL.md" "manual/intro" ""
orphan_scan "dev-docs/README.md" "dev-docs"   "README.md"

# ─────────────────────────────────────────────────────────────────────────────
#  Part 5 — no hand-typed corpus counts
# ─────────────────────────────────────────────────────────────────────────────
echo "── counts: no hand-typed lesson/test corpus size in any tracked .md"

# A PRECISE pattern list, not a vague grep: a standalone number (optionally
# "N+"), then at most a couple of adjective words, then the corpus noun it is
# counting.  Deliberately narrow so the corpus stays silent — a noisy check here
# would be worse than no check.  The lead `(^|[^0-9A-Za-z])` stops `lesson23`
# and `09-adding-tests.md` reading as counts; requiring a SPACE before each
# adjective word stops `3. Runs your tests` and `dev-docs/09-adding-tests.md`.
COUNT_PATTERNS='(^|[^0-9A-Za-z])[0-9]+\+?( [A-Za-z.`*_]+){0,2} lessons
(^|[^0-9A-Za-z])[0-9]+\+?( [A-Za-z]+)? tests'
count_hits="$WORK/counts.txt"
: > "$count_hits"
printf '%s\n' "$COUNT_PATTERNS" | while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  # shellcheck disable=SC2046
  grep -nE "$pat" $(cat "$DOCS") >> "$count_hits" 2>/dev/null
done
sort -u -o "$count_hits" "$count_hits"
if [ -s "$count_hits" ]; then
  fail "$(grep -c . "$count_hits") hand-typed corpus count(s) — generate it or drop the number"
  sed 's/^/        /' "$count_hits"
else
  pass "no hand-typed lesson or Racket-test corpus counts"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Part 6 — the producing side: error_codes.ml's manual deep-links resolve
# ─────────────────────────────────────────────────────────────────────────────
echo "── diagnostics: every 'manual = Some \"<section>#<anchor>\"' deep-link resolves"

EC="compiler/lib/error_codes.ml"
if [ ! -f "$EC" ]; then
  note "no $EC — skipping the diagnostic deep-link check"
elif [ "$SKIPPED_COMPILER" = 1 ]; then
  note "compiler not built — skipping the diagnostic deep-link check"
else
  # Ask the CLI to resolve each one: it prints a 'note: no heading …' to stderr
  # when the anchor is dead, which is exactly the failure a docs edit causes.
  # This uses the compiler's OWN section map and slug rule — no sixth copy here.
  deep="$WORK/deeplinks.txt"
  grep -oE 'manual = Some "[a-z0-9-]+#[a-z0-9-]+"' "$EC" \
    | sed 's/.*Some "//; s/"$//' | sort -u > "$deep"
  n_deep="$(grep -c . "$deep" || true)"
  if [ "${n_deep:-0}" -eq 0 ]; then
    note "no anchored manual deep-links found in $EC"
  else
    bad="$WORK/bad-deeplinks.txt"; : > "$bad"
    while read -r link; do
      [ -n "$link" ] || continue
      err="$("$MAIN_EXE" help manual "$link" 2>&1 >/dev/null)"; rc=$?
      if [ "$rc" -ne 0 ]; then
        printf '%s — tesl help manual failed (rc=%s)\n' "$link" "$rc" >> "$bad"
      elif printf '%s' "$err" | grep -q 'no heading in section'; then
        printf '%s — dead anchor: %s\n' "$link" "$(printf '%s' "$err" | head -1)" >> "$bad"
      fi
    done < "$deep"
    if [ -s "$bad" ]; then
      fail "$(grep -c . "$bad") of $n_deep error_codes.ml deep-links are dead"
      sed 's/^/        /' "$bad"
    else
      pass "all $n_deep anchored error_codes.ml deep-links resolve"
    fi
  fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  if [ "${SKIPPED_COMPILER:-0}" = 1 ]; then
    echo "doc-integrity: SKIP (compiler not built; markdown-only checks passed)"
    exit 77
  fi
  echo "doc-integrity: PASS"
else
  echo "doc-integrity: FAIL"
fi
exit "$FAIL"
