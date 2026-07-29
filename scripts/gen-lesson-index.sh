#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  scripts/gen-lesson-index.sh — the lesson corpus catalog, generated not typed
# ═══════════════════════════════════════════════════════════════════════════════
#
# THE DEFECT THIS EXISTS TO KILL.  The lesson corpus was indexed by hand in three
# places that all disagreed, and every count had drifted:
#
#   manual/examples.md   "73 .tesl lessons"   and a curated path listing 41 of them
#   manual/tour.md       "70+ lessons"
#   manual/MANUAL.md     "50+ structured lessons"
#   the truth            77 .tesl + 5 prose (and the count is now generated)
#
# ...and 37 lesson files appeared in NO index at all.  Hand-typed counts always
# drift; the fix is generation, not correction (roadmap/next/revised_onboarding.md
# defects 4, 7 and 12).
#
# THE SOURCE OF TRUTH is two comment lines in each lesson, so a lesson stays
# self-contained and greppable and there is no sidecar that can silently disagree
# with the directory:
#
#   # lesson: track=<track> order=<int> needs=<slug,slug|none>
#   # summary: <one line, sentence case, no trailing period>
#
# `needs` doubles as the "if you jumped straight here" pointer the reader sees in
# the file itself, and the generated index expands each prerequisite with that
# lesson's own one-liner — so nothing is duplicated and nothing can fall out of
# sync.
#
# Usage:
#   scripts/gen-lesson-index.sh           # regenerate manual/lessons.md in place
#   scripts/gen-lesson-index.sh --check   # verify the committed index + metadata
# Exit: 0 = ok, 1 = drift or invalid metadata, 77 = nothing to do (no corpus)
#
# BSD-clean: no GNU-only sed/grep/awk flags, no `readlink -f`, no `sed -i`.

set -uo pipefail

REPO_ROOT="${TESL_REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
LEARN_DIR="$REPO_ROOT/example/learn"
OUT="$REPO_ROOT/manual/lessons.md"

MODE="write"
[ "${1:-}" = "--check" ] && MODE="check"

[ -d "$LEARN_DIR" ] || { echo "gen-lesson-index: no example/learn — nothing to do"; exit 77; }

# The featured set — the impatient reader's why-Tesl showcase, NOT a
# build-your-first-API path.  It deliberately skips auth, capabilities, HTTP
# handlers, queues and SSE: those live in the getting-started walkthrough and in
# the full sequence below.  Decided in roadmap/next/revised_onboarding.md D5.
FEATURED="lesson00-hello-world lesson05-intro-to-proofs lesson12-records-with-proofs lesson14-test-blocks lesson18-database-sql-and-proofs lesson64-password-storage lesson68-server-endpoints-as-tools lesson72-units"

# Track display order and titles.  A track name not listed here is an error, so
# a typo in a lesson header cannot silently create a new track.
TRACKS="basics proofs api data async testing stdlib ai"
track_title() {
  case "$1" in
    basics)  echo "Basics — the language itself" ;;
    proofs)  echo "Proofs — the reason Tesl exists" ;;
    api)     echo "APIs — handlers, auth, capabilities" ;;
    data)    echo "Data — typed SQL and entities" ;;
    async)   echo "Async — queues, workers, streaming" ;;
    testing) echo "Testing and debugging" ;;
    stdlib)  echo "Standard library" ;;
    ai)      echo "AI-era surfaces" ;;
    *)       echo "$1" ;;
  esac
}

FAIL=0
err() { printf '  \033[31m✗\033[0m  %s\n' "$1" >&2; FAIL=1; }

# ── Harvest ─────────────────────────────────────────────────────────────────
# One record per lesson: slug<TAB>track<TAB>order<TAB>needs<TAB>summary
META="$(mktemp)"
trap 'rm -f "$META" "$META.gen" 2>/dev/null' EXIT

for f in "$LEARN_DIR"/*.tesl; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  slug="${base%.tesl}"
  # Metadata must appear in the first 40 lines — after the module header (which
  # the parser requires on line 1) and before the prose banner.
  head -n 40 "$f" > "$META.head"
  line="$(grep '^# lesson:' "$META.head" | head -n 1)"
  summary="$(grep '^# summary:' "$META.head" | head -n 1 | sed 's/^# summary: *//')"

  if [ -z "$line" ]; then
    err "$base: no '# lesson:' metadata line (see scripts/gen-lesson-index.sh header)"
    continue
  fi
  if [ -z "$summary" ]; then
    err "$base: no '# summary:' line"
    continue
  fi

  track="$(printf '%s' "$line" | sed -n 's/.*track=\([A-Za-z]*\).*/\1/p')"
  order="$(printf '%s' "$line" | sed -n 's/.*order=\([0-9]*\).*/\1/p')"
  needs="$(printf '%s' "$line" | sed -n 's/.*needs=\([A-Za-z0-9,-]*\).*/\1/p')"

  [ -n "$track" ] || { err "$base: metadata has no track="; continue; }
  [ -n "$order" ] || { err "$base: metadata has no order="; continue; }
  [ -n "$needs" ] || { err "$base: metadata has no needs= (use 'none')"; continue; }

  case " $TRACKS " in
    *" $track "*) ;;
    *) err "$base: unknown track '$track' (allowed: $TRACKS)" ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$track" "$order" "$needs" "$summary" >> "$META"
done
rm -f "$META.head"

[ -s "$META" ] || { err "no lesson metadata found at all"; echo "gen-lesson-index: FAIL"; exit 1; }

lesson_count="$(wc -l < "$META" | tr -d ' ')"

# ── Validate ────────────────────────────────────────────────────────────────

# 1. `order` is unique across the whole corpus.  Reading order is value order, so
#    two lessons claiming the same position is a real ambiguity, not a nit.
dupes="$(cut -f3 "$META" | sort | uniq -d)"
if [ -n "$dupes" ]; then
  for d in $dupes; do
    err "order=$d is claimed by more than one lesson: $(awk -F'\t' -v o="$d" '$3==o{printf "%s ", $1}' "$META")"
  done
fi

# 2. every declared prerequisite exists.  A dangling prereq is a link that will
#    404 in the generated index.
while IFS="$(printf '\t')" read -r slug track order needs summary; do
  [ "$needs" = "none" ] && continue
  echo "$needs" | tr ',' '\n' | while read -r n; do
    [ -n "$n" ] || continue
    if ! cut -f1 "$META" | grep -q "^$n$"; then
      err "$slug: prerequisite '$n' does not exist"
    fi
  done
done < "$META"

# 3. a lesson does not require itself, directly.
while IFS="$(printf '\t')" read -r slug track order needs summary; do
  case ",$needs," in *",$slug,"*) err "$slug: declares itself as a prerequisite" ;; esac
done < "$META"

# 4. every FEATURED lesson exists.
#    roadmap/next/revised_onboarding.md asks that the featured set "declare no
#    prerequisites", so that the showcase can be entered cold in any order.  That
#    is NOT enforced here, and the first attempt to enforce it was a mistake worth
#    recording: requiring featured lessons to declare only featured prerequisites
#    made the metadata INCOMPLETE — lesson12 genuinely assumes lesson03-records,
#    and lesson68 genuinely assumes lesson15 and lesson62, none of which are
#    featured.  Filtering true edges out of the source of truth to satisfy a
#    DISPLAY property is the wrong trade.
#
#    The cold-entry guarantee is delivered instead by the generated index, which
#    expands every prerequisite inline with that lesson's own one-liner — so a
#    reader landing on a featured lesson is told exactly what they are missing,
#    whether or not the prerequisite is itself featured.  That works for all 77
#    lessons rather than only the featured ones, which was the stated goal.
for feat in $FEATURED; do
  if ! cut -f1 "$META" | grep -q "^$feat$"; then
    err "featured lesson '$feat' does not exist"
  fi
done

# 5. a prerequisite must come EARLIER in reading order.  Otherwise the sequence
#    tells a patient reader to read something they have not reached yet, which is
#    the failure the ordering metadata exists to prevent.
while IFS="$(printf '\t')" read -r slug track order needs summary; do
  [ "$needs" = "none" ] && continue
  echo "$needs" | tr ',' '\n' | while read -r n; do
    [ -n "$n" ] || continue
    norder="$(awk -F'\t' -v s="$n" '$1==s{print $3}' "$META")"
    [ -n "$norder" ] || continue
    if [ "$norder" -ge "$order" ] 2>/dev/null; then
      err "$slug (order=$order) requires $n (order=$norder) — a prerequisite must come earlier"
    fi
  done
done < "$META"

# ── Generate ────────────────────────────────────────────────────────────────

summary_of() { awk -F'\t' -v s="$1" '$1==s{print $5}' "$META"; }

{
  echo "# Lessons"
  echo ""
  echo "<!-- GENERATED by scripts/gen-lesson-index.sh — do not edit by hand."
  echo "     The source of truth is the \`# lesson:\` and \`# summary:\` header"
  echo "     lines in each example/learn/*.tesl file. Change those, then run the"
  echo "     script. \`--check\` runs in the gate, so drift fails CI. -->"
  echo ""
  echo "Every lesson is a small runnable \`.tesl\` file with its explanation inline,"
  echo "and every one is also a regression test — each has a committed byte-exact"
  echo "\`.rkt\` snapshot and test blocks in the gate. Read one with:"
  echo ""
  echo '```bash'
  echo "tesl help manual <lesson-name>      # e.g. tesl help manual lesson05-intro-to-proofs"
  echo '```'
  echo ""
  echo "There are **$lesson_count** lessons. That number is generated; it cannot drift."
  echo ""
  echo "## In a hurry? Start with these"
  echo ""
  echo "A why-Tesl showcase rather than a build-your-first-API path — read them cold,"
  echo "in any order. Each one shows a thing no other language in this space does."
  echo "For building something end to end, follow the full sequence below instead, or"
  echo "start from [Getting Started](GETTING-STARTED.md) and [Your first change](first-change.md)."
  echo ""
  echo "| Lesson | Shows |"
  echo "|---|---|"
  for feat in $FEATURED; do
    s="$(summary_of "$feat")"
    [ -n "$s" ] || continue
    echo "| [\`$feat\`](../example/learn/$feat.tesl) | $s |"
  done
  echo ""
  echo "## The full sequence"
  echo ""
  echo "**Reading order is value order**: if you get through *N* lessons in an hour,"
  echo "the first *N* are the *N* that matter most. Where a lesson builds on an earlier"
  echo "one it says so, with the one-line reason — so you can jump in anywhere and know"
  echo "exactly what you are missing."
  echo ""
  for track in $TRACKS; do
    have="$(awk -F'\t' -v t="$track" '$2==t{print}' "$META")"
    [ -n "$have" ] || continue
    echo "### $(track_title "$track")"
    echo ""
    echo "| # | Lesson | What it teaches | Assumes |"
    echo "|---|---|---|---|"
    printf '%s\n' "$have" | sort -t"$(printf '\t')" -k3,3n | while IFS="$(printf '\t')" read -r slug t order needs summary; do
      if [ "$needs" = "none" ]; then
        assumes="—"
      else
        assumes=""
        for n in $(echo "$needs" | tr ',' ' '); do
          ns="$(summary_of "$n")"
          [ -n "$assumes" ] && assumes="$assumes<br>"
          assumes="$assumes[\`$n\`](../example/learn/$n.tesl) — $ns"
        done
      fi
      echo "| $order | [\`$slug\`](../example/learn/$slug.tesl) | $summary | $assumes |"
    done
    echo ""
  done
  echo "## Prose companions"
  echo ""
  echo "A few lessons have a longer prose companion alongside the code:"
  echo ""
  for md in "$LEARN_DIR"/*.md; do
    [ -f "$md" ] || continue
    b="$(basename "$md")"
    title="$(grep '^# ' "$md" | head -n 1 | sed 's/^# *//')"
    echo "- [\`$b\`](../example/learn/$b) — $title"
  done
  echo ""
  echo "---"
  echo ""
  echo "See also: [Examples](examples.md) for the standalone example applications,"
  echo "[the tour](tour.md) for the long read, and [the manual index](MANUAL.md)."
} > "$META.gen"

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "gen-lesson-index: FAIL (invalid lesson metadata — index NOT written)"
  exit 1
fi

if [ "$MODE" = "check" ]; then
  if [ ! -f "$OUT" ]; then
    err "manual/lessons.md does not exist — run scripts/gen-lesson-index.sh"
    echo "gen-lesson-index: FAIL"
    exit 1
  fi
  if diff -u "$OUT" "$META.gen" > /dev/null 2>&1; then
    echo "gen-lesson-index: PASS ($lesson_count lessons, index up to date)"
    exit 0
  else
    echo "gen-lesson-index: FAIL — manual/lessons.md has drifted from the lesson metadata"
    diff -u "$OUT" "$META.gen" | head -n 40
    echo "Fix: run scripts/gen-lesson-index.sh and commit manual/lessons.md"
    exit 1
  fi
fi

cp "$META.gen" "$OUT"
echo "gen-lesson-index: wrote manual/lessons.md ($lesson_count lessons)"
exit 0
