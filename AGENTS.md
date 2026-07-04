# Tesl — agent API

A stable, token-economical surface for AI coding agents (Claude Code, etc.) to
understand and debug Tesl programs the way a human would. Everything here is the
`tesl` compiler CLI emitting compact, self-describing JSON on stdout — call it
directly, or via the MCP server (see the end).

**Build the compiler once:** `cd compiler && dune build` → binary at
`compiler/_build/default/bin/main.exe` (referred to below as `tesl`).
Set `TESL_REPO_ROOT` to the repo root so the stdlib resolves.

---

## The core loop (the 80/20)

**After every edit, run `tesl agent-context <file>` and read the diagnostics.**
Tesl's type + proof system rejects unproven/ill-typed code at compile time and
tells you *exactly* what's wrong, with a stable code and often a machine-applicable
fix. That coded-diagnostic feedback is a precise spec to iterate against — better
than guessing. Compile-check after each edit; fix what the codes say; repeat.

```
tesl agent-context path/to/file.tesl          # or: tesl --agent-context-json <file>
```
Emits (compact, single line):
```json
{ "version":1, "file":"...", "content_hash":"...", "ok":true|false,
  "summary":"2 errors, 1 warning; 3 unproven obligations",
  "diagnostics":[ {"code":"...","severity":"error|warning","message":"...",
                   "line":N,"col":N,"end_line":N,"end_col":N,"fix":"..."?} ],
  "symbols":[ {"name":"...","kind":"fn|type|entity|record","signature":"..."} ],
  "proof_obligations":[ {"line":N,"col":N,"message":"...","code":"..."} ] }
```
- `diagnostics` are **errors first**, each with a stable `code` (+ a `fix` when the
  compiler can suggest one). Exit code is non-zero iff there are error-severity diags.
- `symbols` are the in-scope top-level declarations with their **signatures only**
  (no bodies) — enough to call them correctly without reading the whole file.
- `proof_obligations` lists what's still **unproven**.
- This is deliberately *small* (no expr-type firehose). Re-run it after edits; the
  `content_hash` tells you whether a cached answer is stale.

---

## Targeted semantic queries

All take a file (+ a 0-based `LINE COL` where shown) and emit `{"version":1, ...}`.
Use these for a *specific* question — never dump a whole module into context.

| Command | Answers |
|---|---|
| `tesl --check-json <file>` | full diagnostics (codes + fixes) — the **same diagnostics** as `agent-context`, but in the IR-2/LSP schema (see note below) |
| `tesl --type-at-json <file> L C` | the type of the expression at L:C |
| `tesl --field-at-json <file> L C` | the record/field type at L:C |
| `tesl --signature-help-json <file> L C` | callee param labels/types + active-param index at a call site |
| `tesl --completions-json <file> L C` | completion candidates at L:C |
| `tesl --definition-json <file> L C` | definition location of the symbol at L:C |
| `tesl --type-definition-json <file> L C` | location of the *type's* declaration |
| `tesl --occurrences-json <file> L C` | same-file uses of the symbol (each with `kind`: read/write/text) |
| `tesl --selection-range-json <file> L C` | nested AST node ranges (smart-expand) at L:C |
| `tesl --local-bindings-json <file>` | local bindings + inferred types |
| `tesl --semantic-json <file>` | the FULL module snapshot (firehose — avoid unless you need everything) |
| `tesl --lint <file>` | linter findings |
| `tesl --fmt <file>` | format in place |

> Cross-file navigation (project-wide definition/references/rename, workspace symbol)
> is **not** available yet — it needs the IR-1 multi-file index (see
> `roadmap/later/further_editor_improvements.md`). The queries above are same-file.

> **Diagnostic JSON shapes differ by design.** `agent-context` and `--check-json`
> carry the **same diagnostics** (same `code`/`severity`/`message`/`fix`), but in
> two shapes for two audiences:
> - **`agent-context`** — a *flat, compact* diagnostic for the AI edit loop:
>   `{code, severity, message, line, col, end_line, end_col, fix?}` (positions
>   inline, no per-diagnostic `file` since the snapshot is single-file).
> - **`--check-json`** — the *IR-2 / LSP* diagnostic: `{file, start:{line,col},
>   end:{line,col}, severity, code, message, fix, source}` (nested spans, an
>   explicit `file`, and a `source` — `lint`/`type`/…). This is the shape LSP-style
>   tooling consumes.
>
> Both use **0-based** line/col. Consume `agent-context` for the edit loop and
> `--check-json` when you need the LSP span/`source` shape; do not expect them to be
> byte-identical.

---

## Runtime inspection — debug like a human (headless)

`tesl debug-inspect` runs a program to a breakpoint **you set** (with stop-the-world
active so nothing races) and dumps the paused runtime state as one JSON object.

```
tesl debug-inspect <file.tesl> --break-at SPEC [--break-at SPEC ...] \
                   [--when EXPR] [--hit SPEC] [--mode program|test]
```

**You set your own breakpoints — full control, not just pre-existing ones:**

| SPEC form | Meaning | Example |
|---|---|---|
| `LINE` | break unconditionally at LINE | `--break-at 42` |
| `LINE:COL` | column accepted, ignored (checkpoints are per-line) | `--break-at 42:7` |
| `"LINE: <expr>"` | **conditional** — break only when the boolean holds over the locals | `--break-at "42: n == 100"` |
| `"LINE: <hit>"` | **hit-count** — break on the Nth execution (`==`/`>=`/`<=`/`>`/`<`/`%` N) | `--break-at "42: %3"` |
| `L1,L2,L3` | several bare lines at once | `--break-at 10,22,40` |

- `--break-at` is **repeatable**; all are registered and it stops at whichever fires
  first. `--when EXPR` / `--hit SPEC` set defaults for breakpoints with no inline one.
- A bad condition **fails open** (treated as true) — a typo never silently drops a bp.
- `--mode test` runs the module's `test` blocks; `--mode program` runs its main/serve.

Output:
```json
{ "version":2, "stopped":true,
  "source":{"file":"...","line":N},
  "breakpoint":{"line":N, "condition":"..."?, "hit":"..."?},   // which bp fired
  "locals":[ {"name":"...","value":"...","type":"..."} ],       // proof-unwrapped
  "domain":{ "queues":[...], "caches":[...], "sse":[...], "email":[...], "workers":[...] },
  "sql": { "sql":"... $1 ...", "params":[...], "table":"...", "preview":"...", "row-count":N } | null }
```
- `domain` is the **full live state** (every queue's pending jobs, cache entries,
  connected SSE clients, email outbox, worker pools) — drill into entries, not just counts.
- `sql` is the **exact parameterized statement** + bound params the driver runs (+ an
  escaped read-only preview) — no "SQL magic".
- If no breakpoint fires: `{"stopped":false, "reason":"breakpoint-not-hit", ...}` (never hangs).

Example — inspect a value only on the iteration you care about:
```
tesl debug-inspect example/learn/lesson61-step-debugging.tesl \
     --break-at "100: score == 75" --mode test
```

### Breakpoints on a running server (curl flow)
See `.claude/commands/tesl-debug-curl.md` — launch the server under `debug-inspect`
with a handler breakpoint, then `curl` the endpoint to drive the request that hits it;
the inspector captures + dumps the paused state.

---

## MCP server (`editor/tesl-mcp`)

For MCP-capable agents, `editor/tesl-mcp/tesl-mcp.rkt` exposes the surface above as
discoverable tools over stdio (agent-context, diagnostics, type/signature/completion
queries, definition, references, proof obligations, and the headless step-debugger
with full breakpoint-setting). See [`editor/tesl-mcp/README.md`](editor/tesl-mcp/README.md)
for the full tool catalog and argument shapes. Register it with your client.

If Tesl is **installed via the Nix flake** (`nix profile install github:mtonnberg/tesl`),
the `tesl-mcp` binary is on PATH — no repo checkout or env needed:

```sh
claude mcp add tesl -- tesl-mcp           # Claude Code
```

```json
{ "mcpServers": { "tesl": { "command": "tesl-mcp" } } }   # generic client
```

From a repo checkout, run the script directly with `TESL_REPO_ROOT` set:

```json
{ "mcpServers": { "tesl": {
    "command": "racket",
    "args": ["editor/tesl-mcp/tesl-mcp.rkt"],
    "env": { "TESL_REPO_ROOT": "/path/to/tesl" } } } }
```
See `editor/tesl-mcp/README.md` for details.

---

## Token economy (please)

- Prefer `agent-context` (compact) and **targeted** position queries over `--semantic-json`.
- Query a *position/symbol*, read the one answer; don't sweep.
- Results carry `content_hash` — re-query only after you edit.
- `debug-inspect` returns one consistent snapshot per run; pick the breakpoint that
  answers your question (conditional/hit-count) rather than stepping repeatedly.

## Verified / gated

Everything here is covered by automatic regression tests in `compiler/ci.sh`
(OCaml query flags via `dune test` + a "Racket-suites" section running the DAP
debugger, headless `debug-inspect` incl. conditional breakpoints, and the MCP
protocol smoke). A change that breaks the agent API fails the gate.


## Leveraging Proofs

Tesl has a very powerful proof system, make sure to leverage that when coding. The goal is to reduce the amount of code a human need to review/look at to know that the code does what she/he wants. That means, using types, proofs, tests(test, api-test, load-test), auth, check, establish and point the human to relevant parts. When you need a decision/guidance from a human, try to frame it through the lens of proofs (explaining the different options in a friendly and easy-to-understand way).

## Communication style

Be very crisp, concise and precise but helpful and constructive. Avoid fluff and go directly to the point. Use BLUF where appropiate (Bottom Line Up Front). If a user do not seem to understand, be a bit more verbose and use tables to clearly make different options clear and understandable.