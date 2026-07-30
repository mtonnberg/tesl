# Revised onboarding

> **Status:** COMPLETE (2026-07-29). Phases 1, 2, 3 and 4 all landed; the two things this item
> stopped short of were each closed by a decision rather than left open.
>
> | Phase | Outcome |
> |---|---|
> | **1** — stop the contradictions | Done. README is a ~119-line router, `TESL.md` folded in and deleted, `GETTING-STARTED.md` rebuilt around `tesl init`, `dev-docs` quick start corrected, and a **doc-integrity script wired into `./ci.sh`** (278 links, 56 anchors, the section map round-tripped both ways). It also pulled `manual/tests` — 194 assertions — into the gate, which it had never been in |
> | **1** — lesson metadata | Done, with a **deviation**: ordering lives in per-lesson `# lesson:` headers and `manual/lessons.md` is generated from them, so the 75-file rename D5 costed out was **not needed**. `lesson64` was filled by a real lesson rather than renumbered |
> | **2** — the spine | Done: `manual/first-change.md` (S3), `CONTRIBUTING.md`, `dev-docs/12-your-first-compiler-change.md` |
> | **3** — the site | **Complete as delivered.** `playground/lessons.html` gives all 77 lessons a stable permalink and publishes to Pages. The docs-site half is deliberately **not** built — the forge already renders and searches `manual/*.md`, and D1 keeps the README the spine. The one genuine remainder (syntax-highlight the lesson source) moved to `roadmap/completed/playground_polish_and_adoption.md` |
> | **4** — browser checking | Done, and the D7 bet held: 1.07 MB / 351 KB gzipped, 5-65 ms warm, diagnostics byte-identical to `tesl --check-json`. The embedded manual costs nothing — dead-code elimination drops all 2.3 MB |
> | Human trials | **Scoped out** — run by the maintainer outside the roadmap. The reason they matter is preserved: no CI phase can tell you where a reader stalls |
> | Lesson splits | **Discarded** — six evidence-backed candidates recorded in `roadmap/discarded/lesson_splits.md` |
>
> Two recommendations this item's own analysis produced and that were **not** followed, with reasons
> in place: the `lesson64` renumber and the 75-file lesson rename. Both were made unnecessary by
> putting ordering in metadata.
>
> Follow-on work lives in `roadmap/completed/playground_polish_and_adoption.md`.

## Background

We have a lot of documentation and, as far as we know, it is up to date. That is exactly the
problem: it is comprehensive, it is *accurate*, and it gives a newcomer — user or new maintainer
— no idea where to start.

## Goal

- When an interested person asks for a link, the maintainers have **one** good link to send.
- Onboarding is crisp, welcoming, helpful, and not verbose. (Same for all documentation.)
- Onboarding is a **journey**, not a well-structured readme. Other steps are part of the plan.
- LLMs like a lot of documentation, but human readers must be able to use the system too.

### What "done" means, concretely

A person who has never seen Tesl, given one URL and no other help, reaches a running,
type-checked API of their own within **30 minutes**, and has hit and fixed **one deliberate proof
error** along the way — because that is the moment the language sells itself. If they can't, the
onboarding failed regardless of how good the docs are.

---

## The actual problem, measured

Not "the docs are long". The problem is **routing**: there are ~15 plausible front doors, several
of which contradict each other, and no spine connecting them.

### Inventory of entry points

| Entry point | Size | What it claims to be |
|---|---|---|
| `README.md` | 267 lines | Pitch + quick start + a *second*, different quick start |
| `TESL.md` | 27 | "This root file is intentionally short" — routes to three places |
| `INSTALL.md` | 188 | Install + editor setup |
| `manual/MANUAL.md` | 180 | The manual index; its own "where do I start?" |
| `manual/GETTING-STARTED.md` | 484 | Zero to a working project |
| `manual/overview.md` | 194 | "What Tesl is and the problem it solves" |
| `manual/tour.md` | 1016 | Every feature in one read |
| `manual/examples.md` | 192 | Example catalog + a "Learning Path" |
| `manual/FAQ.md` | 589 | Get unstuck |
| `manual/best-practices.md` | 1175 | Idiomatic patterns |
| `manual/ai-testing.md`, `agent-handoffs.md`, `deploy.md`, `tesl-manifest.md`, `anchors.md` | ~600 | Topic references |
| `example/intro/` | 13 slide files | A complete, well-written narrative introduction |
| `example/learn/` | **75** lessons | The learning track |
| `AGENTS.md` | 200 | The AI-agent entry point |
| `dev-docs/` | 14 files, ~2400 lines | The maintainer track |
| `LANGUAGE-SPEC.md` | 4094 | Source of truth |

≈12 000 lines of prose plus 75 lessons. All of it good. None of it ordered.

### Concrete defects found (2026-07-29) — the evidence, not vibes

1. **README contains two quick starts that disagree.** `## Quick start` uses
   `nix profile install` → `tesl init` → `tesl run` (correct, no checkout). `## Try the language
   today`, 150 lines later, tells you to `tesl validate example/sandbox.tesl` and
   `bash scripts/postgres-start.sh` — both of which **require a repo checkout**, contradicting
   the FAQ's "Do I need to clone the repository to use Tesl?" and INSTALL.md.
2. **GETTING-STARTED never mentions `tesl init`.** Its "Option 1: Start from Scratch" is `mkdir`
   + `touch api.tesl`; "Option 2" is copy a file "from a repository checkout". The README's
   headline path does not appear in the getting-started guide.
3. **Three different recommended first paths.** README says `tesl init`. `MANUAL.md` says
   overview → getting-started → examples. `TESL.md` says README → tour → spec.
4. **Counts have already drifted.** `manual/examples.md:35` says "**73** `.tesl` lessons";
   `manual/tour.md:1004` says "70+"; the real number is **75**. Hand-typed counts always drift —
   the fix is generation, not correction.
5. **Lesson numbers collide.** `lesson23-queues-and-workers.md` sits beside
   `lesson23-maybe-and-optional-values.tesl`, and `lesson24-pubsub-sse.md` beside
   `lesson24-error-handling-patterns.tesl` — same number, unrelated topics. **`lesson64` does not
   exist.** Five `.md` files live in `example/learn/` with no stated relationship to the `.tesl`
   lessons.
6. **The best conviction asset is invisible.** `example/intro/` is a 13-slide narrative that does
   the "why should I care" job better than anything else in the repo. It is linked from one line
   of `MANUAL.md`'s table of contents and one table in `examples.md`. It is not linked from the
   README, and it lives under `example/` even though it is not an example.
7. **The curated learning path covers less than half the lessons.** `examples.md`'s "Learning
   Path (Recommended Order)" is a flat numbered list; ~30 of the 75 lessons appear nowhere in it.
8. **A genuine strength is unadvertised.** Every diagnostic has a stable code, `tesl explain
   <CODE>` works, and errors carry machine-applicable fixes and manual deep-links. For a language
   whose pitch is "the compiler tells you exactly what is wrong", this belongs in the first
   90 seconds, not in the FAQ's tooling section.
9. **There is no maintainer onboarding, and the nearest thing to it is wrong.**
   `dev-docs/README.md` has a four-line "Quick start for a new contributor" whose step 2 —
   *"Run the test suite to confirm your environment works"* — gives a command that runs **one
   lesson's tests**, not the test suite. It never mentions `cd compiler && dune build`, the nix
   dev shell, `TESL_REPO_ROOT`, or the actual gate.
10. **The authoritative gate is not named anywhere a contributor will look.** `./ci.sh` at the
    repo root is the real gate; `compile-examples.sh` and `compiler/ci.sh` are now thin `exec`
    shims into it (`roadmap/completed/combine_qa_scripts.md`). `dev-docs/README.md` mentions
    none of the three. The single most important command a contributor can run is absent from
    the contributor docs.
11. **No `CONTRIBUTING.md`.** GitHub surfaces that file in the issue and pull-request UI. Its
    absence means a would-be contributor is never shown a ramp at the moment they are trying to
    use one.
12. **The maintainer docs have their own hand-typed drift.** "657+ Racket tests" appears in both
    `dev-docs/README.md:73` and `dev-docs/01-overview.md:43` — the same generated-not-typed
    problem as defect 4, on the other track.

---

## Design decisions

These are the calls that shape everything else. Each is a recommendation, not a settled fact.

### D1 — What is "the one link"?

**Recommendation: the GitHub README, rewritten as a router (~100 lines).** Not a homepage, not
yet.

Rationale: it is already the canonical URL, it renders everywhere maintainers actually share
links (chat, HN, issues), it costs nothing to host, and it cannot rot separately from the repo.
A homepage was considered and discarded (`roadmap/discarded/make_thesl_home_page.md`), and
`roadmap/completed/architecture_trajectory.md:12` records the adoption path — playground,
homepage, package manager, non-Nix distribution — as carved to a later decision. **This item
should not silently re-open all of that.** Phase 3 proposes a static site generated from the
same sources, which is a much smaller commitment than a homepage project; Phase 4 proposes the
one part of a playground that is genuinely cheap now.

Honest caveat to name in the plan: **Nix is a hard gate.** "One good link" ends at
`nix profile install` for anyone who does not have Nix and does not want it. No amount of doc
work fixes that; it is the non-Nix distribution decision, and it belongs to the adoption-path
item, not this one. The plan should state the ceiling rather than pretend the docs can raise it.

### D2 — Humans get a spine; LLMs keep the corpus

The goal's last bullet is the sharpest constraint: *LLMs like a lot of documentation, but human
readers must be able to use the system.* These are not in conflict if the corpus stays and the
**routing** changes.

- **Keep** every document. `tesl help manual full` / `tesl help full` already serves the
  large-context-LLM case perfectly, and `AGENTS.md` + `agent-context` serve the agent case.
  Nothing about that needs to change, and it should be stated as a deliberate design, not an
  accident.
- **Add** a spine: a short, ordered path with exactly one "next" at each step.
- **Demote** everything else to reference — reachable, searchable, cited by diagnostics, but
  never the thing a newcomer lands on.

The rule: **no document is deleted for being long; documents are deleted for being duplicates.**

### D3 — Delete duplicates, promote the good stuff

| Document | Action | Why |
|---|---|---|
| `README.md` | Rewrite to ~100 lines; **delete `## Try the language today` entirely** | It is a stale duplicate of the quick start that requires a checkout |
| `TESL.md` | **Decided: fold into README and delete** (keep the *Runtime cost* paragraph — move it to the tour) | 27 lines whose only job is routing, competing with the README's routing. Drop its key from `gen_docs.ml`'s root-doc list and grep the tree for links |
| `example/intro/` | **Decided: clean move** to `manual/intro/`; make it the #1 link from the README | It is the best "why care" asset and it is not an example. Changes embedded-doc keys and `tesl help manual intro` resolution — both are part of the move, not reasons to avoid it |
| `manual/overview.md` | Fold into the promoted intro; keep the `overview` section name as an alias | Three documents ("intro", "overview", "tour") answer "what is Tesl" |
| `manual/GETTING-STARTED.md` | Rewrite around `tesl init` | It teaches a from-scratch path that contradicts the README |
| `manual/tour.md` | Keep, unchanged in scope; label it "the long read" | Genuinely useful as reference; wrong as a first read |
| `manual/best-practices.md`, `FAQ.md`, `LANGUAGE-SPEC.md` | Keep as reference | Correctly sized for their job |
| `example/learn/*.md` (5 files) | Resolve against the `.tesl` lessons; renumber or rename | Two of them collide with unrelated lesson numbers |
| `dev-docs/` | Keep; add one missing piece (D5) | Good content, no entry ramp |

### D4 — The journey has six stages, and we only serve three

"More than a well-structured readme" means naming the stages and owning each one.

| # | Stage | Time | Today | Needs |
|---|---|---|---|---|
| **S0** | *What is this?* | 60 s | README top — decent | A code sample showing the **proof error**, above the fold |
| **S1** | *Do I believe it?* | 5 min | `example/intro/` — good, invisible | Promote it; make it the README's first link |
| **S2** | *Does it run on my machine?* | 10 min | Works, but two contradictory recipes | One recipe. Plus a **cold-start test in CI** so it stays true |
| **S3** | *Can I build my thing?* | 1 h | **Missing** | A guided first change to the `tesl init` scaffold that deliberately triggers a proof error and fixes it |
| **S4** | *Fluency* | days | 75 lessons, no real path | Curated tracks, generated index, prerequisites declared in the lessons |
| **S5** | *I want to change the compiler* | weeks | **Missing** — see defects 9–12 and D6 | A maintainer ramp: environment, the gate, one real end-to-end change |

**S3 is the biggest gap and the cheapest win.** The scaffold already exists and is already
commented; what is missing is a page that says "now change *this* line, watch it fail, here is
why, here is the fix." That is the moment the language earns a user, and nothing in the repo
currently stages it.

**S5 matters as much as S0.** The goal says "users and new maintainers alike", and
`roadmap/discarded/security_hardening_audit.md` names bus factor as a live risk. A maintainer
ramp is not a nice-to-have here. It is missing entirely — see D6.

There is also a **parallel journey**: someone points an AI coding agent at Tesl. `AGENTS.md`
serves it well and `tesl init` already writes an `AGENTS.md`/`CLAUDE.md` into new projects. The
spine should route to it explicitly and early rather than treating it as a footnote — for a
language positioned "for the AI-era", that path is likely the *majority* path.

### D5 — Make the lesson track a structure, not a directory listing

75 lessons in a flat folder with hand-maintained prose indexes is why the count has already
drifted three ways.

- **Declare metadata in each lesson's header comment** — track, prerequisites, one-line summary.
  (Format was left open; **decided: header comment, not a sidecar manifest.** Lessons stay
  self-contained and greppable, `./ci.sh` already reads every lesson file so the check needs no
  new file discovery, and a sidecar is one more thing that can silently disagree with the
  directory — which is the exact failure mode this decision exists to kill.)
- **Generate** the lesson index, the learning path, and every count from that metadata. No
  hand-typed lesson lists survive. Apply the same rule to the maintainer docs' "657+ Racket
  tests" (defect 12).
- **Test it:** every lesson belongs to exactly one track; every declared prerequisite exists;
  no number is used twice; no gaps.
- **Renumber the tail to close the `lesson64` hole** (decided). Cost: every renamed lesson's
  byte-exact `.rkt` snapshot regenerates and every cross-reference to a lesson number moves —
  `manual/tour.md`, `manual/examples.md`, `LANGUAGE-SPEC.md`, and the `tesl help manual
  lessonNN-…` best-effort lookup. Do it **inside Phase 1**, before the generated indexes and the
  Phase 3 permalinks exist, because renumbering after those ship breaks published URLs.
- **Keep every lesson; feature seven of them.** Cutting the list was never an option: the lessons
  are **also regression tests** — each has committed byte-exact `.rkt` snapshots and test blocks
  in the gate — so the corpus has a dual role and deleting or demoting a lesson removes coverage.
  The problem is not that there are 75; it is that all 75 look equally important and
  `manual/examples.md`'s "Learning Path" silently omits about 30 of them (defect 7).

  **The featured set (decided):**

  | Lesson | Shows |
  |---|---|
  | `lesson00-hello-world` | it runs |
  | `lesson05-intro-to-proofs` | the core idea |
  | `lesson12-records-with-proofs` | proofs on real data shapes |
  | `lesson14-test-blocks` | testing is in the language |
  | `lesson18-database-sql-and-proofs` | typed SQL carrying proofs — the payoff |
  | `lesson68-server-endpoints-as-tools` | the AI-era differentiator |
  | `lesson72-units` | compile-time dimensions |

  Note what this set *is*: a **why-Tesl showcase**, not a build-your-first-API path — it
  deliberately skips auth, capabilities, HTTP handlers, queues and SSE, all of which you need to
  ship something. That maps cleanly onto the journey (D4): the seven serve **S1, conviction**;
  the fundamentals live in the S3 scaffold walkthrough and the full lesson list serves S4.
  Worth confirming that reading is intended, since it decides what the rewrite optimises for.

- **Two audiences, two mechanisms — decided.** The featured seven serve the **impatient** reader:
  a why-Tesl showcase, entered cold, in any order. The **patient** reader is served by the lesson
  sequence itself, and that means the sequence has to become a real curriculum:

  > **Reading order is value order.** If a reader gets through *X* lessons in an hour, the first
  > *X* should be the *X* that matter most. Advanced material moves later, and a lesson that does
  > two jobs gets split so the harder half moves back.

  That is a stronger commitment than fixing the `lesson64` gap. It is a **full reorder of the
  corpus by importance**, plus targeted splits. See below for how to make it affordable.

- **Cold-entry blocks, generated — not hand-duplicated.** The open question was how far
  "stand alone" goes: full self-containment duplicates explanation across seven files that then
  drift, while a shared preamble reintroduces reading order. Both are avoidable, because D5
  already puts prerequisites and a one-line summary in every lesson's header.

  So **generate** a short "if you jumped straight here" block from that metadata — *"Assumes:
  proofs (`lesson05`), records with proofs (`lesson12`)"*, each with the one-liner pulled from
  that lesson's own header. Zero duplication, nothing to keep in sync, and it works for every
  lesson rather than only the seven. The patient reader skips it; the impatient reader gets
  exactly the pointers they need.

- **Decouple order from the filename — recommended, and this is the decision to confirm before
  Phase 1 starts.**

  Renumbering is not a rename. Verified 2026-07-29:

  - **The filename and the module name are locked together by the language.**
    `check_file_module_name_match` (`compiler/lib/validation_advanced.ml:1459`) requires the file
    to be the kebab-case or PascalCase form of the module header — and it is **not a style rule**:
    *"the compiler resolves imports by file name, so no other file can `import Bar`."* So the
    number lives in `module Lesson18DatabaseSqlAndProofs` too, and every rename is a paired edit
    by construction. There is no version of this where you move the file and leave the module
    name alone.
  - Renaming a lesson therefore also breaks any **cross-lesson import** — they resolve by file
    name, and at least one pair does this today (`lesson07-consumer` → `lesson07-home`).
  - There are **110 `lessonNN` references** across `manual/` and `LANGUAGE-SPEC.md`.
  - Every rename regenerates a byte-exact `.rkt` snapshot whose embedded source map carries the
    path.

  So one reorder is ~75 renames + 75 module-name edits + 75 snapshot regenerations + ~110
  reference updates + cross-lesson import fixes + embedded-doc key churn + the
  `tesl help manual lessonNN-…` lookup. **And a curriculum that is supposed to evolve pays that
  every time.**

  *(The validator exempts "standalone fixture/example files", so a lesson's module name may not be
  strictly forced today. Do not build on that — the cross-lesson import still resolves by file
  name, and deliberately letting the two drift would be a worse state than either option below.)*

  | Option | Reorder cost, now | Reorder cost, forever |
  |---|---|---|
  | Keep numbers in filenames (and so in module names) | one big mechanical commit | the same big commit, every time |
  | **Order lives in the D5 metadata; filenames are stable slugs** — `typed-sql.tesl` / `module TypedSql`, which satisfies the kebab↔PascalCase rule unchanged | one big mechanical commit | **a metadata edit** |

  The numbers in filenames are precisely what produced the `lesson64` gap, the `lesson23`/`24`
  collisions, and three disagreeing counts. Since the sequence is now meant to be curated and
  revised, encoding it in 75 filenames is encoding the most volatile thing in the most expensive
  place. **Recommendation: move ordering into the metadata.**

  Cost of that choice, stated plainly: one large rename now, and the loss of a genuinely useful
  affordance — "I'm on lesson 12" and the muscle memory of `tesl help manual lesson17-telemetry`.
  Mitigate by having the *generated* index and the Phase 3 site display the sequence number
  prominently, and by keeping the help lookup resolving both the slug and the displayed number.

- **Reorder mechanically; split editorially.** Whichever option wins, do the reorder as **one
  scripted, content-free commit** — renames, module names, references, snapshots — so the diff is
  reviewable and content edits land separately. **Splitting is different**: it is real editorial
  work, it adds lessons and snapshots, and it should be driven by evidence. Split only where the
  human trial or a maintainer identifies a lesson doing two jobs — not speculatively across all 75.

This kills defects 4, 5, 7 and 12 by construction and gives Phase 3/4 a machine-readable lesson
catalog for free.

### D6 — The maintainer ramp (currently absent)

The goal names maintainers explicitly, and there is no ramp — defects 9–12. This is not a
"polish the dev-docs" task; the content largely exists and is good. What is missing is the
**path in**, and the two things a newcomer needs before any of the guides make sense: a working
environment and the command that says yes or no.

Three deliverables.

**1. `CONTRIBUTING.md` at the repo root — decided.** The forge shows it in the issue and
pull-request UI, which is the one moment a would-be contributor is actively looking for a ramp.
Short, a router, same shape as the rewritten README: how to get a working environment, how to
run the gate, where the guides are, how the roadmap works. **It routes; `dev-docs/` holds the
content** — the same spine-and-corpus split as D2, applied to the second audience. Keeping it a
router is also what stops it drifting from `dev-docs/`, which is how the current four-line
quick start ended up wrong.

**2. Fix `dev-docs/README.md`'s quick start** so it is correct and complete. It must state, in
order:

- the nix dev shell as the supported environment;
- `cd compiler && dune build` → `compiler/_build/default/bin/main.exe`;
- `TESL_REPO_ROOT` must point at the checkout or the stdlib will not resolve — and it is exported
  by direnv, which is a trap when working in a git worktree (it keeps pointing at the main repo,
  so snapshot tests compare against the wrong tree);
- **`./ci.sh` is the authoritative gate.** `compile-examples.sh` and `compiler/ci.sh` are `exec`
  shims into it and `dune test` alone is not sufficient. Name the real one, and say what the
  shims are, so muscle memory and documentation stop disagreeing;
- the PostgreSQL setup the suites need;
- the "version mismatch, found 8.18" failure means stale `.zo` bytecode — clear and recompile,
  it is not a regression. This is the single most likely first-hour confusion.

**3. "Your first compiler change" — one real change, end to end.** The equivalent of S3 for
maintainers, and the piece that does not exist in any form. Walk it: where to edit, what breaks
first, what the gate says, which snapshots regenerate and why, how to read a failing byte-exact
diff, how to add the regression test, what a finished change looks like.

**Decided: the worked example is improving a diagnostic message.** Better than the obvious
candidate (adding a stdlib function) on every axis that matters here:

- **It is on-brand.** The language's pitch is "the compiler tells you exactly what is wrong". A
  contributor's first act being *making that truer* is the right first act, and it teaches the
  house standard for what a good Tesl error looks like — stable code, precise span, a machine-
  applicable `fix` where possible, a manual deep-link.
- **It is never out of stock.** There is always an error message worth improving, so the guide
  does not depend on one specific unimplemented feature staying unimplemented.
- **Small blast radius, full tour.** It touches the parser or checker, `error_codes.ml`, the
  diagnostic emitter, often `diag_fix.ml`, the manual anchor it cites, and a test — which is a
  complete lap of the pipeline without being a risky change.
- **It teaches the ratchet workflow for free.** Changing an error message changes byte-exact
  expectations, so the contributor meets the snapshot/regeneration discipline in the one context
  where breaking it is harmless. That is exactly the lesson to learn early.
- **The fix is provably useful**, so it can be merged rather than reverted — the guide documents
  a real commit, not a rehearsal.

**Decided: `W020` — "module name not UpperCamelCase"** (`compiler/lib/linter.ml:237-247`,
`compiler/lib/error_codes.ml:242`). Fifteen lines of code containing five *graded, genuinely
real* improvements, which is close to ideal for a teaching walkthrough — a contributor can stop
after any one of them and have shipped something:

| # | The defect | What it teaches |
|---|---|---|
| 1 | `emit i 0` — the span is column 0, so the editor squiggle covers the line start, not the offending name | spans and `location.ml`; why a precise range matters to LSP |
| 2 | **No `fix`**, despite this being the most mechanically fixable diagnostic in the compiler (`todo_api` → `TodoApi`) | `diag_fix.ml`, the verified-builder pattern, and how a fix reaches the LSP quickfix and `agent-context` |
| 3 | The check is only *"first character is uppercase"* — `Todo_api` and `TODOAPI` both pass — while the message says UpperCamelCase | the house standard that a diagnostic must not overclaim. Tighten the check or soften the message, and defend the choice |
| 4 | `starts_with stripped "module "` is line-prefix text matching, not AST | why the linter is text-based and where that bites |
| 5 | `manual = Some "best-practices"` with no `#anchor`, so the deep-link lands at the top of a 1175-line file instead of `#naming-conventions`, which exists | the anchor contract (`manual/anchors.md`) from the producing side |

Do it in public and write it up afterwards. Start at #2 — a machine-applicable fix is the most
satisfying first contribution and the most representative of what this compiler is for.

The load-bearing detail is that this repo has a lot of **single-source machinery that punishes
skipped steps** — capability maps, the stdlib binding seam test, generated docs promoted on
build, byte-exact snapshots. A guide that lists the steps is not the same as a guide that shows
what happens when you miss one. Write the second kind.

**Explicitly in scope, and cheap:** state the trunk-based workflow, that there is no
`CODEOWNERS`/review requirement to satisfy, and how `roadmap/next` → `roadmap/completed` works.
A newcomer cannot infer any of that, and every one of them is a stall.

### D7 — The playground: take the cheap half, skip the expensive half

The note asks whether it is time to revisit the online editor. It was discarded
(`roadmap/discarded/online_editor_to_drive_adoption.md`) on the strength of the hard part:
running a Tesl program needs Racket, PostgreSQL, and a sandbox per session.

**One fact changes the calculus, and it is not the one that doc considered.**

The Tesl **compiler is pure OCaml**. `compiler/lib/dune` declares exactly two libraries — `str`
and `unix` — and `unix` is used only for opt-in phase timing. Parsing, type checking, **proof
checking**, diagnostics with fixes, and the Racket/TypeScript/Elm emitters are all in that
library, and the whole manual is already baked into it (`embedded_docs.ml`). That is a
`js_of_ocaml` target.

So split the ask in two:

| Half | What it needs | Verdict |
|---|---|---|
| **Check it in the browser** — type errors, *proof errors*, quick-fixes, generated Racket/TS/Elm, `tesl help` | a `js_of_ocaml` build. No server, no container, no database, no per-session state, no abuse surface | **Feasible and cheap.** Spike it. |
| **Run it in the browser** — serve HTTP, hit endpoints, see SSE | Racket + PostgreSQL + sandboxing + hosting + abuse handling | Still expensive. Still discarded. |

The first half is the one that demonstrates Tesl's actual thesis. *"Paste this, watch the
compiler refuse to let an unvalidated string reach the database"* is the whole pitch, and it does
not require executing anything. Sharing is then a compressed URL hash — no backend, no storage,
no moderation — which also answers "a good way to share Tesl code".

**Decided: Phase 4, gated on a spike, explicitly scoped to checking only.** If the
`js_of_ocaml` build turns out to be awkward (the `str`/`unix` uses are the risk), drop it — the
rest of the plan stands on its own. Do **not** reopen the container-per-session design.

---

## Phases

Each phase is independently shippable and independently useful.

### Phase 1 — Stop the contradictions (S, no new structure)

The bleeding first. Nothing here needs a decision.

- Delete `README.md` § *Try the language today*; keep one quick start.
- Rewrite `manual/GETTING-STARTED.md` around `tesl init`.
- Fold `TESL.md` into the README and delete it (D3); make `MANUAL.md` and `README.md` agree on
  one first path.
- **Reorder the lesson corpus by value** (D5), as one scripted content-free commit, and resolve
  the `lesson23`/`lesson24` `.md`/`.tesl` collisions and the `lesson64` hole as part of it. Do it
  here — before generated indexes and before Phase 3 mints permalinks. This is the largest single
  piece of Phase 1; confirm the filename-vs-metadata ordering decision before starting it.
- Add the lesson-metadata headers and the structural tests (D5); generate every count and table,
  and the cold-entry blocks.
- Fix `dev-docs/README.md`'s quick start and name `./ci.sh` as the gate (D6.2). Cheap, and it
  unblocks anyone who shows up before Phase 2 ships.

### Phase 2 — The spine (M — the core of this item)

- README rewritten as a router, ~100 lines, with the proof-error sample above the fold.
- `example/intro/` → `manual/intro/` (clean move), promoted to the first link, `overview`
  aliased to it.
- **Write S3**: the guided first change to the `tesl init` scaffold — trigger a proof error on
  purpose, read it, fix it. The single highest-value new document in the plan.
- **The maintainer ramp (D6)**: `CONTRIBUTING.md` + "your first compiler change".
- Curated lesson tracks and the featured seven, generated from the metadata (D5).
- ~~**Targeted lesson splits** where the reorder or the trial showed a lesson doing two jobs.~~
  **DISCARDED 2026-07-29.** The ordering pass identified six candidates with evidence
  (`lesson21-sql-reference`, `lesson06-proof-check-proof-auth`, `lesson63-ai-structured-output`,
  `lesson25-standard-library-strings-lists-ints`, `lesson66-query-parameters`, and — weakest —
  `lesson12-records-with-proofs`), and each split would add a lesson, a snapshot and test blocks
  for an editorial gain that is real but small next to the reorder itself. Not doing them.
  The candidate list is preserved in `roadmap/discarded/lesson_splits.md` so the evidence is not
  lost if the case is ever reopened.
- Route the AI-agent path explicitly from the spine.

### Phase 3 — The site (M, in scope, no new runtime)

**Decided: in scope, hosted on the forge's own static pages, no domain.** A static site generated
from the same markdown — no backend, no service to operate. Gets "a homepage listing all the
lessons" without reopening the homepage decision: lessons rendered with syntax highlighting and a
stable permalink each, the spine as the nav, search over the same corpus.

Preconditions: Phase 1's generated lesson catalog (so the site never disagrees with the repo)
**and** Phase 1's renumbering (so no permalink is minted against a number that is about to move).

**Two constraints, both from the planned forge move.**

1. **Keep the generator host-agnostic.** Plain static output plus one CI step — no
   GitHub-specific plugins, no Actions-only build logic, no Pages-specific path assumptions.
   Then moving forge is a CI-config change, not a rewrite. Both GitHub and the likely
   destination serve static pages the same way, so this costs nothing to honour up front and is
   expensive to retrofit.
2. **Do not let the site URL become the one link.** A `*.github.io` address is a URL you will
   have to abandon at the move, and a domain is the only thing that would survive it — which is
   precisely the recurring obligation being avoided here. So: **the README stays the canonical
   link** (D1), the site is a nicer way to read the same content, and nothing published or cited
   depends on the Pages URL. Revisit the domain question at the forge move, when there is a
   reason to pay for it.

Keep it a build artifact of the repo with no hand-maintained content, so the cost stays at "a CI
step", and so a stale site is impossible rather than merely unlikely.

### Phase 4 — Browser checking + shareable links (L, gated on a spike)

Per D7. Deliverables: `js_of_ocaml` build of the compiler library, an editor pane, real
diagnostics, `#`-hash sharing, every lesson openable in it from the Phase 3 site.

**Timing (decided): after Phase 2, or in parallel with Phases 2–3 if someone can pick it up
independently.** It shares no files with the docs work — it is a dune target and a web front end
— so parallel is genuinely safe; the only coupling is that Phase 3's lesson pages want to link
into it, and that link can be added last.

Spike first (≈1 day): does `tesl_compiler_lib` build under `js_of_ocaml` with its `str` and
`unix` uses stubbed, and how large is the artifact with `embedded_docs.ml` baked in?

---

## Machinery the reshuffle must respect

Moving docs in this repo is not `git mv`. Every one of these will bite:

| Constraint | Where | Consequence |
|---|---|---|
| **Contracted, test-guarded anchors** | `manual/anchors.md` | Compiler diagnostics cite `<section>#<anchor>`. **Never move an anchor-backed heading without migrating the anchor.** Renaming `overview` breaks live error messages. |
| **Section-name map is hardcoded in OCaml** | `compiler/bin/main.ml:226`, `:274`, `:373`, `:639` | Adding, renaming, or removing a manual section is an OCaml change in ~4 places, plus `MANUAL.md`. The two drift independently today. |
| **Docs are baked into the binary** | `compiler/gen/gen_docs.ml`, promoted to `compiler/lib/embedded_docs.ml` on every `dune build` | Adding a `manual/*.md` is automatic; moving `example/intro/` changes the embedded key namespace. Never hand-edit the generated file; let dune re-promote. |
| **Diagnostic deep-links** | `main.ml:702-717` and the diagnostic emitters | ~15 hardcoded `tesl help manual <section>#<anchor>` strings point into `best-practices` and friends |
| **Lesson snapshots are byte-exact** | `example/learn/*.rkt` | Renaming or editing a lesson regenerates its snapshot, whose embedded source map carries the path; the gate diffs them |
| **A file's name and its module name are locked together** | `check_file_module_name_match`, `compiler/lib/validation_advanced.ml:1459` | Not style — **the import resolver resolves by file name**. Every lesson rename is a paired file+module edit, and it breaks any cross-lesson import (`lesson07-consumer` → `lesson07-home`). This is the fact that makes numbers-in-filenames expensive (D5) |
| **`./ci.sh` (repo root) is the authoritative gate** | `compile-examples.sh` and `compiler/ci.sh` are `exec` shims into it (`roadmap/completed/combine_qa_scripts.md`) | `dune test` alone misses the example sweep and the Racket suites. **Three names for one gate is itself an onboarding defect** (defect 10) — the docs should name `./ci.sh` and explain the shims once |

**Add a doc-integrity check** as part of Phase 1, because the reshuffle will break links and
nothing currently catches that:

- every relative link in every `.md` resolves;
- every `#anchor` cited anywhere resolves to a real heading — including the ones inside
  `error_codes.ml`'s `manual` fields, which is the producing side of the contract (see D6 #5);
- every section named in `MANUAL.md` is accepted by `tesl help manual <section>`, **and the
  reverse** (this closes the `main.ml` ↔ `MANUAL.md` drift);
- every `manual/*.md` and every lesson is reachable from the spine within N clicks (no orphans);
- the featured seven declare no prerequisites and the rest declare valid ones (D5).

**Shape (decided): its own script, invoked by a `./ci.sh` phase.** Runnable standalone for fast
feedback — it is markdown work and does not need the six-minute gate — while still being part of
the authoritative run, so it cannot be skipped by forgetting. This is the same shape the repo
already uses for its QA scripts, and it is what makes the check get used during a docs edit
rather than only at the end.

---

## Verification bar

Onboarding quality resists automated testing, so verify what can be verified and be explicit
about the rest.

**Automated (CI):**

- `./ci.sh` green; lesson snapshots byte-exact.
- The doc-integrity script above (standalone + a `./ci.sh` phase): no dead links, no dead
  anchors, no orphan documents, section map round-trips, `error_codes.ml` anchors resolve.
- The lesson-structure tests from D5: unique numbers, no gaps, declared prerequisites exist,
  every lesson in exactly one track, the featured seven declare none, no hand-typed counts
  anywhere.
- **The cold-start test.** In a clean container: install → `tesl init --yes` → `tesl run` →
  `curl` → assert 200. This is the real onboarding regression test — it is the thing that
  silently broke in defect 1, and it is the promise the one link makes.
- **The maintainer cold-start test.** From a clean checkout: enter the dev shell →
  `cd compiler && dune build` → `./ci.sh` green. Same argument as above, for the other audience.
  If the documented maintainer path is not executable in CI, it will rot exactly the way the
  user path did.

**Human — OUT OF SCOPE for this item (2026-07-29).**

The newcomer trials (three people, one link, no help, screen-shared; one of them running the
maintainer ramp instead) remain **the only honest measure of whether this item worked** — an
automated gate can prove the docs are internally consistent, never that they teach. But they are
run by the maintainer outside the roadmap, so they are not a deliverable here and their absence
does not block this item from closing.

Recorded rather than deleted, because the *reason* they matter is still true: no CI phase can tell
you where a reader stalls.

---

## Settled (2026-07-29)

| Question | Decision |
|---|---|
| `TESL.md` | **Fold into the README and delete.** Drop its key from `gen_docs.ml`'s root-doc list, and grep for inbound links at implementation time — the doc-integrity check (below) will catch any that are missed |
| `example/intro/` | **Clean move** to `manual/intro/`. Embedded-doc keys and `tesl help manual intro` resolution move with it |
| Lesson metadata format | **Header comment, not a sidecar.** Lessons stay self-contained and greppable; a sidecar is one more thing that can silently disagree with the directory |
| Static site (Phase 3) | **In scope.** Keep it a pure build artifact with no hand-maintained content, so a stale site is impossible rather than merely unlikely |
| `js_of_ocaml` timing | **After Phase 2, or in parallel with Phases 2–3.** It shares no files with the docs work; only Phase 3's inbound link couples them, and that goes last |
| `lesson64` | **Renumber the tail.** Do it in Phase 1, before generated indexes and before Phase 3 mints permalinks |
| Maintainer ramp location | **`CONTRIBUTING.md` at the repo root**, as a router; `dev-docs/` holds the content |
| The worked maintainer change | **`W020`, module name not UpperCamelCase** — five graded real defects in fifteen lines; start with the missing machine-applicable fix |
| Lesson curation | **Keep all 75** (they are regression tests too); **feature seven** — `lesson00`, `05`, `12`, `14`, `18`, `68`, `72` — as the impatient reader's why-Tesl showcase |
| The lesson sequence | **Reading order is value order** — DONE, and it lives in per-lesson metadata rather than in filenames, so a future reorder is a metadata edit and the 75-file rename was **not** needed (see `roadmap/completed/`). Splits: **discarded**, candidates recorded in `roadmap/discarded/lesson_splits.md` |
| Standing alone | **Generated cold-entry blocks**, built from the D5 prerequisite metadata — no hand-duplicated context, nothing to keep in sync, and it works for every lesson rather than only the seven |
| Doc-integrity check | **Its own script, invoked by a `./ci.sh` phase** — standalone for fast feedback, in the gate so it cannot be skipped |
| Site hosting | **The forge's own static pages, no domain.** Keep the generator host-agnostic and keep the README as the canonical link, so the planned forge move costs a CI-config change and no abandoned URL |

## Open questions

1. **Numbers in filenames, or ordering in metadata?** (D5.) The one decision that must be made
   *before* Phase 1 starts, because it determines whether the reorder is paid once or forever.
   Recommendation is metadata; the cost is one large rename and the loss of the "I'm on lesson 12"
   affordance, mitigated by displaying the sequence number in the generated index and the site.
2. **What is the new order?** The reorder is mechanical; deciding the sequence is editorial and
   needs one opinionated pass. Do it as a list first, review the list, *then* run the script —
   not the other way round.
3. ~~**Which lessons get split?**~~ **Answered by discarding it** — see Phase 2 and
   `roadmap/discarded/lesson_splits.md`. Six candidates were identified with evidence; none is
   being split.

---

## Related

- `roadmap/discarded/make_thesl_home_page.md` — the homepage decision this deliberately does not
  reopen
- `roadmap/discarded/online_editor_to_drive_adoption.md` — the playground analysis; D7 revisits
  only the half it did not cost out
- `roadmap/completed/combine_qa_scripts.md` — why there are three names for one gate (defect 10)
- `dev-docs/README.md` — the maintainer entry point D6 rewrites
- `roadmap/discarded/language_distribution.md` — Path E (playground) and the non-Nix
  distribution question that caps what onboarding can achieve
- `roadmap/completed/architecture_trajectory.md` — ARCH-ADOPTION; the deferred adoption-path
  decision this item borders on
- `manual/anchors.md` — the anchor stability contract any reshuffle must honour
- `AGENTS.md` — the parallel agent-facing journey
