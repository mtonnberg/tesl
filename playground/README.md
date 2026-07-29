# Tesl playground (browser)

The Tesl compiler, compiled to JavaScript, running in a browser tab. It
**checks** Tesl — parser, type checker, **proof checker**, capability and
validation passes, linter, and the Racket/TypeScript/Elm emitters — and it shows
the diagnostics with their stable codes, precise spans and
**machine-applicable fixes**.

It cannot **run** a Tesl program. See [What it deliberately cannot do](#what-it-deliberately-cannot-do).

Status: spike outcome for Phase 4 of `roadmap/next/revised_onboarding.md` (D7).

---

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
| the same, plus one reference to `Embedded_docs` | 3 424 269 B (3.27 MiB) | 867 613 B (847 KiB) |

`build.sh` re-reports the first row on every build; prefer its output to this
table if they disagree.

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
| `../compiler/playground/tesl_playground_js.ml` | the driver: exports exactly one function |
| `../compiler/playground/dune` | the `(modes js)` target, opt-in |

The driver exports one global:

```js
teslCheck(source: string) : string   // JSON
```

It is the browser equivalent of `tesl --check-json <file>`: same
`Compile.check_source` + `Linter.lint_file` pair, same `Compile.diag_to_json`
serializer. The returned document is a **superset** of the CLI's shape — the
`diagnostics` array is byte-identical, plus `racket` / `ts` / `elm` keys carrying
the generated code when the check passes (and `null` when it does not, mirroring
the CLI's rule that a program failing `tesl check` must not produce a plausible
artifact).

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
4. **Capability error** — `requires [dbRead]` on a function whose body writes.
   `V001`: *"uses privileged operations and callees requiring `[dbWrite]` but
   does not declare them"*.

### Sharing

The source is compressed into the URL fragment: `#z<base64url>` of a
`deflate-raw` stream (`CompressionStream`, no library), falling back to
`#s<base64url>` where that API is unavailable. The fragment is never sent to a
server. **No backend, no storage, no moderation surface** — which is also the
answer to "a good way to share Tesl code".

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

## Not wired into CI

Deliberately. A CI phase would be three lines and needs no new machinery:

```sh
# phase N — browser playground (only where js_of_ocaml is available)
if command -v js_of_ocaml >/dev/null 2>&1; then
  playground/build.sh "$TMPDIR/playground-dist"
  node -e 'globalThis.window=globalThis;require(process.argv[1]);
           const j=JSON.parse(teslCheck("module A exposing []\n"));
           if(j.version!==1)process.exit(1)' "$TMPDIR/playground-dist/tesl_playground.js"
else
  echo "skip: js_of_ocaml not installed"
fi
```

The valuable assertion is not "it builds" but **parity**: run the same source
through `tesl --check-json` and through `teslCheck` and diff the `diagnostics`
arrays. That catches the real failure mode — the browser build silently
diverging from the CLI (which is exactly how the linter was found to be
contributing nothing before `Sys_js.mount` replaced `Sys_js.create_file` here).
