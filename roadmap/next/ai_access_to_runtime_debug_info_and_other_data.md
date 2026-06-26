# Steps to improve coding agent performance

## Background

We have taken great steps to improve the developer experience in vscodium with a lot of debugging features and LSP functionality.

## Goal

We want a coding agent (claude code, Mistral Vibe, etc) to have as much information and help as possible to increase the performance of these agents. 

- The coding agent can set break points, debug and inspect the code and runtime values, just as a human would do.
- The coding agent has a good way of interacting with the compiler/linter that gives token effecient ways of progressing when coding
- (optional) generate skills/commands for the agent to easily curl the app to call it to activate a breakpoint

## Assessment (Claude's thoughts, 2026-06-26)

**TL;DR — yes, very feasible, and it's a strong idea — but the framing should change.
Do *not* hand the agent the LSP/DAP protocols. Hand the agent the same SEMANTIC
DATA those protocols are built on, exposed in an agent-shaped surface (CLI flags +
an MCP server). The compiler already produces almost all of it; the LSP is just one
consumer. Add a second consumer.**

### The key reframe: agents are not editors

The LSP and DAP are protocols designed for a *long-lived, stateful, low-latency*
client (an editor) that pushes/pulls incremental updates over a JSON-RPC session
keyed to a cursor position and an open-buffer model. A coding agent is the opposite
shape: it is *stateless per call*, works in batches, edits files directly, has no
cursor, and pays a real token cost for every byte it reads. Driving an LSP session
from an agent (spawn server → initialize → didOpen → request → parse → shutdown) is
awkward and buys little.

What the agent actually wants is the **underlying facts**, on demand, as compact
self-describing JSON it can shell out for. TESL is unusually well-positioned here
because the compiler *already* emits exactly that — the LSP is a thin Racket shim
over CLI query flags. So the move is: **promote those queries (plus a new headless
debug surface) into a documented, stable "agent API," and the LSP and the agent
become two front-ends over one set of compiler queries.**

### What is already agent-ready today (low-hanging fruit)

The compiler exposes machine-readable JSON for: diagnostics (`--check-json`, with
**stable error codes + suggested fixes**), full module snapshot (`--semantic-json`),
type-at-position (`--type-at-json`), hover/field (`--field-at-json`), definition
(`--definition-json`), occurrences (`--occurrences-json`, now with read/write kind),
completions (`--completions-json`), signature help (`--signature-help-json`),
selection ranges, type-definition, local bindings, formatting (`--fmt`), lint
(`--lint`). An agent can already call these directly.

For TESL specifically, the single **highest-ROI** item is not navigation at all — it
is feeding the agent the **structured diagnostics + proof obligations**. TESL's whole
value is that the type/proof system rejects unproven code at compile time. That means
the compiler can tell an agent, in machine-readable form, *exactly what is unproven or
ill-typed and why*, with a code and often a fix. That is a far better signal than a
human gets from squinting at squiggles — it is a precise, checkable spec the agent
can iterate against. **An agent that compiles-checks after every edit and reads the
coded diagnostics is already "debugging like a human," statically.**

### The real gap: runtime / dynamic inspection

Everything above is *static*. The thing this repo just built — the DAP debugger with
**domain inspection** (live queues / caches / connected SSE clients / email outbox /
worker pools), **SQL transparency** (the exact parameterized SQL + params), and
**stop-the-world** pausing — has *no headless equivalent*. That is the genuinely new
capability worth a roadmap item: let an agent run a program to a breakpoint and dump
the live runtime state as JSON, so it can answer "what is *actually* in this queue /
what SQL *actually* runs / what does this value evaluate to" instead of reasoning
about it in its head.

Crucially, the DAP work just shipped is **directly reusable**: the domain registry,
the SQL capture, and the value-rendering (`domain-inspect.rkt`) are front-end-agnostic
state capture. A headless inspector is the same capture with a JSON dump instead of
the DAP wire protocol.

### Recommended architecture (phased, each independently useful)

1. **`tesl agent-context <file>` (cheap, do first).** One command that emits a
   compact, *token-economical* snapshot tuned for an agent: signatures + types of the
   symbols in scope, the coded diagnostics with fixes, and the **outstanding proof
   obligations**. Not the raw `--semantic-json` firehose — a summarised, ranked view.
   Plus a short `AGENTS.md` documenting the query surface as a stable contract.

2. **`tesl debug <file> --break-at L:C --dump json` (headless inspect).** Runs to a
   breakpoint and emits locals + the full domain state (queues/caches/SSE/workers) +
   pending/last SQL as JSON. Built straight on the DAP machinery (domain registry +
   SQL capture + stop-the-world) already in the tree. This is the "inspect like a
   human" capability, made scriptable and deterministic. Pair it with the
   already-added "run a function with input" so the agent can probe behaviour.

3. **An MCP server (`tesl-mcp`) — the "perfect world" delivery.** Claude Code, and a
   growing set of agents, speak the Model Context Protocol natively. Wrap the queries
   above as MCP *tools*: `tesl.check`, `tesl.type_at`, `tesl.signature`, `tesl.run`,
   `tesl.debug_inspect`, `tesl.explain_sql`, `tesl.proof_obligations`. Then the agent
   gets first-class, discoverable tools instead of having to know CLI incantations —
   and the *same* server can serve any MCP-capable agent. This is the cleanest answer
   to "as much information and help as possible."

### Downsides & mitigations

- **Context cost is the dominant risk.** Dumping `--semantic-json` or raw LSP
  responses into an agent's context is expensive and noisy, and *hurts* performance
  (drowns the signal). Mitigation: every agent-facing surface must be *targeted*
  (a position, a symbol) and *summarised* (ranked, deduped), never a firehose. Token
  economy is a first-class design constraint, not an afterthought.
- **Latency / chattiness.** Each query is a subprocess (~compiler startup). Fine for
  on-demand use, bad if an agent polls like an editor. Mitigation: batch queries; a
  persistent MCP server amortises startup; reuse the import cache.
- **Determinism for runtime debugging.** Inspecting a live server with timers/workers
  /SSE is non-reproducible unless paused — which is exactly why stop-the-world +
  scriptable breakpoints matter for the headless path.
- **Security / code execution.** A debug/run surface executes arbitrary program code.
  Inside a local agent harness that already runs shell commands, this is not a *new*
  risk. But a hosted/remote agent scenario needs sandboxing (a custodian-bounded,
  network-restricted runner) before exposing `tesl.run`/`tesl.debug_inspect`.
- **Staleness.** Query results reflect the on-disk file at call time; an agent mid-edit
  can get stale answers. Mitigation: results carry a content hash (the snapshot already
  has `content_hash`); the agent re-queries after edits.

### Can it be solved another way?

Largely it already is, statically: **the compiler CLI + coded diagnostics is the
80/20.** Most of the "understand the program better" win comes for free from an agent
that compiles after each edit and reads the structured errors/fixes — no LSP plumbing
required. The LSP/DAP investment pays off for the *dynamic* questions (runtime state,
actual SQL, real values), which the headless inspector (#2) and MCP server (#3)
unlock. So: ship the static agent-context first (cheap, big win), then the headless
inspector (reuses the DAP work), then the MCP wrapper (broad reach).

### Bottom line

Feasible and worthwhile. Reframe from "give the agent the LSP" to "expose the
compiler's semantic + runtime facts through an agent-shaped API (CLI + MCP), with
token economy as a hard constraint." The static half is nearly free (it exists); the
dynamic half is a thin headless front-end over the debugger machinery just built.
The proof system is the secret weapon — it turns the compiler into a precise,
machine-checkable spec the agent can iterate against, which is a better debugging
signal than most languages can give a human, let alone an agent.