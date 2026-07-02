# Documentation improvements

> **STATUS: CLOSED (2026-07-01).** This is the documentation program record. The
> P0 "stop active misleading" fixes and the first self-defending checks were
> executed this pass; the larger restructure/enforcement items are carried over
> into **`roadmap/later/documentation_backlog.md`** with the maintainer decisions
> baked in — nothing actionable remains in `roadmap/next/`.
>
> **Shipped this pass (verified: doc-guard tests + `./compile-examples.sh` green):**
> - **D1** — the GETTING-STARTED first program was a parse error on line one
>   (`predicate … where`, `--` comments, bare imports, `Tesl.Db`, `impl … on 8080`);
>   rewritten to valid, compile-verified Tesl modelled on `lesson15`/`lesson16`.
> - **D3** — "unbreakable"/"production-ready" retired (TESL.md H1 + tagline,
>   overview.md, intro title); pivoted to the calibrated AI-first framing. TESL.md:5
>   disclaimer kept.
> - **D8a** — banned-phrase lint added (`test_embedded_docs.ml`) so the tagline
>   cannot silently resurface.
> - **D4** — Docker status contradiction resolved (README was correct; `INSTALL.md`
>   was the stale line — fixed, plus its broken roadmap link).
> - **D5 (partial)** — README step numbering + drifting example-list fixed.
> - **D6** — the two duplicate manual indexes collapsed (`manual/index.md` deleted).
> - **D7 (partial)** — examples.md dead lesson23/24 links + duplicate ordinals fixed.
> - **D9 (partial)** — the two bogus by-line `§` citations fixed.
> - `embedded_docs.ml` regenerated so the compiled-in docs match.
>
> **Carried over →** `roadmap/later/documentation_backlog.md`: D2, D8b/c/d, D9-full,
> D10, D11, D12, D13, D14, D15 (incl. the ID-3 "why a language" thesis), D16, D17,
> D7-full.

## Background

Information about the project lives in many places — `README.md`, `TESL.md`, `LANGUAGE-SPEC.md`,
`INSTALL.md`, the CLI manual (`manual/`), two tutorial tracks (`example/learn/` code lessons and
`example/intro/` prose), `tesl init` scaffolds (`templates/`), contributor docs (`dev-docs/`),
tooling docs (`editor/`, `AGENTS.md`), and the decision log (`taken_decision.md`). Having different
material for different readers is good and intended. But today it is verbose, hard to get an overview
of, duplicated across surfaces that have already drifted apart, and in places it is uncertain how
helpful — or how *correct* — the text actually is.

## Goal

Analyze the documentation sources and how they relate, then move to a structure that is:

- **comprehensive** — no correct, uniquely-housed information is lost (only the outdated/wrong/misleading);
- **as small as possible** — but the honest target is **smaller *drift surface***, not smaller file
  count: collapse duplicated facts and crossed funnels (a code-level audit shows file count barely
  changes; the win is one canonical home per fact and one door per audience);
- **audience-fit** — each distinct reader meets exactly one obvious entry point and path, in the style
  that suits them;
- **honest** — the calibrated alpha voice (README + SPEC) used everywhere; USPs communicated without
  inflation; status *and* direction stated once and clearly;
- **crisp, friendly, welcoming, constructive — no fluff.**

This item is the *systematic* program. Specific instances already flagged in the reviews are being
handled; the value here is the durable structure and the disciplines that stop the doc-problem
**classes** from recurring.

---

## Root diagnosis — the same generator as the stability work, plus a docs twist

The dominant generator is identical to `stability_and_robustness.md`'s:

> **A single fact is hand-authored in N surfaces instead of having one canonical home, so editing it
> means editing N files and any miss is silent drift.**

Two docs-specific properties make drift *silent* rather than loud:

1. **Doc code and claims are largely ungated.** Only `.tesl` files are compile-checked
   (`compile-examples.sh` globs `*.tesl`; the doctest extractor `parser.ml:4858` is `.tesl`-only).
   Roughly **267 ` ```tesl ` blocks in prose docs are never compiled**, so they rot. This is the docs
   analog of "no runtime backstop": nothing fails when a doc goes wrong.
2. **Positional/identity references are used as an API without a contract.** The manual's
   `section#anchor` deep-links *are* contracted and test-guarded (the strength to generalize), but the
   spec's `§`-numbers — cited 32× from compiler code, plus two by-*line*-number cites — are not.

A live, self-verified proof that fixing instances doesn't close the class: the "unbreakable /
production-ready" honesty fix landed on `TESL.md`, but the **same claim is still live in
`manual/overview.md:3`** — which is compiled into the binary via `embedded_docs.ml` and served by
`tesl help manual overview`. Meanwhile `README.md:3` already uses the calibrated voice. One sentence,
three surfaces, three honesty levels.

### What is genuinely solid (build on it, don't reinvent)

- **A real single-source pipeline already exists.** `compiler/gen/gen_docs.ml` bakes `manual/*.md`,
  `dev-docs/*.md`, the four root docs, and `example/**/*.tesl` + `example/learn/*.md` into
  `embedded_docs.ml` via a `(mode promote)` dune rule — so `git diff` reveals any un-regenerated copy.
- **Contracted, test-guarded anchors.** `manual/anchors.md` + `manual/tests/test_embedded_docs.ml`
  (anchor resolution, section map, *and* a stale-proof-wording scan) + `test_error_codes.ml` (every
  diagnostic's `section#anchor` resolves to a real heading). This correspondence-test pattern is
  exactly the discipline to extend to the surfaces it doesn't yet cover.
- **A diagnostics → docs deep-link scheme** (`error_codes.ml` emits `manual = Some "overview#core-principles"`
  etc.). This is a differentiator; preserve it.

---

## The documentation problem-classes and the discipline that removes each

### C1 — One fact hand-copied across N surfaces (drift-by-copy)

Verified instances: the **proof-cost model** told 5× (`best-practices.md:204-240` — which itself admits
a 3-way hand-sync — plus `overview.md:172-178`, `GETTING-STARTED.md:288-296`, `FAQ.md:468-484`,
`TESL.md:40/543`); **install** told 4×; the **lesson count** disagreeing in every copy (71 real;
`"53"`/`"70+"`/`"50+"`); the **feature-status checklist** in `overview.md:184-215` duplicating the
roadmap; and an outright **contradiction** — `README.md:42` shows `tesl build --with-postgres` as a
working command while `INSTALL.md:187` lists "Docker image — not done." Honesty inflation is a special
case of this class (the "unbreakable" claim, copied and diverged).

**Discipline:** one canonical home per fact; every other surface **links or transcludes/generates** from
it, never re-types it. Counts are *computed*, never typed. **Enforced by** the existing `gen_docs` +
`(mode promote)` pipeline (git-diff tripwire on `embedded_docs.ml`) plus coherence-test assertions that
curated literals equal their generated source.

### C2 — Ungated prose code blocks and claims rot silently

The highest-trust newcomer doc, `manual/GETTING-STARTED.md:138-141`, teaches a first program using
`predicate … where` (no `.tesl` file uses `predicate`; the real keyword is `fact`), `--` comments
(real Tesl uses `#`), and port `8080` (vs `8086` everywhere else) — a parse error on line one.
~267 ` ```tesl ` blocks across README/TESL/SPEC/manual/dev-docs/intro are unverified.

**Discipline:** every shipped Tesl block is either compile-gated or explicitly opted out
(` ```tesl,ignore ` for deliberately partial fragments); teaching surfaces prefer **transcluding** from
already-gated `example/learn/*.tesl` over inline code. **Enforced by** extending `compile-examples.sh`
(the authoritative green-check) with a markdown-fence extractor that runs each block through
`tesl validate`; a non-ignored block that doesn't compile fails the build.

### C3 — Two artifacts serve one audience, so neither is the obvious path

Two manual indexes both titled "# Tesl Manual" (`manual/index.md` + `MANUAL.md`, only the latter
CLI-wired); the pitch authored 3× (README / TESL.md / overview.md) at three calibrations; editor setup
told 3× (README / `editor/README.md` / `editor/vscode-tesl/README.md`) with none canonical; the MCP tool
catalog told 2×; the agent door (`AGENTS.md`) reachable only as a scaffold artifact, not a funnel entry.

**Discipline:** exactly one canonical artifact per (audience, topic); peers collapse to a one-line link.
**Enforced by** a coherence assertion that exactly one `manual/*.md` is an index and it equals the
CLI-resolved one (`compiler/bin/main.ml:215`), and the audience map below (one door each).

### C4 — Internal/contributor docs leak into the user funnel

`README.md:115-140` splices the full contributor build/test workflow (`nix develop`, `dune`, `ci.sh`)
*between* the user pitch and "try the language today"; `dev-docs/deploy.md` is a pure end-user deploy
guide that `README.md:49` deep-links users into; `dev-docs/tesl-manifest.md` is the user-facing
`tesl.toml` schema; `taken_decision.md` (a branch-scoped maintainer log) sits at the repo root beside
README/TESL/INSTALL.

**Discipline:** a four-way partition — **USER / CONTRIBUTOR / TOOLING+AGENT / DECISION-LOG** — with one
door each and no funnel crossing a partition; every doc opens with an explicit `Audience:` banner
(model: `dev-docs/zero-cost-proofs-contract.md:3`). **Enforced by** a net-new scanner (does not exist
today) asserting each `dev-docs/*.md` carries the banner and `README` contains no `dune`/`ci.sh`
instructions (link only).

### C5 — Mixed Diátaxis kinds under one cover

`LANGUAGE-SPEC.md` interleaves normative semantics (§6-7, the test suite's authority) with product
pitch/lineage (§2-3) and feature-tour walkthroughs whose syntax is re-typed in TESL.md;
`best-practices.md` embeds a ~660-line testing *reference* (384-1045) inside a how-to; `GETTING-STARTED`
mixes tutorial + concept + CLI reference; `FAQ` re-teaches GDP/capabilities the spec/overview own.

**Discipline:** assign each page exactly one job — *explanation* (overview), *tutorial/how-to*
(getting-started), *reference* (a dedicated testing section + the spec), *how-to patterns*
(best-practices), and strip from each page what another now owns. **Enforced by** the canonical-source
map + the link-resolution coherence test.

### C6 — Hand-typed indexes/catalogs over a generated, growing tree

`manual/examples.md` has duplicate ordinals, curates ~24 of 71 lessons, and links to
`lesson23-queues-and-workers.tesl` / `lesson24-pubsub-sse.tesl` that don't exist (wrong filename — only
`.md` siblings exist; the real `.tesl` files at 23/24 are *different* topics). `gen_docs.ml` does **not**
walk `example/intro/`, so the prose track is invisible to the CLI while the code track is embedded —
asymmetric discoverability. Two tutorial tracks with no stated relationship.

**Discipline:** generate the lesson/example index from the filesystem (each file's own header is the
source); never hand-type a count or list. **Enforced by** extending `gen_docs.ml` (it already has
`walk_dir`) + a coherence check that every `example/learn/*.tesl` and `example/intro/*.md` appears in
the generated index, no listed file is missing, and `example/learn/` holds only uniquely-numbered
`lessonNN-*` files (catches the genuine 07/62/63 collisions and a stray `tesl-lsp-*.tesl`).

### C7 — Position-as-API with no stability contract

`§`-numbers are cited 32× across `compiler/lib` + `compiler/test` (e.g. §7.12 ×17), plus two brittle
by-*line*-number cites (`test_review31_antagonistic.ml:130,252`, already drifted). Reordering the spec
silently breaks them — unlike the manual anchors, which are test-guarded.

**Discipline:** treat spec `§`-numbers as a published, contracted API; ban by-line-number citation.
**Enforced by** a build-failing test that every `§` cited in compiler code resolves to a real
LANGUAGE-SPEC heading — the proven `test_error_codes.ml` correspondence pattern, generalized. Keep the
spec **one physical, citable file**; add a generated TOC + per-heading anchors for navigability without
fragmenting it.

---

## Target information architecture

### One door per audience (no funnel crosses a partition)

| Audience | One entry point | Path |
|---|---|---|
| **Evaluator / skeptic** | `README.md` (GitHub front page) | 60-sec pitch → Alpha status + Current state + Non-goals (the calibrated voice) → Who-for → `example/intro/` prose tour → deeper tour (retargeted TESL.md) |
| **Newcomer building first API** | `README` Quick start → `INSTALL.md` | install → `tesl init` → read the generated, *compiling* `app.tesl` → slimmed `GETTING-STARTED` (init + check/run loop) → `example/learn/` (generated index) |
| **Working user** | `tesl help manual` → `MANUAL.md` (the one CLI-wired index) | task-first index → `best-practices` how-to (cited anchors) → a dedicated testing section → diagnostics deep-link to `section#anchor` → `LANGUAGE-SPEC` for exact semantics → `FAQ` |
| **AI coding agent** | `AGENTS.md` (linked from the README funnel) | core loop + JSON query flags + `debug-inspect` → links to `editor/tesl-mcp/README.md` (MCP tools) and `editor/protocol.md` (envelopes) → `tesl help manual full` |
| **Language contributor** | `dev-docs/README.md` | contributor index (must list *all* dev-docs) → `01-overview` pipeline/layout → internals → `09-adding-tests` + `compile-examples.sh` → relocated decision log |
| **Editor/tooling integrator** | `editor/vscode-tesl/README.md` (one door — not also `protocol.md`) | user setup → `editor/protocol.md` as downstream reference contract |

### Canonical home per topic (everything else links/transcludes)

- **Pitch / USP** → `README` (60-sec frame). TESL.md tour, overview.md, SPEC §1-3 link to it.
- **Status + direction** → `README` Alpha/Current-state (calibrated) + `roadmap/` (granular) +
  `INSTALL.md:179-189` (supported / not-yet matrix, the single status authority for Docker etc.).
- **Install** → `INSTALL.md`. **Getting started** → `manual/GETTING-STARTED.md` (around real `tesl init`).
- **Concept explanation** → `manual/overview.md` (one-screen; **keeps the `overview#core-principles`
  anchor**). **Precise semantics** → `LANGUAGE-SPEC` §6-7.
- **How-to / recipes** → `best-practices.md` (owns its cited anchors). **Proof-cost model** →
  `LANGUAGE-SPEC` §4.3/§7.10 (table transcluded into `best-practices#proof-cost-model`).
- **Tutorial** → `example/learn/` (code) + `example/intro/` (prose); index **generated**.
- **Normative reference** → `LANGUAGE-SPEC` (one physical file). **Agent API** → `AGENTS.md`.
- **Editor** → `editor/vscode-tesl/README.md` (user) + `editor/protocol.md` (contract).
- **Deploy + `tesl.toml`** → user/manual path (rehomed from dev-docs). **Decision log** → beside `roadmap/`.

---

## Durable disciplines

1. **One canonical home per fact; everything else links or is generated.** Enforced by `gen_docs.ml` +
   `(mode promote)` + git-diff tripwire + coherence assertions that literals equal their generated source.
2. **Compile-gate every shipped Tesl block** (extract markdown fences in `compile-examples.sh`;
   ` ```tesl,ignore ` opt-out). Prefer transclusion from gated `example/learn/*.tesl`.
3. **One calibrated voice, lint-enforced.** Extend the existing stale-wording scan (currently
   `manual/`-only) to `TESL.md` + `overview.md` with a banned-phrase list (`unbreakable`,
   `production-ready`).
4. **Positional refs are contracted.** Manual anchors (already) + a new spec-`§` resolution test;
   by-line-number citation banned.
5. **Indexes/catalogs are generated from the tree, never hand-typed** (count, lesson list).
6. **One door per audience + `Audience:` banner**, with a coverage test that every `manual/*.md` is a
   registered CLI section or an explicit allowlist exception, and every `dev-docs/*.md` carries a banner.
7. **Anchor-safety precondition (sequencing rule).** No heading backing a row in `anchors.md` or a
   `manual = Some "…#…"` in `error_codes.ml` may be cut or moved without migrating the anchor **in the
   same change** — *add the new anchor + register it, then move content, never the reverse.* Already
   enforced by `test_error_codes.ml` + `test_embedded_docs.ml`; make the sequencing explicit so cuts
   don't redden the build.

---

## Actionable program (prioritized)

Format: **ID — action** · *closes* · **enforced by** · effort. (Incorporates the adversarial review's
corrections: selective trims not wholesale deletes, correct file paths, anchor-safety first.)

### P0 — stop active misleading + lock the safety preconditions

- **D0 — Anchor-safety precondition (blocks every cut/move below).** Inventory the contracted anchors
  (`overview#core-principles` at `error_codes.ml:86`; `best-practices#{validation-patterns,
  proof-management, proof-cost-model, api-design, database-access, error-handling, testing}`; `faq#…`);
  any reshaping migrates the anchor first. · *Prevents reshaping from breaking diagnostic deep-links /
  the build.* · **enforced by** existing `test_error_codes.ml` + `test_embedded_docs.ml`. · S
- **D1 — Fix `GETTING-STARTED.md` first program** (`predicate→fact`, `--`→`#`, `8080`→`8086`), sourcing
  the example by transclusion from a gated lesson. Do **not** delete concept text backing an anchor. ·
  *C2, C5.* · **enforced by** D2's fence gate. · M
- **D2 — Compile-gate prose code blocks.** Extend `compile-examples.sh` with a ` ```tesl ` fence
  extractor over README/TESL/INSTALL/manual/dev-docs/intro (~267 blocks); ` ```tesl,ignore ` opt-out;
  build fails on a non-ignored block that won't compile. · *C2.* · **enforced by** the authoritative
  green-check gate. · L
- **D3 — Retire "unbreakable"/"production-ready"** from `TESL.md` (H1:1, tagline:10, line 3) and
  `overview.md` (3, 136-138); keep `TESL.md:5`'s honest disclaimer. · *C1 (honesty).* · **enforced by**
  D8a banned-phrase lint. · S
- **D4 — Reconcile the Docker status contradiction.** Make `INSTALL.md:179-189` the single status
  authority; correct `README:39-49` (and its `:49` deep-link into `dev-docs/deploy.md`) to match, or
  update INSTALL if it shipped. Pick one truth. · *C1.* · **enforced by** INSTALL as status authority;
  README links to it. · S

### P1 — one canonical home, one door

- **D5 — README is the single landing pitch.** In `overview.md` delete only the duplicated pitch/problem
  framing (**keep** core-principles 70-92 — the contracted anchor); trim `TESL.md`'s inflated H1/tagline
  selectively (not 1-117 wholesale). Fix README step numbering (1,2,3,5,6) and replace the literal
  example-filename list (226-235) with a pointer to the generated index. · *C1, C3.* · **enforced by**
  canonical map + link-resolution test + D0. · M
- **D6 — Collapse the two manual indexes.** `manual/index.md` → 3-line stub (or cut); `MANUAL.md` is the
  sole index; merge its two section listings. · *C3.* · **enforced by** "exactly one CLI-resolved
  index" coherence assertion. · S
- **D7 — Generate `examples.md` + the lesson index** from `example/learn` + `example/intro`
  (`gen_docs.ml` already walks `learn/`); compute the count; fix the wrong-filename links (23/24 are
  valid distinct `.tesl` lessons — reconcile the `.md` naming, don't renumber); fix the genuine
  07/62/63 collisions and the stray `tesl-lsp-*.tesl`. · *C6.* · **enforced by** generation + index
  coverage check. · M
- **D8 — Add the coherence checks as explicit net-new code** (none of these exist today): (a)
  banned-phrase lint over `TESL.md`+`overview.md`; (b) `Audience:` banner required on every
  `dev-docs/*.md`; (c) `README` contains no `dune`/`ci.sh`; (d) every `manual/*.md` is a registered CLI
  section or allowlisted. · *C1, C3, C4.* · **enforced by** `test_embedded_docs.ml` extensions. · M
- **D9 — Spec `§`-citation resolution test** (highest-leverage net-new check): fail the build if any
  `§` cited in `compiler/lib`+`compiler/test` doesn't resolve to a LANGUAGE-SPEC heading; replace the
  two by-line cites; document the `§`-stability contract in `anchors.md`. · *C7.* · **enforced by**
  build-failing test; spec stays one physical file. · M
- **D10 — Single-source the proof-cost model + install + CLI flags.** Transclude the cost-model **table**
  from SPEC §4.3/§7.10 into `best-practices#proof-cost-model`; replace the 5 prose copies with a link
  *plus one audience-specific lead-in* (don't erase the approachable framing). Link `INSTALL.md` from
  GETTING-STARTED/FAQ/overview. Fix the live `tesl --fmt` vs `tesl fmt` / `tesl validate` vs
  `tesl check` contradictions by deferring to `tesl help`. · *C1.* · **enforced by** transclusion +
  existing freshness scan + a ban on duplicated install/flag blocks. · L
- **D11 — Split README's contributor half** (the "Two ways to use this repository" block 115-140) down
  to a single "Contributing? See `dev-docs/README.md`" link. · *C4.* · **enforced by** D8c. · S

### P2 — structure + audience partition

- **D12 — Retarget `TESL.md` into the manual as the single guided feature tour** (absorbing overview's
  unique content; deep theory → one theory page). Inventory overview's uniquely-housed content
  (Architecture; core-principles anchor) and give each a home **before** reducing it. · *C3, C5.* ·
  **enforced by** canonical map + transcluded gated examples + D0. · L
- **D13 — Four-way partition + `Audience:` banners.** Rehome `dev-docs/deploy.md` and the user half of
  `dev-docs/tesl-manifest.md` onto the user/manual path (this is a *move*, not a shrink); relocate
  `taken_decision.md` beside `roadmap/`; fix `dev-docs/README.md` to index all its files. · *C4.* ·
  **enforced by** D8b + the no-user-deep-link-into-dev-docs rule. · M
- **D14 — One agent door + one editor door.** Make `AGENTS.md` a README funnel entry and the single agent
  authority, linking to `editor/tesl-mcp/README.md` (MCP tools) and `editor/protocol.md` (envelopes)
  instead of re-listing them; designate `editor/vscode-tesl/README.md` the canonical editor-setup doc
  and reduce the other two to links. · *C1, C3.* · **enforced by** canonical map. · M
- **D15 — Generated TOC + published anchors for LANGUAGE-SPEC** (one `gen_docs.ml` step, no split);
  publish §7/§14b anchors in `anchors.md`; trim §2-3 pitch/lineage to a one-line scope + link. · *C5,
  C7.* · **enforced by** `gen_docs.ml` + the D9 resolution test. · M
- **D16 — Single-source the slug rule + section→file map.** Expose `Error_codes.slug_of_heading` and one
  section table as the sole implementations; have `test_embedded_docs.ml` (which reimplements the slug
  at line 91) and `test_error_codes.ml` import them. · *C1 (code-side registries).* · **enforced by**
  compile-time sharing (tests fail to build on drift). · M
- **D17 — Declare one newcomer journey** (install → first program → why/concepts → learn-by-code →
  build real project) in README + GETTING-STARTED, cross-linking `intro/` ↔ `learn/`; resolve the CLI
  asymmetry by walking `example/intro/` in `gen_docs.ml`. Be honest this leaves a *guided fork* (two
  complementary tracks), not a single path. · *C6.* · **enforced by** README/GETTING-STARTED journey
  section + `gen_docs.ml` intro walk. · S

---

## Decisions by the maintainer

1. **Fate of `TESL.md`** — (a) retarget into the manual as the guided feature tour *(recommended:
   strong content, no other connected-prose home; collapses 3 pitch surfaces to 1 landing + 1 tour)*;
   (b) keep at root but strip pitch/theory duplication; (c) distribute into per-feature manual sections.
   **DECISION**: Go with (a)
2. **One tutorial track or two** (`example/intro` prose vs `example/learn` code) — (a) keep both, declare
   one journey, cross-link, embed `intro/` in the CLI *(recommended — genuinely complementary)*;
   (b) `intro/` as repo-only on-ramp; (c) merge prose into lesson THEORY tiers and drop the track.
   **DECISION**: Go with (a), intro is the TLDR; version of the whole language, perhaps integrate/fold into tesl manual/tesl manual somehow.
3. **Who owns concept explanation** — (a) `overview.md` owns the end-user one-screen explanation, SPEC
   §6-7 owns precise semantics *(recommended — split by Diátaxis kind)*; (b) spec owns all; (c) collapse
   overview into the spec.
   **DECISION**: Go with (a)
4. **The "unbreakable" / "Joyfully unbreakable APIs" tagline** — (a) retire it everywhere *(recommended;
   it overstates exactly the property §7 bounds: compile-time-only, no runtime re-check)* + (c) adopt a
   calibrated tagline from README's framing; (b) keep but always pair with the trust-boundary caveat.
   **DECISION**: Retire the tagline, we should pivot to focus to the "ai-first" angle (not those words but something else)
5. **Decision-log location** — (a) relocate `taken_decision.md` beside `roadmap/` *(recommended)*;
   (b) fold resolved decisions into the roadmap items they close; (c) leave at root *(rejected — pollutes
   first impression)*.
   **DECISION**: (b) and remove the old taken_decision.md file
6. **Spec `§`-numbers: contract or migrate** — (a) contract `§`-numbers now with a resolution test
   *(recommended now)*; (c) migrate the 32 citations to named anchors opportunistically over time;
   (b) full migration now (larger, lower-urgency).
   **DECISION**: Go with (b)

---

## Exit criteria

1. **No doc actively misleads:** D1-D4 done; every shipped ` ```tesl ` block compiles or is explicitly
   `ignore`d (D2 standing in the gate).
2. **One canonical home per fact:** the canonical-source map holds; the proof-cost model, install, status,
   pitch, lesson index, and CLI-flag facts each exist once and are linked/generated elsewhere (D5-D10).
3. **One door per audience:** the audience map holds; two manual indexes → one; editor/agent doors
   singular; contributor flow out of the user funnel (D6, D11, D13, D14).
4. **The structure is self-defending:** banned-phrase lint, dev-docs `Audience:` banner check, manual
   section-coverage check, generated indexes, the spec-`§` resolution test, and the anchor-safety
   sequencing are all standing (D8, D9, D16) — so the classes turn a regression **red** instead of
   shipping silently.

> **On "smaller":** measured honestly, prose-file count barely changes — the program *moves* some files
> (deploy/manifest onto the user path) and *adds* enforcement code. The real, deliverable shrinkage is
> **duplicated facts** (3 pitches → 1+1; 5 cost-model copies → 1+links; 2 indexes → 1) and **crossed
> funnels** (one door per audience). State the goal as drift-surface reduction, which this delivers.
