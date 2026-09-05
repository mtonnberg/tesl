# Adoption workbench: Elm shell, optional Monaco editor

Decision, 2026-09-05: keep a custom adoption interface and migrate its application
state and views to Elm. Offer Monaco as a lazy desktop editor inside that shell.
The default native editor remains useful for fast first visits, mobile keyboards
and simple examples. Both editors use the same compiler and application state.

This combines discovery and a richer editing experience: builtin search, checked
examples, proof explanations and shareable lessons remain prominent. A complete
VS Code workbench would introduce workspace/extension-host concerns into this
single-buffer experience. Monaco supplies editing features, not a VS Code
extension host. [Monaco's own documentation](https://microsoft.github.io/monaco-editor/)
explicitly excludes mobile browser support. [VS Code web extensions](https://code.visualstudio.com/api/extension-guides/web-extensions)
also require browser-compatible extension and language-server implementations;
embedding the shell would not make the native Tesl runtime work in a browser.

## First-visit experience

Start with the runnable Hello HTTP server; the invoice/workspace rule and its
success/rejection tests remain available as the next practical example. The welcome
panel offers a runnable API guide, a missing-workspace-check demonstration and search in everyday
language. Success points to **Build with Tesl**, sharing, or a short lesson.
Explicitly hiding/reopening the introduction persists the preference; shared
links always begin with the introduction hidden. The local run guide includes a
copyable coding-agent prompt and links to canonical installation instructions.
Proof-error and permission examples remain available as explicit choices. Compiler
requirements, raw details and generated code use progressive disclosure.
The mobile welcome is compact enough to leave room for the code.

**Save .tesl** downloads the exact current buffer. The optional local observation
hook emits `tesl:adoption` with only `{version: 1, event: NAME}` for install intent,
source download, successful source-link copy or successful search-link copy.
No analytics request, identifier, source or query is emitted. An external,
consent-aware aggregate adapter is still needed to measure a deployed funnel.
An install-link click does not count as a successful install or first project.

## Ownership

| Component | Responsibility |
|---|---|
| `elm/src/Main.elm` | Source revision, pending operations, diagnostics, fixes, explanations, generated tabs, search views, theme, highlights, first-visit framing and error/retry state |
| `bridge.js` | Versioned compiler requests, debounce, verified lazy assets, dialog/focus effects, clipboard and source URL codec |
| `editor.js` | A custom element containing one native textarea and decorative layers; native selection, scroll and composition; optional editor lifecycle |
| `monaco.js` | Monaco markers, quick fixes, catalog hover/completions, selection, find, folding, comments, multiple cursors and keyboard actions |
| `fix.js`, `share.js` | Existing machine-edit and backwards-compatible source fragment algorithms |
| `Builtin_search` / browser compiler | Authoritative types, ranking, diagnostics, explanations and code generation |

Elm owns the surrounding DOM. The `tesl-editor` custom element owns its children;
Elm projects source/diagnostics/highlights through its `state` property. The
adapter never replaces the textarea or assigns its value when an input is merely
echoed back. Composition suspends automatic checking; completion triggers a check.
Monaco applies explicit source replacements as undoable editor edits.

The former inline JavaScript application and optional Elm experiment have been
retired. There is one production application, with two editing components.

## Port contract

Requests and replies carry `version: 1`, `request_id`, `source_revision`,
`operation`, and `payload`. Replies also contain nullable `error`. Operations are
`check`, `search`, `fix`, `share`, `copy`, `editor`, `learn`, and `explain:CODE`.

Elm records each outstanding operation's ID/revision. Replies must match that
record; check/fix/share/learn replies must also match the current source revision.
Malformed messages are visible; old replies cannot overwrite current results.
A fix button also carries its rendering revision, so an old button cannot apply
an edit to a newer buffer. Monaco quick fixes check their source snapshot too.
The adapter cancels superseded debounce timers and checks IDs again after awaits.
A compiler or asset load failure leaves the source intact and exposes retry.

Browser-only effects (including downloads and content-free observation events) use a separate `ui` port. Source and queries stay in memory;
theme and explicit introduction visibility are the only persisted preferences. Sharing explicitly writes the URL or
clipboard. The existing `#s` / `#z`, `.L` and `.H` formats are retained. Switching
editors preserves source and selection; undo history is local to each editor
instance and is reset when that instance is replaced.

## Monaco's language support

The compiler's diagnostic spans become squiggles and problems. Quick fixes use
its actual structured edits. Hover and completion query the same compiler-owned
builtin catalog used by the search dialog, CLI and MCP. Ctrl+Space opens builtin
suggestions. Ctrl/Cmd+K opens discovery; Ctrl/Cmd+Enter checks;
Ctrl/Cmd+Shift+H highlights selected lines for sharing.

Catalog suggestions are **not scope-aware IntelliSense**. They do not infer local
expression types, guarantee callability, automatically import a symbol, or erase
proof/capability requirements. The checker decides whether the resulting program
is valid. Token colors and folding are cosmetic. Go output is a project preview;
the additive `go_files` field preserves filenames and contents rather than treating
legacy concatenated `go` text as one Go file. The CLI supplies runtime library
files separately. TypeScript and Elm tabs appear only for substantive output.

## Build and verification

`playground/build.sh` builds the OCaml checker/search, Elm 0.19.1 application and
pinned npm editor dependencies. `elm.json` and `package-lock.json` lock versions;
`npm ci --ignore-scripts` installs build dependencies. Elm and npm are playground
build dependencies, not compiler requirements. No CDN or network service is used
at runtime. All files, including Monaco workers, fonts and licenses, are served
locally. Monaco JS/CSS loads only after **Use IDE editor**; search loads separately
on first use. Compiler/search and optional editor entry assets have SRI identities.

Run native/browser parity and `e2e/playground/*.spec.cjs`. The production tests
cover partial typing, old source links, native undo/composition, stale/malformed
ports, themes, mobile layout, diagnostics/explanations, fixes, generated tabs,
asset failures, and Monaco switching/undo/markers/quick fixes/suggestions.

The checker still runs synchronously on the main thread. A worker with timeout
and restart is the next responsiveness improvement; the versioned envelope is
ready for that transport, but it is not implemented here. Physical IME,
screen-reader and touch-device testing remains distinct from Chromium simulation.
Full workspace navigation, local imports, runtime execution, and VS Code
extension hosting are outside this browser implementation.

## Local learning and runnable examples

`learning.js` supplies curated explanations selected lexically from the cursor,
selection or line. This is neither an AI request nor semantic type inference.
The native gutter context menu, shared Explain this button, and Monaco action
use the same request and source-revision guard. Editing clears old guidance.

`examples.json` refers to official sources in `example/playground`. The build
generates `examples.js` and downloadable files, then checks every example's
expected error codes and native/browser diagnostic parity. Clean examples also
compare each emitted Go file with native output under the same source basename.
`playground-examples-runtime.py` runs the invoice tests and the HelloServer through
the actual CLI, verifies HTTP 200 and the response body, then stops the process
group. `start.html` and `agents.md` remain readable without JavaScript.

## Guided introduction and action hierarchy

The primary toolbar keeps the example picker, builtin search, source sharing and
Install Tesl visible. More contains download, editor mode, introduction, guide,
lessons and theme controls. Check sits beside the source, where it acts. The
native disclosure closes after an action, on outside click or Escape.

The optional guide lives alongside the editor in the feedback pane. Opening it or selecting a step loads the matching example, or the saved draft
for that step. A per-step Dict holds drafts in memory. The visitor can restore
the source, selected example and highlight captured when opening the guide, or
leave with the edited source. This is a source snapshot,
not a preserved undo history. Shared links never start the guide automatically.

The five chapters contain eleven bounded exercises. `Guide.elm` is the catalog for
step IDs, order, chapter membership, examples, deep-link keys, suggested edits and
test commands. Elm owns deep-link resolution and validation of stored exercise IDs;
JavaScript storage effects operate on opaque IDs. Completion compares the accepted
source with the suggested repair (ignoring ordinary comments, whitespace and import declarations, and allowing a different
name for the checked local value); the greeting
exercise allows a changed greeting while preserving the surrounding source.
Removing a required check or privileged caller does not earn a star. Accepted
compiler replies must still match the current request and source revision.

The completion message also checks the current source against the exercise and
the last accepted compiler revision. A saved star on a restarted or changed
example is shown as earlier completion, not as validation of the current code.
The step heading reports the current position within the chapter; compact step
buttons keep the exercise visible as chapters grow.

Earned IDs are sent as deltas through the UI port. Browser effects save one
`tesl-playground-star-v2:<id>` key per award to avoid whole-array lost updates
across tabs. Existing v1 stars migrate once; the v1 array is kept as a compatibility
snapshot. Storage events refresh the Elm model through a dedicated progress port.
Reset removes the per-star keys and synchronizes every open tab. Storage failures
(including readable but unwritable storage) retain session progress in memory.

A check arriving after Keep editing still grades the paused exercise against the
same accepted source revision. The capability repair may retain read access too.
Historical stars remain separate from current diagnostics; source snapshots and
per-step drafts remain in memory only.

Native details/summary nodes provide diagram explanations by click, keyboard or
touch, with title text for hover. Chapter navigation synchronizes source and prose. Pending checks/fixes complete
before a queued step change, so the outgoing revision can earn its star. Explicit `?guide=` links resolve only an allowlisted chapter/example pair;
a source fragment takes precedence and suppresses automatic guide activation.
Changing an example removes the launch-only guide query and closes the active
guide to avoid mismatched prose. Repair buttons apply a single matching source
span, then request a fresh compiler check. Unfinished steps offer Try this edit as the primary action and Continue without
a star as a secondary link;
navigation alone earns no completion, and the local run chapter makes no installation/execution claim.

## Reasons, lessons and community

The primary install link opens `start.html#install`. `why.html` is a static,
evidence-linked overview of practical capabilities and their limits, not a
comparative benchmark. Discussions links invite newcomers to ask for help.
The introduction’s close icon uses the same remembered visibility action as
Hide introduction; the privacy line is smaller, dimmer and aligned below the tagline.

`gen-lessons-page.py` also emits `random.html`. Its pool uses lessons with no
listed prerequisites, no known sibling import and no error from the built browser
compiler. The source corpus is loaded only in the separate random-lesson page.
It previews the selected lesson and avoids an immediate repeat when another is
requested. The browser still does not execute lesson tests or programs.

Doctest exercises retain `#>` and `#=` lines when comparing source edits for
progress. Ordinary comments remain ignored; visiting an unchanged doctest
example does not count as adding a test.
