# Tesl playground (browser)

The Tesl compiler, compiled to JavaScript, running in a browser tab. It
**checks** Tesl — parser, type checker, **proof checker**, capability and
validation passes, linter, and the Racket/TypeScript/Elm emitters — and it shows
the diagnostics with their stable codes, precise spans and
**machine-applicable fixes**, squiggled on the exact range in a highlighted
editor, with `tesl explain <CODE>` prose in place.

It cannot **run** a Tesl program. See [What it deliberately cannot do](#what-it-deliberately-cannot-do).

Status: spike outcome for Phase 4 of `roadmap/completed/revised_onboarding.md` (D7).

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

The workflow asserts four things before deploying, and each corresponds to a real
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
| **Explain in place** | every diagnostic has a *Explain `<CODE>`* disclosure carrying the same prose as `tesl explain <CODE>`, fetched on first open |
| **A guided first failure** | a first visit lands on the proof-error example, already checked, with one line of framing. It disappears the moment the visitor edits the buffer, picks another example, or arrives via a share link |
| **Honest framing, when it matters** | declaring a `server`, `api`, `handler`, `queue` or channel surfaces an inline note saying what *is* checked and what is not, pointing at `tesl init` / `tesl run`. Detected on the stripped source, so prose about `api` in a comment does not trip it |
| **Keyboard and mobile** | panes stack under 900 px and the page is usable at 375 px without sideways scrolling; a skip link, real list semantics for the diagnostics, buttons for every action, visible focus rings, and Tab moves focus rather than inserting a tab character |

## The editor, and why there is no editor library

`index.html` is one file with **no dependencies**: no CDN, no web font, no image,
no framework, no bundler. The editor is a `<textarea>` with transparent text
layered exactly over an `aria-hidden` `<pre>` that carries the highlighted copy
of the same text plus the squiggle spans, with a gutter column beside it. Both
layers share one font, one line-height, one padding and `white-space: pre`; the
textarea's `scroll` event drives the underlay's and the gutter's scroll offsets.

`white-space: pre` rather than `pre-wrap` is deliberate: with wrapping, one
logical line occupies several visual rows and the gutter numbers drift from the
code. Long lines scroll horizontally *inside the editor*; the page itself never
scrolls sideways.

**CodeMirror 6 was considered and declined**, for the three reasons recorded at
the top of `index.html`: the artifact must stay static files with relative paths
and no CDN (CM6 would need bundling, and the build has no JS toolchain — only
js_of_ocaml and python3); there is no CM6 language mode for Tesl, so the
tokenizer is hand-written either way; and a plain `<textarea>` keeps native
selection, undo, IME, mobile keyboards and screen-reader support, which the
accessibility requirement asks for and a `contenteditable` gives up. Monaco stays
out on size (~5 MB against a 1.07 MB compiler).

The tokenizer's keyword table is transcribed from `compiler/lib/lexer.mll`, not
guessed. Its deliberate approximations are listed beside it in `index.html`: one
line at a time with no carried state; SQL and route words (`select`, `where`,
`get`, …) coloured wherever they appear even though the real grammar treats them
as contextual identifiers; no call-vs-binding distinction.

**Themes.** The page follows `prefers-color-scheme` by default and has an
explicit **System / Light / Dark** control (three radios, native keyboard
behaviour) persisted in `localStorage` under `tesl-playground-theme`. The
override is `:root[data-theme="light"|"dark"]`, each restating the full palette so
it wins in both directions.

## The lesson index

`lessons.html` links all 77 lessons into the checker, each with its source in the
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
nix develop                 # dev shell ships js_of_ocaml + js_of_ocaml-compiler
playground/build.sh         # → playground/dist/{index.html,tesl_playground.js}
python3 -m http.server -d playground/dist 8000
```

Two static files, all paths relative. Publishing is "copy `dist/` to any static
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
| `index.html` | the whole front end — one file, no dependencies, no CDN, no fonts, no framework |
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
`diagnostics` array is byte-identical, plus `racket` / `ts` / `elm` keys carrying
the generated code when the check passes (and `null` when it does not, mirroring
the CLI's rule that a program failing `tesl check` must not produce a plausible
artifact).

`teslExplain` is `Error_codes.explain` — the same prose `tesl explain <CODE>`
prints — rendered in a `<details>` disclosure under each diagnostic. It is called
**without** `~manual`, deliberately: the optional argument only refines the
trailing *"read more: tesl help manual …"* pointer, and resolving an anchor to
actual prose is what would reach for `Embedded_docs` and triple the artifact.
Measured cost of adding it: **+640 B raw / +288 B gzipped**, because
`error_codes.ml` was already linked.

### The generated-code tabs are conditional

Racket, TypeScript and Elm appear as tabs, and only when they contain something.
"Something" is decided by **content**, not by guessing whether the program has a
server: the generated banner, the `module` header and the `import`/`require`
preamble are stripped, and the tab appears only if anything substantive remains.
A module with no HTTP surface therefore shows Racket and no clients, instead of an
Elm tab holding three imports.

### The examples

Four preloaded, all verified to produce the same diagnostics in the browser as
`tesl --check-json` produces natively:

1. **Clean** — validate once, pass the stamped value to the write. No
   diagnostics; the generated Racket, TypeScript and Elm are shown.
2. **Proof error** — the same program with the validation skipped. `V001`:
   *"call to `saveTitle` argument `title` does not statically satisfy declared
   proof `ValidTitle raw`"*. This is the demonstration; a type error is not the
   point.
3. **Type error with a fix** — a missing stdlib import. The diagnostic carries an
   `insert_line` edit titled *"Import String.length from Tesl.String"*; the
   **Apply** button applies it and re-checks.
4. **Capability error** — `requires [dbRead Note]` on a function whose body writes.
   `V001`: *"uses privileged operations and callees requiring `[dbWrite Note]` but
   does not declare them"*.

### Sharing, and the optional position

The source is compressed into the URL fragment: `#z<base64url>` of a
`deflate-raw` stream (`CompressionStream`, no library), falling back to
`#s<base64url>` where that API is unavailable. The fragment is never sent to a
server. **No backend, no storage, no moderation surface** — which is also the
answer to "a good way to share Tesl code".

A link can also say *"and look at line 42"*:

```
#z<base64url>            the source
#z<base64url>.L42        …and put the caret on line 42
#z<base64url>.L42-45     …and select lines 42 through 45
#s<base64url>.L42        same, uncompressed payload
```

The position is **optional and appended after the payload**. `.` cannot occur in
base64url (alphabet `A-Z a-z 0-9 - _`), so every pre-existing `#z…` / `#s…` link
still decodes unchanged, and a decoder that ignores the suffix still gets the
source. Line numbers are **1-based** — what the diagnostics display and what a
person reads off the gutter.

The **Copy share link** button appends a position only when text is selected:
select the interesting lines, copy the link, and the recipient lands on them. With
no selection the link is exactly what it always was.
`gen-lessons-page.py`'s `share_fragment()` takes optional `line` / `end_line`
arguments and emits no position for the lesson index — a lesson link means "open
the lesson", and an index guessing at an interesting line would be guessing.

### Module name ↔ file name

One validation pass requires the `module` header to match the file name. The
driver therefore derives a virtual file name *from the header* (`module Foo` →
`/tesl/Foo.tesl`) instead of using a fixed one, so a lesson pasted verbatim
checks exactly as it does on disk instead of reporting a spurious mismatch.

## What it deliberately cannot do

- **Run a program.** No Racket runtime, no PostgreSQL, no HTTP server, no SSE, no
  queue workers, no `tesl test` execution. Running Tesl needs Racket + Postgres +
  a sandbox per session; that half of the online-editor idea stays discarded
  (`roadmap/discarded/online_editor_to_drive_adoption.md`, D7).
- **Multi-module programs.** There is one buffer, so `import` of another *local*
  module cannot resolve. Stdlib imports (`Tesl.*`) work — those are compiled in.
- **Read or write files.** `Unix.realpath` is the one primitive `js_of_ocaml`
  cannot provide; every call site in the compiler is already inside
  `try … with _ -> p`, so the dummy implementation is caught and the path is used
  unchanged. Nothing else in `compiler/lib/` needs `unix` at check time.

## Wired into CI: the parity assertion

`ci.sh` phase 14, *"Playground parity (browser teslCheck ≡ --check-json)"*, is a
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
**SKIP**, never FAIL, the same rule the racket/PostgreSQL phases follow. `file` is
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
