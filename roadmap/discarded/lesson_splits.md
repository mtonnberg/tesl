# Lesson splits — discarded (2026-07-29)

`roadmap/completed/revised_onboarding.md` D5 asked for **targeted splits** where a lesson does two jobs:

> a lesson that does two jobs gets split so the harder half moves back … **Splitting is different**:
> it is real editorial work, it adds lessons and snapshots, and it should be driven by evidence.
> Split only where the human trial or a maintainer identifies a lesson doing two jobs — not
> speculatively across all 75.

**Discarded.** The evidence was gathered — the reordering pass read all 77 lessons and named six
candidates — but each split adds a lesson, a byte-exact `.rkt` snapshot and test blocks for an
editorial gain that is real yet small next to the reorder itself, which has landed. The reorder was
the part that changed what a reader meets in their first hour; splitting `lesson21` in two does not.

The candidates are recorded here so the evidence is not lost, and so that reopening the case does
not mean re-reading the corpus.

## The candidates, with the evidence that identified them

| Lesson | The two jobs | Evidence |
|---|---|---|
| `lesson21-sql-reference` | a syntax cheat-sheet **and** the worked proof-carrying-SQL corpus | 30 exports, a 31-line `exposing` list, and it re-covers `innerJoin` (lesson48) and witness packing (lesson20/22). Its own banner calls itself a "cheat-sheet" |
| `lesson06-proof-check-proof-auth` | `check`/`establish` (validation) **and** `auth` (the HTTP trust boundary) | three trust mechanisms in one file, and after the Phase-0 security rewrite the `auth` half also carries a ~30-line signed-session lesson using `Crypto.checkSignature` |
| `lesson63-ai-structured-output` | `askFor` structured output **and** per-user bring-your-own-key providers | **self-declared** — its own banner opens "Two patterns" |
| `lesson25-standard-library-strings-lists-ints` | three modules in one | `lesson47-list-functions` already re-covers `Tesl.List` exhaustively, and the file draws 16 `W060 unused let binding` warnings — one per catalogue-style demonstration |
| `lesson66-query-parameters` | introduces all three request dictionaries, then teaches one | says "This lesson focuses on `request.queryParameters`" after introducing `cookies` and `headers`, leaving both stranded |
| `lesson12-records-with-proofs` | the featured showcase **and** a codec/API section | weakest of the six: splitting would cost a featured slot, and the `OrderLine` codec half pulls in `W091` codec-precision territory |

## If this is ever reopened

Two things make it cheaper now than it was:

- **Ordering lives in per-lesson metadata**, not in filenames. A split inserts a new `order=` value
  in the sparse 10…770 numbering and needs no renames or reference updates.
- `scripts/gen-lesson-index.sh` regenerates the catalog, and `scripts/regen-rkt-snapshots.sh`
  regenerates the snapshot, so the mechanical half is two commands.

`lesson63-ai-structured-output` is the one to do first if any are: it is the only self-declared case,
so the seam needs no judgement call.
