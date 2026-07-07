# AI agent prompting human actions

## STATUS: IMPLEMENTED (2026-07-08)

Shipped as `humanActions MyServer user : List Tool` — the checker-verified
complement of `serverTools`, resolved exactly as the design below prescribes.

- **Surface / checker:** new special form mirroring `serverTools`
  (`checker.ml`); computes the EXCLUDED endpoint set (`endpoints \ included`)
  per call site from the user's declared proof; `human_actions_sites` threaded
  through the metadata tuple. Registered in `Tesl.Agent` exports.
- **Inert lowering:** `(__tht_human-actions "ServerName" (list rows…))` —
  server NAME only, no user, no handler (`emit_racket.ml`). Runtime
  `tesl/human-actions.rkt` builds inert tools whose dispatch mints a correlation
  `handle` and returns a `{kind,server,action,args,handle}` descriptor as the
  tool_result; it can reach no route or handler. Charges **zero** capability.
- **Frontend (typed value, not URL):** `tesl generate elm|ts` emits a per-server
  `<Server>HumanAction` tag union + request decoder that rejects any `action`
  the server did not declare; the real URL is resolved by the generated endpoint
  client, never the wire (`emit_elm.ml`, `emit_ts.ml`).
- **Resume-after:** re-invoke (not suspend) — the completed `{action,handle,
  result}` is appended to the persisted conversation and run as another
  `converse` turn. Shown in the lesson.
- **Decisions honored:** prefill args carried (advisory, structured); full result
  on resume; correlation handle = server-minted random hex.
- **Tests:** `compiler/test/test_human_actions.ml` (9), `tests/agent-runtime-tests.rkt`
  PILLAR 8 (2), `tests/human-actions-tests.tesl` (4, in ci.sh AI_TESL).
  Spec: LANGUAGE-SPEC §11.1 (AI agents). Lesson:
  `example/learn/lesson69-agent-human-handoff.tesl`. Manual: `tour.md`,
  `examples.md`, `ai-testing.md`.
- **Deferred (own roadmap item):** completion delivery over queues/workers for
  scale — see `roadmap/next/agent_queue_resume.md`. v1 resume-after is a plain
  synchronous `converse` turn driven by an HTTP handler.

The original design follows.

## Problem

When an ai-agent has a set of tools via `serverTools` and the human has another
(overlapping) set, it would be nice for the agent to know about the actions it is *not*
allowed to do but *can ask the human to do* — so the frontend can dynamically render a
button that performs that action.

A Tesl developer could build this by hand: add a tool that returns some JSON the frontend
renders as a button. The question is whether this deserves first-class language support.

- **Benefit of first-class:** an easy, one-way-to-do-it path to building *safer*
  ai-driven systems, instead of every developer inventing their own.
- **Risk:** language bloat.

## Design (resolved)

First-class, but built as the **complement of `serverTools`** — a thin projection over
machinery that already exists, not a new subsystem. This is what defuses the bloat risk.

### Core framing: the mirror of serverTools

`serverTools S user` exposes the **intersection** — endpoints whose auth predicates are
covered by `user`'s declared, checker-verified proof annotation. The *excluded* set is
already computed at the same call site (`server_tools_sites`).

This feature exposes the **difference** — endpoints only the human may trigger:

```
serverTools  S user : List Tool          -- agent may call (agent-authority ∩ user-authority)
humanActions S user : List HumanAction   -- only the human may trigger (the difference)
```

Both are derived from the **same** verified annotations. No new discharge logic, no
hand-restated auth predicates (that restatement is the root anti-pattern behind Tesl's
soundness bugs — see stability-root-diagnosis).

Scope is the **same principal, agent ⊂ human authority** case: the agent is deliberately
granted narrower authority than the human it acts for. `humanActions` surfaces exactly
what the human can do that the agent was not trusted to do autonomously.

Explicitly **out of scope:** a "human confirm even if the agent *could* do it" gate. That
would make correctness depend on the agent *choosing* not to act — i.e. on LLM
non-determinism. This design guarantees the agent *cannot* perform the action, which is a
security property; "chooses not to" is not.

### Enforcement principle: *cannot*, not *chooses-not-to*

The action must be un-performable by the agent by construction, even under prompt
injection. The affordance the agent produces is a **typed value, never a URL**.

An agent-controlled URL string means the agent picks target + label + args = injection and
false-labelling surface. A generated typed action closes three of those outright:

- **Fabrication** — the constructor set *is* the excluded-endpoint set. The agent cannot
  name an action that does not exist.
- **False label** — rendering is generated Elm keyed on the constructor, not an
  agent-supplied string.
- **Redirection** — the route is baked into generated Elm per constructor. The agent
  never sees or sets it; the browser makes the call with the user's own session.

The `HumanAction` ADT is **auto-derived** from the server's excluded-endpoint set (payload
= the endpoint's input type). Developers must **not** hand-declare the constructors —
that reintroduces hand-restatement. Reuses the existing Elm codec generation (same path as
the tolerant Elm/TS decoders).

### The invariant that makes "cannot" true (implementation-critical)

The `HumanAction` descriptor must be **inert**: it carries endpoint *identity* only, never
the handler closure.

- The endpoint is excluded from the agent's tool set (`serverTools` already does this).
- The tool/path that produces a `HumanAction` **constructs a descriptor — it must not
  close over or invoke the handler.** Note the contrast with issue #30: normal agent tool
  dispatch *executes* fns. Here the opposite is mandatory — in-process dispatch of a
  `HumanAction` must resolve to nothing. Resolution to a real handler happens *only* on the
  browser round-trip.
- The endpoint stays mounted (the browser must reach it) and re-checks the user's real
  proof server-side.

If any in-process path can turn the descriptor back into a call, the guarantee is gone.
This is the invariant to nail in the design and pin with a test.

### Residual policy knob: payload arguments

The type closes label / URL / fabrication. It does **not** by itself close payload args —
if the agent supplies a constructor's payload (amount, recipient, …), an injected agent
picks bad values. Decide per field:

- **Sensitive fields** → human fills them in the browser (generated typed form, free from
  the ADT). The agent supplies at most a *displayed, editable* default.
- **Non-sensitive fields** → the agent may prefill.

Both boundaries (browser + server) validate against the generated type, so this is a
policy knob, not new machinery.

### Resume-after (v1 requirement)

The browser owns the call, so the completion signal is not in-process. The agent must be
able to **continue reasoning after the human acts**: the browser result re-enters the
agent loop as a fresh event (action identity + result), and the agent resumes its turn.

This is the hard part of the feature — the typed button is easy. Design work:

- A correlation handle minted with the `HumanAction` so the browser result can be matched
  back to the awaiting agent turn.
- A re-entry path in the agent loop that ingests `{action, result}` as a new event and
  resumes, without re-granting the agent the excluded capability.
- Decide the wait model: does the agent turn *suspend* pending human action (durable, so a
  slow/never human click doesn't pin a run), or does it end and get *re-invoked* on the
  result event? Prefer re-invocation for the same reason the pool/SSE work went
  non-blocking — don't pin a slot on human latency (see issue-31-32-pool-sse-scale).

### Surface sketch

```
-- server declares endpoints as usual; auth predicates on each handler

humanActions myServer user : List HumanAction   -- auto-derived complement of serverTools

-- agent turn: agent selects an action + (permitted) args, returns a HumanAction value;
-- runtime emits it to the frontend, does NOT execute it.

-- Elm (generated): parser + typed form + submit button per constructor;
-- on click -> POST real endpoint with user's session -> result -> re-enter agent loop.
```

### Open items to settle before implementation

1. Correlation-handle shape and its trust properties (must not be forgeable by the agent
   into a *different* action).
   1. I'm agnostic/do not know the best option
2. Suspend-vs-re-invoke for the resume-after wait model.
   1. I'm agnostic/do not know the best option
3. Per-field sensitivity annotation syntax for the payload-arg knob (default: all
   human-filled unless marked agent-prefillable).
   1. DECISION: Prefilled is fine, the data must be structured so that the frontend easily can display it in a clear way
4. What the agent sees of the result on resume (full handler return vs a redacted summary).
   1. DECISION: FULL or none (I'm agnostic). Full is best but none is ok (just that the action is taken)
