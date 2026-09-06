# Tesl playground (browser)

The Tesl compiler, compiled to JavaScript, running in a browser tab. It
**checks** Tesl — parser, type checker, **proof checker**, capability and
validation passes, linter, and the Go/TypeScript/Elm emitters — and it shows
the diagnostics with their stable codes, precise spans and
**machine-applicable fixes**, squiggled on the exact range in a highlighted
editor, with `tesl explain <CODE>` prose in place.

It cannot **run** a Tesl program. See [What it deliberately cannot do](#what-it-deliberately-cannot-do).

Builtin discovery now ships through **Search builtins** (Ctrl/Cmd + K), the CLI
and MCP. See [search, sharing and verification](SEARCH.md) and the
[Elm/Monaco architecture](ARCHITECTURE.md). The original editor was the
Phase 4 outcome of `roadmap/completed/revised_onboarding.md` (D7).

---

## Published

`.github/workflows/playground.yml` builds and publishes this to GitHub Pages on
every push to `main`. The workflow is a **thin caller**: it enters the flake dev
shell, runs `playground/build.sh`, sanity-checks the artifact, and hands the
directory to Pages. All the build logic stays in the script, so a forge move
replaces the workflow's `on:` block and its two Pages steps — nothing else.

**The published URL is deliberately not cited anywhere in the repo.** Per
`roadmap/completed/revised_onboarding.md` D1 and Phase 3, the README stays the one
canonical link: a `*.github.io` address is a URL that has to be abandoned at the
planned forge move, and an abandoned URL is worse than no URL. This is a nicer
way to read and try the same content, not the entry point.

The workflow checks native/browser parity and Chromium interactions, as well as these artifact properties before deploying, and each corresponds to a real
regression rather than to "did it build":

| Assertion | The regression it catches |
|---|---|
| `teslCheck` is exported | the page loads and every check silently does nothing |
| `lessons.html` exists and links **every** lesson | a lesson lost its metadata header, or `python3` was missing and the index was skipped with only a warning |
| artifact < 2 MB | something referenced `Embedded_docs`, tripling the bundle (measured: 1 127 187 B → 3 424 269 B) |
| artifact > 200 KB | a truncated build |

## What the page does

| | |
|---|---|
| **Highlighting, gutter, squiggles** | the **exact** diagnostic range is underlined, multi-line ranges included; the gutter carries a severity-coloured marker per line; hovering a squiggle shows the code, the message and the fix title |
| **Click-to-jump** | clicking a diagnostic scrolls the editor to it, puts the caret on the range, selects it and flashes it (a static flash under `prefers-reduced-motion`) |
| **Check as you type** | 300 ms debounce, and the measured ms is shown. The Check button stays, and <kbd>Ctrl</kbd>/<kbd>⌘</kbd>+<kbd>Enter</kbd> checks immediately |
| **Explain in place** | every diagnostic has an *Explain `<CODE>`* disclosure carrying the same prose as `tesl explain <CODE>`, fetched on first open |
| **A welcoming first success** | a first visit starts with a runnable HTTP server; the invoice/customer rule is a second example. Three paths offer a runnable API guide, a quick fix, or discovery. Explicit intro visibility is remembered; shared links go straight to the source |
| **Honest framing, when it matters** | declaring a `server`, `api`, `handler`, `queue` or channel surfaces an inline note saying what *is* checked and what is not, pointing at `tesl init` / `tesl run`. Detected from declaration-leading lines; comments do not trip it |
| **Build or share next** | successful checks lead to a local run guide linking canonical installation instructions and explicit sharing; Save .tesl downloads the current source. These actions are distinct from verified installation or project activation |
| **Keyboard and mobile** | panes stack under 900 px and the page is usable at 375 px without sideways scrolling; a skip link, real list semantics for the diagnostics, buttons for every action, visible focus rings, and Tab moves focus rather than inserting a tab character |

## Editors inside the Elm application

Elm owns application state and views. The default native textarea keeps the
lightweight first visit, syntax overlay, compiler squiggles and mobile editing.
**Use IDE editor** loads Monaco locally on demand: find, folding, multiple
cursors, actual compiler quick fixes, and builtin hover/completion (Ctrl+Space).
**Use simple editor** switches back, preserving source and selection.

Search and lessons remain part of the custom workbench. Monaco is not a VS Code
extension host; its catalog suggestions are not scope-aware language-server
completion. Proof/capability requirements still apply. Monaco does not support
mobile browsers, so the native editor remains the default. Undo histories belong
to their editor instance and reset across editor switches.

See [ownership, ports, build and limits](ARCHITECTURE.md). The old inline
JavaScript application and separate Elm spike have been replaced by one
production Elm application. The compiler, type-search algorithm, share codec and
machine-applicable fix semantics retain their existing authorities.

**Themes.** System / Light / Dark applies to the application and Monaco. Only
this preference is persisted; source and search queries stay local in memory.

## The lesson index

`lessons.html` links every lesson into the checker, each with its source in the
share fragment, grouped by track in reading order. It is generated by
`gen-lessons-page.py` from the `# lesson:` / `# summary:` headers in each
lesson — the **same** single source `manual/lessons.md` is generated from, so the
two catalogs cannot disagree and adding a lesson needs no edit here.

It is a separate page rather than a picker inside `index.html` on purpose:

* the corpus is 750 KB raw / 190 KB gzipped, comparable to the entire compiler
  bundle — the embedded-manual measurement already showed what happens when large
  content rides along with the thing that has to load fast;
* every lesson gets a **stable permalink**, which is what Phase 3 actually asked
  for. A dropdown selection is not a URL you can send someone;
* it reuses the existing share-hash mechanism instead of inventing a second way
  for source to reach the playground.

Largest fragment: ~12 KB, for the 34 KB `lesson21-sql-reference` (raw deflate,
matching the browser's `CompressionStream("deflate-raw")`). Fragments are never
sent to a server.

One lesson is flagged in the index rather than silently broken:
`lesson07-consumer` imports a sibling module, and the browser checker works on
one buffer at a time.

## Build

```sh
nix develop                 # OCaml, js_of_ocaml, Elm, Node/npm and Python
playground/build.sh         # → playground/dist/ (verified static assets)
python3 -m http.server -d playground/dist 8000
```

A directory of static assets, all paths relative. Elm packages and pinned npm
build dependencies are downloaded on a cold build; runtime assets are local. Publishing is "copy `dist/` to any static
host" — no plugins, no Actions-only build logic, no assumption about the URL
prefix. Moving forge is a CI-config change, not a rewrite.

The dune target lives at `compiler/playground/` and is **gated on the release
profile** (`(enabled_if (= %{profile} release))`). Plain `dune build`,
`dune test`, `./ci.sh` and the nix derivation all use the *dev* profile, so none
of them touches it and a machine without `js_of_ocaml` still builds the compiler
normally.

An empty `(alias (name default))` override was tried first and **does not
work** — `Library "js_of_ocaml" not found` is raised while dune *resolves* the
rule, before any alias decides whether to build it, so `dune build` failed for
everyone lacking js_of_ocaml. `%{env:…}` would be the direct way to say "opt
in", but it requires `(lang dune 3.15)` and this project is on 3.0. The cost of
the profile gate, stated: `dune build --profile release` now requires
js_of_ocaml. Nothing in the repo does that.

Verified, with no js_of_ocaml anywhere in the environment:

```
$ dune build playground/tesl_playground_js.bc.js
Error: Don't know how to build playground/tesl_playground_js.bc.js
```

— the stanza is *absent*, not merely unbuilt, which is the property that keeps
plain `dune build` safe.

`build.sh` also passes `--build-dir compiler/_build-playground`, so switching
profiles does not invalidate the shared `compiler/_build` and force a full
rebuild in both directions. **That directory must stay inside the repo**: the
embedded-docs rule promotes `gen_docs` output back into
`compiler/lib/embedded_docs.ml`, and `gen_docs` locates the repo root by walking
up from its own path in the build directory, so an out-of-repo build directory
makes it emit an empty document list and silently truncate the embedded manual.

To build it by hand:

```sh
cd compiler && dune build --profile release \
  --build-dir "$PWD/_build-playground" playground/tesl_playground_js.bc.js
```

## Measured artifact size

`js_of_ocaml` 6.3.2, OCaml 5.4.1, `--profile release`, same docs snapshot for
both rows:

| | Raw | gzip -9 |
|---|---|---|
| `tesl_playground.js` — parser, type checker, proof checker, validation, linter, all three emitters | **1 127 187 B** (1.07 MiB) | **359 603 B** (351 KiB) |
| the same, plus `teslExplain` (`Error_codes.explain`) | 1 130 405 B | 360 602 B |
| the same, plus one reference to `Embedded_docs` | 3 424 269 B (3.27 MiB) | 867 613 B (847 KiB) |
| after the Go migration (#82), `Embedded_go_runtime` linked in through `Emit_go` | 2 369 713 B (2.26 MiB) | 719 817 B (703 KiB) |
| the same, with the runtime as a virtual library and the empty implementation linked | **1 516 821 B** (1.45 MiB) | **481 815 B** (471 KiB) |

Row 2 is the shipping artifact and is measured on a later snapshot of the compiler
than row 1, so the +3 218 B between them is mostly ordinary compiler growth: the
`teslExplain` export itself cost **+640 B raw / +288 B gzipped**, measured by
building the same tree with and without it. The 2 MB ceiling is untouched.

`build.sh` re-reports the first row on every build; prefer its output to this
table if they disagree.

**The embedded Go runtime is NOT free: `emit_go.ml` references it statically.**
`compiler/lib/go_runtime/embedded/embedded_go_runtime.ml` is 860 KB of Go source as
OCaml string literals, and `Emit_go.compile_module` (reachable from `Compile`, which
the driver links) reads `Embedded_go_runtime.files`. The OCaml linker therefore
includes the unit in every executable that links the compiler library, and
`js_of_ocaml` cannot drop a list literal that module initialisation builds — the
2.37 MB row above. The fix is a dune **virtual library** (`compiler/lib/go_runtime`):
the interface is all the compiler depends on, `bin/main.exe` and the tests get the real
snapshot as the default implementation, and `compiler/playground/dune` names
`tesl_go_runtime_none` (`files = []`). The remaining growth over row 1 (+0.39 MB raw)
is the Go emitter itself.

**The embedded manual is free as long as nothing reaches for it.**
`compiler/lib/embedded_docs.ml` is 2.3 MB of OCaml string literals, but the
driver never references it and `js_of_ocaml`'s dead-code elimination drops every
byte — confirmed by grepping the artifact for manual prose (0 hits in row 1,
present in row 2). That answers the roadmap's sizing question: **the docs do not
need splitting out, because they are already not in the bundle.** Adding an
in-page `tesl help` would cost +2.30 MB raw / +0.51 MB gzipped, so it should
fetch the manual as a separate lazily-loaded file instead of linking it in.

Measured performance (Node 24, same process, repeated calls):

| | script eval | first check | warm check |
|---|---|---|---|
| 20-line snippet | ~70 ms | ~50 ms | **5–10 ms** |
| `example/learn/lesson18-database-sql-and-proofs.tesl` (~500 lines) | ~70 ms | ~180 ms | **50–65 ms** |

Headless Chromium, full page load to rendered diagnostics: **87–117 ms** for the
proof-error example. Type-as-you-go checking is comfortably interactive.

## Verified parity with the CLI

The first 30 files of `example/learn/` were checked through `tesl --check-json`
and through `teslCheck`, comparing `(code, severity, source, line, col, message,
fix)` for every diagnostic: **29 of 30 byte-identical** (50 diagnostics), zero
crashes.

The one difference is the documented single-module limit:
`lesson07-consumer.tesl` imports the local module `Lesson07Home`, which cannot
exist in a one-buffer playground. It fails loudly — *"module `Lesson07Home` not
found: looked for `/tesl/Lesson07Home.tesl`"* — rather than silently checking a
different program, which is the behaviour you want.

## What is in here

| File | |
|---|---|
| `index.html`, `elm/src/Main.elm` | Bootstrap and production Elm application |
| `editor.js`, `monaco.js`, `fix.js`, `share.js` | Native/IDE editor adapters, structured edits and source-link codec |
| `bridge.js`, `search.css`, `playground.css` | Browser effects, lazy assets and presentation; no type matching |
| `../compiler/playground/tesl_search_js.ml` | lazy browser export of the shared native search module |
| `gen-search-assets.py` | native/browser-checked examples and build integrity manifest |
| `build.sh` | build + copy + report sizes |
| `../compiler/playground/tesl_playground_js.ml` | the driver: exports exactly two functions |
| `../scripts/playground-parity.sh` | the CI parity assertion (below) |
| `../compiler/playground/dune` | the `(modes js)` target, opt-in |

The driver exports two globals:

```js
teslCheck(source: string) : string   // JSON
teslExplain(code: string) : string   // `tesl explain <CODE>` prose, "" if unknown
```

`teslCheck` is the browser equivalent of `tesl --check-json <file>`: same
`Compile.check_source` + `Linter.lint_file` pair, same `Compile.diag_to_json`
serializer. The returned document is a **superset** of the CLI's shape — the
`diagnostics` array is byte-identical, plus `go` / `ts` / `elm` keys carrying
the generated code when the check passes (and `null` when it does not, mirroring
the CLI's rule that a program failing `tesl check` must not produce a plausible
artifact). `backend` is `go`; the legacy `racket` key remains an alias of `go`
for existing consumers. The additive `go_files` array preserves each generated
project file as `{path, content}`; it is empty on errors. The CLI supplies runtime
library files separately; they are not included in this browser response.

`teslExplain` is `Error_codes.explain` — the same prose `tesl explain <CODE>`
prints — rendered in a `<details>` disclosure under each diagnostic. It is called
**without** `~manual`, deliberately: the optional argument only refines the
trailing *"read more: tesl help manual …"* pointer, and resolving an anchor to
actual prose is what would reach for `Embedded_docs` and triple the artifact.
Measured cost of adding it: **+640 B raw / +288 B gzipped**, because
`error_codes.ml` was already linked.

### The generated-code tabs are conditional

TypeScript and Elm appear for substantive generated content. **Go project**
lets the visitor select each emitted file by path. The runtime is supplied by
the CLI; the browser never executes generated code. Arrow keys cycle all tabs.

**Explain this** uses the selection or current line to find a curated language
explanation, including `fact`, `check` and `:::`. Right-click a native line number
or use Monaco's Tesl: Explain this action. This local guide is not semantic
inference or an AI call. See `learning.js` and the linked manual.

### The examples

Five examples are generated from `examples.json` and `example/playground`:

1. A checked invoice/customer rule, with success and rejection tests.
2. The missing customer check, rejected with `V001`.
3. A missing import with a machine-applicable `String.length` fix.
4. A database write without its declared capability.
5. Hello HTTP: a minimal App listening on port 8086, with an empty memory database.
6. Capability chain: a read-only caller invokes a write-capable helper (V001).
7. Money check: an addition lacks evidence of matching currencies (V001).
8. Dimensions: adding speed and duration cannot produce a length (T001).

The build verifies expected errors, native/browser diagnostic parity, and each
clean example's Go files. Run `python3 scripts/playground-examples-runtime.py`
with the compiler/Go environment to execute the invoice tests and smoke-test
`tesl check` + `tesl run` + GET /hello. The browser checks tests but does not run them.

`start.html` includes the download, commands and a copyable setup prompt for a
coding agent. It links current installation documentation rather than duplicating
platform support promises. `agents.md` provides static capabilities, limitations
and source links for both people and visiting agents.

## What it deliberately cannot do

- **Run a program.** No Go runtime, PostgreSQL, HTTP server, SSE, queue workers
  or `tesl test` execution in this tab. A hosted runner would need runtime
  isolation and any services used by the example; that work remains separate
  (`roadmap/discarded/online_editor_to_drive_adoption.md`, D7).
- **Multi-module programs.** There is one buffer, so `import` of another *local*
  module cannot resolve. Stdlib imports (`Tesl.*`) work — those are compiled in.
- **Read or write files.** `Unix.realpath` is the one primitive `js_of_ocaml`
  cannot provide; every call site in the compiler is already inside
  `try … with _ -> p`, so the dummy implementation is caught and the path is used
  unchanged. Nothing else in `compiler/lib/` needs `unix` at check time.

## Wired into CI: the parity assertion

The `ci.sh` *"Playground parity (browser teslCheck ≡ --check-json)"* phase is a
thin caller over `scripts/playground-parity.sh`.

The assertion is **not** "it builds" — that failure is loud. It is **parity**: the
same source through `tesl --check-json` and through `teslCheck`, comparing every
diagnostic on `(code, severity, source, line, col, message, fix)`. That catches
the real failure mode, the browser build silently diverging from the CLI — which
is exactly how the linter was found to be contributing nothing before
`Sys_js.mount` replaced `Sys_js.create_file` here, and which "it builds" would
have missed entirely.

```sh
scripts/playground-parity.sh                    # build if needed, compare 30 lessons
scripts/playground-parity.sh --dist DIR         # reuse an existing dist
scripts/playground-parity.sh --limit N --verbose
```

Exit codes: `0` parity holds, `1` divergence, `77` nothing to do — `js_of_ocaml`
or `node` missing, no corpus, no built compiler. The CI phase maps `77` to
**SKIP**, never FAIL, the same convention as other optional-tool phases. `file` is
excluded from the comparison because the CLI reports a real path and the driver
reports the virtual `/tesl/<Module>.tesl` it derives from the module header.

Measured, over the first 30 files of `example/learn/` (50 CLI diagnostics):
**29/30 byte-identical, 1 known exception, 0 divergences.**

The exception is **named, not tolerated**: `lesson07-consumer.tesl` imports the
local module `Lesson07Home`, which cannot exist in a one-buffer playground. The
script asserts that this file *still differs* **and** that the browser says so out
loud (a diagnostic matching ``module `X` not found``). If it ever stops differing
the script fails on purpose, pointing at the three places that claim the
single-buffer limit still holds — here, `gen-lessons-page.py`'s `cross_module`
flag, and the note it renders on `lessons.html`.

## Explore with a guide

Six optional chapters sit beside the editor: Your first API, Rules that travel
with your code, Money and measurements, Query your data, Testing your code, and Run it locally.
Fourteen exercises cover greeting edits, imports, customer evidence, capabilities,
currencies, dimensions, typed query fields, missing rows, database evidence, regular tests,
doctests, fuzz/property tests, API tests and load tests. Each diagram node
has a hover explanation and a native disclosure usable by keyboard or touch.

Entering or selecting a step loads its matching source automatically. A per-step
in-memory draft map preserves edits when revisiting steps. Keep editing hides the
guide and preserves its step and starting-source snapshot; Resume guide remains
in the feedback header. Guide options contains restart, original-source restore,
reset stars and the Discussion link for suggesting guides. Next step and Next chapter let visitors explore freely. A short legend explains
that stars mark completed edits and are saved in the browser.

Each exercise shows the suggested code with an adjacent Apply edit button. It
replaces one matching span and rechecks the result, preserving surrounding edits;
ambiguous or already changed source disables the action. Navigation waits for an
outstanding fix/check so a finishing edit can earn its star before source changes.

One star per exercise is earned from an accepted compiler check of the suggested
edit, keeping the example's structure intact. Ordinary comments, formatting, imports and
the local checked-value binding name may vary; the capability exercise accepts
read and write access together as well as write access alone; deleting the required caller does
not solve an exercise.
Stars are historical exercise completion, not certification of arbitrary rewrites,
tests or runtime behavior. Returning to a starter or changing a completed example
shows “Completed earlier; your star is saved” until the current source satisfies
the exercise and its compiler check. Doctest lines remain part of that comparison.
Stars persist as one `tesl-playground-star-v2:<id>` key per earned star, so
separate tabs cannot replace each other’s awards. Existing v1 arrays migrate
once; the v1 array remains a compatibility snapshot. Storage events synchronize
open tabs, including Reset stars. No source is stored.
Malformed or unavailable localStorage falls back to in-memory learning. The
starting buffer and current step are held only for the current page session.

Sharing, builtin search and Install Tesl remain in the main toolbar. More holds
Save .tesl, editor mode, theme, lessons, introduction and guide controls; the
manual Check action lives next to the editor.

**Why Tesl?** opens a static, collapsible overview. Every feature has a See it in
action link using an allowlisted `?guide=` key to load the relevant chapter and
example. A shared source fragment always takes precedence and never auto-opens
the guide. Unknown guide keys use the normal playground default.
**Surprise me with one** opens a random, self-contained lesson in a separate tab;
its pool is checked with the browser compiler at build time. The community help
link points to GitHub Discussions. These pages do not replace the current buffer.


The guide catalog lives in `elm/src/Guide.elm`: step order, chapter membership,
example selection, deep-link keys, suggested edits and local test commands have
one owner. The bridge passes a raw guide key to Elm and persists opaque progress
IDs; it does not decide which chapters or exercises exist.

The testing chapter uses `test`, documentation examples (`#>` / `#=`),
`test ... with N runs` / `property`, `api-test`
and `load-test`. Its stars mean the suggested tests were added and compiler-checked,
not executed. Each step includes a `tesl test Module.tesl` command. The example
runtime check runs all five starter files and their additions through the real
CLI; load tests use a small local in-process workload. No remote scan or load is
started by the playground.

The SQL adventure (`?guide=sql`, `sql-results`, `sql-evidence`) uses three separate
steps over the same Invoice entity. Each starter intentionally fails checking; its
repair is compiled in both native and browser checks and executed by
`scripts/playground-examples-runtime.py`. Database evidence identifies the queried
row and key; it does not establish customer authorization. The browser does not
connect to a database or execute the displayed tests.

The recursive Go corpus gate also covers every tracked playground example.
`playground/examples.json` declares the expected starter errors and exact repairs.
The gate rejects changed diagnostics, missing manifest entries, and ambiguous
repairs, then builds the Go modules and generated tests for valid starters and
every repair. Deliberately broken starters must have a repair; they are never
silently excluded from the corpus.
