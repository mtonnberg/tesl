# 12 — Your First Compiler Change

> Audience: contributors making their first change to the Tesl compiler — one real improvement, end to end, including the parts that go wrong.

This is a lap of the pipeline, not a tour of it. You will edit the linter, ship a
machine-applicable fix, break three tests on purpose, read a byte-exact diff, and finish with
something worth committing.

Prerequisites: [`README.md`](README.md)'s "Quick start for a new contributor" — you are in the nix
dev shell, `cd compiler && dune build` works, and `TESL_REPO_ROOT` points at *this* checkout.
`tesl help manual dev-docs/12-your-first-compiler-change` prints this page from the CLI.

---

## The change: make `W020` actually helpful

`W020` is the linter warning for a module name that is not UpperCamelCase. Fifteen lines of code,
[`compiler/lib/linter.ml:237-247`](../compiler/lib/linter.ml):

```ocaml
      if starts_with stripped "module " then begin
        let name = first_word_after "module " stripped in
        (* Check each dot-separated part *)
        let parts = String.split_on_char '.' name in
        let bad = List.exists (fun part ->
          part <> "" && not (part.[0] >= 'A' && part.[0] <= 'Z')
        ) parts in
        if bad then
          emit i 0 "warning" "W020"
            (Printf.sprintf "module name `%s` should be UpperCamelCase" name)
      end;
```

and its catalog entry, [`compiler/lib/error_codes.ml:300`](../compiler/lib/error_codes.ml):

```ocaml
  { code = "W020"; category = Lint;
    title = "module name not UpperCamelCase";
    explanation = "Module names use UpperCamelCase, e.g. `module TodoApi`.";
    manual = Some "best-practices" };
```

Those fifteen lines contain **five** real defects. Each is a complete contribution on its own; you can
stop after any one of them.

| # | The defect | What it teaches |
|---|---|---|
| 1 | `emit i 0` — the span is column 0, so the editor squiggle covers the line start, not the offending name | spans, `location.ml`, why a precise range matters to the LSP |
| 2 | **No `fix`**, though `todo_api` → `TodoApi` is the most mechanical edit in the compiler | `diag_fix.ml`, the verified-builder pattern, how a fix reaches the LSP quickfix and `agent-context` |
| 3 | The check is only *"first character is uppercase"* — `Todo_api` and `TODOAPI` both pass — while the message says UpperCamelCase | a diagnostic must not overclaim; tighten the check or soften the message, and defend the choice |
| 4 | `starts_with stripped "module "` is line-prefix text matching, not AST | why the linter is text-based, and where that bites |
| 5 | `manual = Some "best-practices"` has no `#anchor`, so the deep-link lands at the top of the manual's longest page instead of `#naming-conventions`, which exists | the anchor contract, from the producing side |

**Start at #2.** A machine-applicable fix is the most satisfying first contribution and the most
representative of what this compiler is for. #1 comes along for free (a fix needs a real span), and #5
is a one-line bonus.

> If W020 already ships a fix by the time you read this, someone got here first. The other defects in
> the table are almost certainly still open — pick one and follow the same lap. Every failure
> sequence below is reproduced output, not a sketch.

---

## Step 1 — see it before you touch it

Always capture the current behaviour first. It is your diff.

```bash
cd /tmp && mkdir -p w020 && cd w020
printf 'module todo_api exposing [f]\nimport Tesl.Prelude exposing [Int]\nfn f() -> Int =\n  1\n' > probe.tesl
"$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe" --lint probe.tesl
```

```text
warning[W020]: module name `todo_api` should be UpperCamelCase
  --> /tmp/w020/probe.tesl:1:1

  read more: tesl help manual best-practices  (explain: tesl help W020)
```

`1:1` is defect #1 (rendered positions are 1-based; internal ones are 0-based, so `emit i 0` prints
as column 1). No fix is offered — defect #2. The deep-link has no anchor — defect #5.

Now confirm defect #3 while you are here, because it changes what a *correct* fix looks like:

```bash
printf 'module Todo_api exposing [f]\nimport Tesl.Prelude exposing [Int]\nfn f() -> Int =\n  1\n' > naive.tesl
"$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe" --lint naive.tesl; echo "exit=$?"
```

Silent, exit 0. `Todo_api` is not UpperCamelCase and the linter is happy — the check only looks at
`part.[0]`. Remember that: a fix that merely uppercases the first character produces `Todo_api`, which
makes the warning go away **without making the name UpperCamelCase**. Defects #2 and #3 are coupled,
and you cannot ship a correct fix without picking a side on #3.

---

## Step 2 — the edit

Two things change in `lint_naming`: the column becomes the column of the *name*, and the diagnostic
carries a fix. The linter's `emit` already accepts one:

```ocaml
  let emit ?(fix=None) line col severity code message =
```

`fix` is a `Compile.diagnostic_fix option`. `Compile` re-exports [`Diag_fix.t`](../compiler/lib/diag_fix.ml)
by type equation, so `Compile.Replace_range { … }` *is* `Diag_fix.Replace_range { … }` — either
spelling compiles, and the linter uses the `Compile.` one throughout.

Replace the `if bad then …` arm with:

```ocaml
        if bad then begin
          (* #1: anchor the span on the NAME, not on column 0. *)
          let col =
            match string_index_of line ("module " ^ name) with
            | Some c -> c + String.length "module "
            | None -> 0
          in
          (* #2: the edit is mechanical, so ship it as a fix. *)
          let upper_camel part =
            String.split_on_char '_' part
            |> List.concat_map (String.split_on_char '-')
            |> List.filter (fun w -> w <> "")
            |> List.map (fun w ->
                 String.make 1 (Char.uppercase_ascii w.[0])
                 ^ String.sub w 1 (String.length w - 1))
            |> String.concat ""
          in
          let suggestion = String.concat "." (List.map upper_camel parts) in
          let fix =
            if suggestion = name then None
            else Some (Compile.Replace_range
                         { start_line = i; start_col = col;
                           end_line = i; end_col = col + String.length name;
                           replacement = suggestion })
          in
          emit ~fix i col "warning" "W020"
            (Printf.sprintf "module name `%s` should be UpperCamelCase" name)
        end
```

Three things in there are house style, not incidental:

- **`Replace_range` columns are half-open** — `end_col` is exclusive, `start = end` is an insertion.
  That contract is documented on the type in `diag_fix.ml`; get it wrong and the edit eats a
  character.
- **`string_index_of` returning `None` degrades to column 0** rather than raising. The linter is
  text-based (defect #4): it can be handed a line it does not fully understand, and a lint must never
  crash the compile.
- **`suggestion = name` yields no fix.** A fix that changes nothing is worse than no fix — the
  apply-and-recompile seam test (`compiler/test/test_fix_apply.ml`) requires every shipped fix to make
  its own diagnostic disappear.

Note `upper_camel` splits on `_` and `-`, so the suggestion is `TodoApi`, not `Todo_api`. That is
taking a side on defect #3: the *fix* now produces genuinely UpperCamelCase output even though the
*check* still under-reports. Say so in your commit message; leaving the check for a follow-up is
fine, leaving it silently is not.

```bash
cd "$TESL_REPO_ROOT/compiler" && dune build
```

It builds. Everything after this point is the interesting part.

---

## Step 3 — what breaks first, and why that is good news

```bash
dune test 2>&1 | tail -40
```

### Failure 1 — the byte-exact diagnostic snapshot

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ [FAIL]        snapshot/linter                  3   W020 module name casing.  │
└──────────────────────────────────────────────────────────────────────────────┘
ASSERT W020: rendered diagnostics changed.
--- EXPECTED ---
[W020] warning @ lint 0:0-0:0
  module name `myMod` should be UpperCamelCase
--- ACTUAL ---
[W020] warning @ lint 0:7-0:7
  module name `myMod` should be UpperCamelCase
--- END ---
(If this change is intentional, update the expected block in test_diag_snapshots.ml to the ACTUAL block above.)
```

**How to read a byte-exact diff:** the pair of blocks is the whole story. `0:0-0:0` → `0:7-0:7` is
line 0, column 0 → line 0, column 7 — the span moved onto the name, which is precisely what you set
out to do. The message text is unchanged, which is the reassurance you want: you moved the span and
nothing else.

These snapshots are **expectations, not oracles**. They exist so that a diagnostic cannot change
without a human agreeing to it. The fix is to update the expectation — this file, not a regeneration
command:

`compiler/test/test_diag_snapshots.ml`, around line 277:

```ocaml
let lint_w020_expected =
  "[W020] warning @ lint 0:7-0:7\n\
  \  module name `myMod` should be UpperCamelCase"
```

Update it only after you have read the ACTUAL block and agree with every character of it. "Paste
ACTUAL over EXPECTED until green" is how a real regression gets blessed into the suite.

### Failure 2 — the one you have to go looking for

Rebuild and re-run and the suite is **green**, including `test_fix_titles.ml`. That is a gap in the
test, not a pass:

```bash
./_build/default/test/test_fix_titles.exe        # "Test Successful" — every case passes
```

`test_fix_titles.ml` guarantees that every fix-shipping code has an entry in
`Diag_fix.titled_codes` — but it discovers fix-shipping codes by running a **fixed corpus** of seven
broken sources through the real pipeline, and not one of them has a badly named module. Your new fix
is invisible to it.

So make it visible. Add a corpus entry in `compiler/test/test_fix_titles.ml` (the `corpus` list,
around line 144):

```ocaml
  ( "module name not UpperCamelCase",
    "module todo_api exposing [f]\n\
     import Tesl.Prelude exposing [Int]\n\
     fn f() -> Int =\n\
    \    1\n" );
```

Now it fails, and says exactly what to do:

```text
ASSERT code W020 ships a fix but has no entry in Diag_fix.titled_codes — add an intent-bearing title for it (see Diag_fix.title)
```

**This is the load-bearing lesson of the whole guide.** The repo is full of single-source machinery
that punishes skipped steps — capability maps, the stdlib binding seam test
(`compiler/test/test_stdlib_runtime_binding.ml`), generated docs promoted on build, byte-exact `.rkt`
snapshots. That machinery is only as good as its discovery mechanism. When you add a new *kind* of
thing, check whether the test that guards that kind can actually see it. Here the honest change is
two edits, not one: the fix, and the corpus entry that makes the fix subject to the rule.

### Failure 3 — the house standard for titles

Add the entry to `compiler/lib/diag_fix.ml` — both halves, the list and a `title` arm:

```ocaml
let titled_codes = [ "W010"; "W011"; "W020"; "W050"; "T001"; "E000"; "E002";
                     "VBOOL001"; "VBOOL002" ]
```

```ocaml
  | "W020", Replace_range { replacement; _ } ->
    Printf.sprintf "Rename the module to `%s`" (truncate 40 replacement)
```

That reads well. It also fails:

```text
ASSERT module name not UpperCamelCase [W020]: title should start with an imperative verb (Remove/Re-indent/Import/Delete/Move/Replace/Insert/Rewrite/Change/Clear/Apply): Rename the module to `Todo_api`
```

The rules a quick-fix title must satisfy, all enforced by that suite:

- starts with an **imperative verb** from the allowlist in `test_fix_titles.ml`;
- **≤ 72 characters** — it has to fit in an editor's lightbulb menu;
- never mentions the diagnostic code, and never contains the word "diagnostic";
- two different actions offered on the same file must read differently.

Two legitimate resolutions, and you must pick deliberately: use an allowlisted verb, or argue that
"Rename" belongs in the allowlist and add it there. Adding a verb widens the standard for everyone,
so the cheaper call is:

```ocaml
  | "W020", Replace_range { replacement; _ } ->
    Printf.sprintf "Change the module name to `%s`" (truncate 40 replacement)
```

Green.

---

## Step 4 — defect #5, and the anchor contract from the producing side

One line in `compiler/lib/error_codes.ml`:

```ocaml
    manual = Some "best-practices#naming-conventions" };
```

`## Naming Conventions` exists in `manual/best-practices.md`; the slug rule that turns a heading into
an anchor lives in [`manual/anchors.md`](../manual/anchors.md) and is implemented by
`Error_codes.slug_of_heading`. This is the **producing** side of that contract: `error_codes.ml`
ships deep-links, and markdown edits can break them. Two independent guards catch it —
`compiler/test/test_error_codes.ml` in the gate, and `tests/doc-integrity.sh`, which resolves every
`manual = Some "<section>#<anchor>"` through the CLI's own section map in about two seconds:

```bash
bash tests/doc-integrity.sh
```

Confirm the result end to end:

```bash
"$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe" --lint /tmp/w020/probe.tesl
```

```text
warning[W020]: module name `todo_api` should be UpperCamelCase
  --> /tmp/w020/probe.tesl:1:8

  read more: tesl help manual best-practices#naming-conventions  (explain: tesl help W020)
```

Column 8 instead of 1, and an anchored deep-link. And the machine-readable surface now carries the
edit:

```bash
"$TESL_REPO_ROOT/compiler/_build/default/bin/main.exe" agent-context /tmp/w020/probe.tesl
```

```json
    "fix": {
      "kind": "replace_range",
      "start_line": 0, "start_col": 7,
      "end_line": 0,   "end_col": 15,
      "replacement": "TodoApi",
      "title": "Replace with `TodoApi`"
    }
```

That is the same payload the LSP turns into a quick-fix. **And it exposes a real bug you did not
cause:** the title says `Replace with \`TodoApi\`` — the generic content-derived wording — not
`Change the module name to \`TodoApi\``. `Compile.agent_diag_json`
(`compiler/lib/compile.ml`, `agent_diag_json`) calls `fix_to_json d.fix` without `~code`, while
`diag_to_json` a few hundred lines earlier calls `fix_to_json ~code:d.code d.fix`. So every
intent-bearing title is dropped on the `agent-context` surface and only on that one. Tracing your
change to *every* client surface is how you find things like this; write it up as its own item rather
than smuggling it into this commit.

---

## Step 5 — snapshots, and the failures that are not your fault

Three gate mechanisms will confront you sooner or later. Know which is which before you start
regenerating things.

**Byte-exact `.rkt` snapshots.** `ci.sh` phase *"Exact-match `.rkt` snapshots"* compiles every
`example/learn/*.tesl` and diffs the output against the committed `.rkt` beside it. A diagnostic
change does not touch these; an **emitter** change touches all of them. When the diff is intentional,
regenerate per file:

```bash
compiler/_build/default/bin/main.exe example/learn/lesson00-hello-world.tesl \
  > example/learn/lesson00-hello-world.rkt
```

Read the diff before committing it. The phase canonicalises absolute paths inside `thsl-src!` forms,
so a path-only difference is not a real one.

**Promoted generated files.** `compiler/lib/embedded_docs.ml` bakes `manual/` and `example/` into the
binary and is re-promoted by `dune build`; `ci.sh` phase *"Embedded-docs sync"* fails if the tracked
copy is stale. Never hand-edit a promoted file. Edit the source, run `dune build`, and commit the
regenerated file **in the same commit** as the change that caused it.

**`version mismatch, found 8.18`** (or any Racket version) is **stale `.zo` bytecode, not a
regression.** Tesl targets Racket 9.2 and the dev shell ships 9.2. Clear and recompile:

```bash
find . -name compiled -type d -prune -exec rm -rf {} +
```

plus `tesl clean` in any project directory. This is the single most likely first-hour confusion.

**Snapshot tests failing on files you never touched** almost always means `TESL_REPO_ROOT` points at
another checkout. It is exported by direnv, which is a **trap in a git worktree**: the export keeps
pointing at the main repository, so the worktree builds and tests against the wrong tree and the
snapshot comparison is meaningless — it can fail *or pass* for reasons unrelated to your change. In a
worktree, set it explicitly:

```bash
export TESL_REPO_ROOT="$PWD"
export TESL_OCAML_COMPILER="$PWD/compiler/_build/default/bin/main.exe"
```

---

## Step 6 — the regression test

Adding a test file is not enough to run it. Two registries have to agree:

- name the executable in `compiler/test/dune` (the big `(names …)` stanza), and
- `compiler/test/test_suite_registration.ml` fails the build if a `test_*.ml` on disk is **not** named
  in that dune file — the "a test exists but never runs" hole, closed by construction.

For this change no new file is needed: the two existing suites are the right homes, and you have
already edited both.

- `compiler/test/test_diag_snapshots.ml` pins the rendered diagnostic byte for byte, including the
  span. That *is* the regression test for #1.
- `compiler/test/test_fix_titles.ml`'s new corpus entry pins #2: it drives the real pipeline, so the
  fix must exist, apply, and carry a title that meets the standard.
- `compiler/test/test_fix_apply.ml` already covers every shipped fix generically — it applies each one
  and asserts the diagnostic disappears. Your fix is now in its scope for free, which is why the
  `suggestion = name` guard matters.

A new *behaviour* would need a new case: prefer a `.tesl` fixture and a snapshot over a hand-built
OCaml value, because the former exercises the pipeline the user actually hits. See
[`09-adding-tests.md`](09-adding-tests.md).

---

## Step 7 — what a finished change looks like

```bash
cd "$TESL_REPO_ROOT" && ./ci.sh
```

`./ci.sh` at the repo root is the authoritative gate. `compile-examples.sh` and `compiler/ci.sh`
`exec` into it, and `dune test` alone omits corpus, runtime, tooling, and end-to-end checks. Run the
full gate before committing.

The finished diff is about 30 lines across five files:

| File | Change |
|---|---|
| `compiler/lib/linter.ml` | precise column + a `Replace_range` fix (#1, #2) |
| `compiler/lib/diag_fix.ml` | `"W020"` in `titled_codes` + a `title` arm |
| `compiler/lib/error_codes.ml` | `manual = Some "best-practices#naming-conventions"` (#5) |
| `compiler/test/test_diag_snapshots.ml` | the updated span expectation |
| `compiler/test/test_fix_titles.ml` | a corpus entry, so the completeness rule can see the new fix |

Commits go **straight to `main`** — trunk-based, no `CODEOWNERS`, no review requirement, no branch
protection. `./ci.sh` is the review. If the change closes a `roadmap/next/` item, move that file to
`roadmap/completed/` in the same commit, rewritten to describe what was actually built.

Leave the tree honest: if you fixed #2 and #5 but left #3 open, say that in the commit message.
An accurate account of what remains is worth more than the appearance of completeness.

---

## Where to go next

- The remaining W020 defects — **#3** (the check under-reports; tighten it or soften the message) and
  **#4** (line-prefix text matching instead of AST). #3 is the more interesting argument.
- The `agent-context` title bug found in Step 4 (`compiler/lib/compile.ml`, `agent_diag_json`).
- [`01-overview.md`](01-overview.md) — the pipeline as a whole, once you have seen one change move
  through it.
- [`02-parser.md`](02-parser.md) + [`04-body-compiler.md`](04-body-compiler.md) — where compiler bugs
  usually live.
- [`05-adding-stdlib-function.md`](05-adding-stdlib-function.md) — the other classic first change, and
  the one with the most single-source machinery to respect.
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — the short version of all of this.
