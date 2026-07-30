# Playground polish — making the browser checker persuasive

> **Status: IMPLEMENTED 2026-07-30.** All nine items shipped, plus a theme toggle
> (System/Light/Dark, persisted) that was not in this list. The verification bar is met:
> `playground/build.sh` still emits static files with relative paths only and no CDN, the
> artifact is **1 130 679 B raw / 360 776 B gzipped** against the workflow's 2 MB ceiling
> (the `teslExplain` export cost **+640 B raw / +288 B gzipped** — `Embedded_docs` is still
> not linked, as item 3 demands), and the parity assertion is now **wired into CI** as
> `scripts/playground-parity.sh` (ci.sh phase 19, `TOTAL_PHASES` 18 → 19), measuring
> **29/30 byte-identical over the first 30 lessons with `lesson07-consumer.tesl` as a named
> exception** — asserted to keep failing loudly rather than tolerated by a fuzzy threshold.
> Verified in headless Chromium: 56 assertions, including that Apply round-trips
> (fix → re-check → the diagnostic is gone), that both editor layers share every computed
> text metric, and that a 375 px viewport never scrolls horizontally.
>
> **The one decision taken against this file: no CodeMirror 6, and no editor library at all.**
> Item 1 permitted CM6 "only if that makes it easier". It does not. Bundling it needs a JS
> toolchain the repo does not have (build.sh needs only js_of_ocaml and python3), it would
> break "static files, relative paths, no CDN", and Tesl has no CM6 language mode so a
> tokenizer had to be hand-written either way. What shipped is a zero-dependency
> `<textarea>` over a highlighted `<pre>` underlay plus a gutter — which also keeps item 7's
> accessibility bar intact, since a textarea has native selection, undo and screen-reader
> support that a `contenteditable` gives up. The tokenizer's keyword table is transcribed
> from `compiler/lib/lexer.mll` rather than guessed; its approximations (no state across
> lines, contextual SQL/route words coloured as keywords) are commented in place.
>
> Two things worth knowing that this file did not anticipate: a bare `pre { max-height }`
> rule for the artifact panes also matched the underlay, clipping the highlight layer so
> squiggles below the fold drifted from the text (now scoped to `#artifacts pre, #diags pre`);
> and `EXAMPLES[1]`'s proof error carries no machine-applicable fix, so item 4's "make Apply
> the obvious next click" also offers example 3, which has one.
>
> **Original planning notes follow, unedited** — except the cross-reference in item 1 of
> *The runnable version*, where `playground/README.md` § *Not wired into CI* is now
> § *Wired into CI: the parity assertion*.

> **Status:** Next · **Effort:** S for the first three items, M for the whole list. Every item is
> independently shippable and none needs a backend.
>
> **Scope: the CHECKING playground only.** Running a Tesl program in the browser is a separate,
> much larger decision — see [The runnable version](#the-runnable-version) at the bottom, which this
> item deliberately does not presume either way.

Carved out of `roadmap/completed/revised_onboarding.md` Phase 3 (2026-07-29), which is otherwise
complete. Phase 3 asked for a static site "generated from the same markdown … lessons rendered with
syntax highlighting and a stable permalink each, the spine as the nav, search over the same corpus".
What shipped instead was better on the lesson half and absent on the docs half:

| Phase 3 wanted | Outcome |
|---|---|
| a stable permalink per lesson | ✅ `playground/lessons.html`, all 77, each opening in the checker with its source loaded |
| "a homepage listing all the lessons" | ✅ same page |
| forge static pages, no domain, host-agnostic | ✅ `.github/workflows/playground.yml` is a thin caller over `playground/build.sh` |
| the manual rendered as HTML, spine as nav, search | ❌ **not built, and deliberately not going to be** — the forge already renders `manual/*.md` with highlighting and provides search over the repo, so a second copy would need its own generator, its own staleness story and a markdown renderer the tree does not have. D1 already makes the README the spine |
| lessons rendered **with syntax highlighting** | ❌ the source lands in a plain `<textarea>` — item 1 below |

So Phase 3's genuine remainder is one polish item on the playground, not a site project. This item is
that remainder plus the rest of what would make the page actually convert a visitor.

---

## What the playground is today

`teslCheck(source) → JSON` — the compiler compiled to JavaScript (1.07 MB raw / 351 KB gzipped,
5–65 ms warm), reusing the *same* `Compile.check_source` + `Linter.lint_file` pair and the *same*
`diag_to_json` serializer as `tesl --check-json`, so diagnostics are byte-identical to the CLI's.
The page has: a `<textarea>`, an examples dropdown, Check, Copy-share-link, a link to all lessons,
diagnostics with stable code + precise span + message + machine-applicable **fix with a working
Apply button**, and the generated Racket / TypeScript / Elm.

That is already the whole thesis — *"paste this, watch the compiler refuse to let an unvalidated
string reach the database"* — and it does not execute anything.

---

## The items, in value order

### 1. Syntax highlighting and a real editor gutter — Phase 3's remainder

A `<textarea>` is the weakest part of the page. A visitor's first impression of a language is partly
typographic, and unhighlighted code reads as unfinished.

**The constraint that decides the approach:** diagnostics carry a **precise span**
(`line`/`col`/`end_line`/`end_col`, 0-based) and a machine-applicable fix. Those are wasted on a
textarea, which cannot underline a range or put a marker in a gutter. So the win is not decoration —
it is *making the span visible*, which is the compiler's whole selling point.

- Squiggle the exact range, not the line.
- Gutter markers, click-to-jump from the diagnostic list.
- Hover a squiggle to see the message and the fix title.

**CodeMirror 6**. Use codemirror 6 if appropiate but only do that if that makes it easier to achieve the goals below. Do not use Monaco. We will probably keep a lightweight (this) way to share and inspect code even if we build a full playground with DAP debugging (probably built on Monaco) in the future.

### 2. Check as you type

Warm checks are **5–10 ms** for a snippet and 50–65 ms for a 500-line lesson. That is well inside
interactive budget, so the Check button is an unnecessary step that hides how fast the compiler is.
Debounce ~300 ms, keep the button for the keyboard-averse.

This is the cheapest item with the largest perceived effect: a proof error appearing *as you delete
the validation* is a fundamentally different demonstration from one that appears after a click.

### 3. Explain the error, in place

Every diagnostic has a stable code and `tesl explain <CODE>` prose — the language's own pitch is
"the compiler tells you exactly what is wrong", and right now the page shows the code without the
explanation.

`Error_codes.explain` is in the compiler library and is **already in the bundle**. Export a second
function (`teslExplain(code)`) and render it in a disclosure next to the diagnostic. No new content,
no size cost, and it closes the loop the README opens.

**Careful:** do NOT wire up `tesl help manual <section>#<anchor>`. That means linking
`Embedded_docs`, which triples the artifact — measured: 1 127 187 B → 3 424 269 B. If the manual is
ever wanted in the page, fetch it as a separate lazily-loaded file. The workflow's 2 MB ceiling
enforces this.

### 4. A guided first failure, on the landing page

The four preloaded examples are behind a dropdown, so a first-time visitor sees an empty editor and
has to decide what to type — the same "blank page" problem the onboarding item fixed for
`tesl init`.

Land on the **proof-error example already loaded and already checked**, with one line of framing:
*"this program does not compile, and here is why."* Make the fix's Apply button the obvious next
click. That is the 30-second version of `manual/first-change.md`.

### 5. Deep-link into a lesson at a position

`lessons.html` links a lesson's whole source. A lesson's *interesting line* is what a tutorial or a
forum answer wants to point at. The share fragment already carries the source; add an optional
cursor/selection so `#z…` can also say "and look at line 42".

### 6. Honest framing of what it cannot do

The page says "checks only — nothing is executed, no server involved" in the header, which is easy to
miss. A visitor who types an `api` block and looks for a Run button should be told, at that moment,
what the checker does and does not do — and pointed at `tesl init` for the real thing. A limitation
stated confidently reads as a design decision; one discovered by the visitor reads as a missing
feature.

### 7. Accessibility and mobile

The current layout is two side-by-side panes. Most inbound links from chat and social are opened on a
phone. Stack the panes under a width breakpoint; keep the editor keyboard-navigable; do not trap
focus in a `contenteditable` if item 1 uses one.

### 8. Updated looks

Make it look nicer and more like a shipped product

### 9. Only show the Typescript and Elm when relevant

Only show the generation tabs when something actually is being generated (a server is present) instead of the "empty"

```elm
module MissingImport exposing(..)
{- Generated by tesl generate elm from MissingImport.tesl — experimental client generation, do not edit by hand -}

import Http
import Json.Decode as D
import Json.Encode as E
```
```ts
// Generated by tesl generate ts from MissingImport.tesl — experimental client generation, do not edit by hand
// Module: MissingImport
import { z } from "zod";"
```

---

## Explicitly not in this item

| | Why |
|---|---|
| **Running Tesl programs** | see below — a different decision of a different size |
| Monaco | ~5 MB against a 1.07 MB compiler; see item 1 |
| The manual rendered into the site | the forge already renders and searches it; the README is the spine (D1) |
| Accounts, saved snippets, a share backend | the fragment is the storage. No backend means no moderation surface, no abuse handling, no data to lose |
| A domain | still the recurring obligation `revised_onboarding.md` D1 declines. The README stays the canonical link |

---

## The runnable version

**Not decided here, and this item is written so it does not prejudge it.**
`roadmap/discarded/online_editor_to_drive_adoption.md` costed it out and it was discarded on the
strength of the hard part: running a Tesl program needs Racket, PostgreSQL, and a sandbox per
session. That analysis explored two shapes — a container-per-session backend with reverse-proxied
preview URLs, and a "zero-backend" browser approach with Service Workers / MSW intercepting the
API and SSE traffic. Both are still the right starting points if it is revisited, and the SSE
visualiser it describes ("write a `publish`, POST from the mini-client, watch the event card land")
is genuinely the most persuasive demo Tesl could have.

**What has changed since that discard, and what has not.** Changed: the compiler now demonstrably
runs in the browser, so the *checking* half is no longer hypothetical and the front end, the share
format and the lesson catalog would all be reusable. Unchanged: **execution is still the expensive
part**, and every cost in that document — sandboxing arbitrary code, per-session resource limits,
outbound network restriction, abuse handling, and an operated service where there is currently none —
is still there in full.

**Three things this item does to keep that door open, at no cost:**

1. **Keep `teslCheck` the only compiler entry point, and keep its output the CLI's `diag_to_json`
   shape.** A server-run version needs a *different* transport, not a different contract. The moment
   the page grows a bespoke diagnostic format, the two implementations start to drift — and the
   parity assertion (`tesl --check-json` vs `teslCheck` on a fixture set, in
   `playground/README.md` § *Wired into CI: the parity assertion* — renamed from § *Not wired into
   CI* when it was) is what would catch that. Wire it up. **Done: `scripts/playground-parity.sh`,
   ci.sh phase 19.**
2. **Keep the share fragment the only way source enters the page.** A run button would need to send
   source *somewhere*, and "the fragment is the source of truth" is the property that makes that a
   transport change rather than a redesign.
3. **Do not build UI that a runnable version would throw away.** Specifically: no mini API client, no
   SSE panel, no request/response pane. Those belong to execution and are the *good* part of the
   discarded design — building inert mockups of them now would be work discarded twice.

**If it is revisited, the honest sequencing question is not technical.** The blocker is that it turns
a repo with no operated services into one with a service to run, secure and pay for, and
`roadmap/completed/architecture_trajectory.md` deliberately carved the adoption path — playground,
homepage, package manager, non-Nix distribution — to a later decision. That decision, not the
engineering, is what to make first.

---

## Verification bar

- `playground/build.sh` still produces **two static files with relative paths only**, and the
  artifact stays under the workflow's 2 MB ceiling. Any item that adds a dependency reports its size
  delta.
- **The parity assertion exists and runs**: `tesl --check-json` and `teslCheck` agree on
  `(code, severity, source, line, col, message, fix)` over a fixture set. The spike measured 29/30
  byte-identical across real lessons, with the one difference being the documented single-buffer
  limit failing loudly — that is the number to hold, and it is the check that catches silent
  divergence between the browser and the CLI.
- Every diagnostic the page renders shows its **stable code**, and Apply still round-trips (apply →
  re-check → the diagnostic is gone), matching the compiler's own apply-and-recompile invariant.
- `lessons.html` still links **every** lesson, asserted against the corpus count.
- The page is usable on a 375 px viewport and with the keyboard alone.
- No item introduces a backend, an account, or a stored snippet.

## Related

- `roadmap/completed/revised_onboarding.md` — Phase 3 (complete) and D7, which argued the check/run split
  this item inherits
- `roadmap/discarded/online_editor_to_drive_adoption.md` — the runnable design, still the right
  starting point if that decision is revisited
- `roadmap/discarded/make_thesl_home_page.md` — the homepage decision this does not reopen
- `roadmap/completed/architecture_trajectory.md` — ARCH-ADOPTION, where the "should we operate a
  service" decision actually lives
- `playground/README.md` — what exists, the measured sizes, and the CI phase the parity assertion
  wants
