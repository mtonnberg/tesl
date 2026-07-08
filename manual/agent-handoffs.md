# Agent handoffs: `humanActions` and long-running work

Two features, one idea. An agent turn is short and synchronous. Sometimes the
thing that needs to happen **cannot or should not** happen on that turn:

- it needs a **human** (the agent isn't trusted to do it), or
- it needs a **worker** (it's slow and shouldn't block the turn).

Both are handled the same way — **resume-after**: the turn emits an intent and
ends; an external actor (human or worker) completes the work; the conversation
then *resumes* with the result as a new turn. The runtime never suspends a turn,
so nothing pins a request while you wait.

```
            ┌─ agent turn (short, synchronous) ─┐
 user  ───► │  … model calls a handoff tool …   │ ───► reply now ("queued" / "ask the human")
            └───────────────┬───────────────────┘
                            │ intent + correlation id
            ┌───────────────▼───────────────────┐
   human clicks a button   OR   worker runs job   (elsewhere, later)
            └───────────────┬───────────────────┘
                            │ result + same correlation id
            ┌───────────────▼───────────────────┐
 resume ──► │  converse(load transcript, result)│ ───► follow-up published on the conversation's SSE channel
            └───────────────────────────────────┘
```

---

## Feature 1 — `humanActions` (agent → human)

The agent is deliberately given **narrower authority than the human**. Anything
the human can do that the agent may not becomes a *human action*.

`serverTools S user : List Tool` gives the agent the endpoints the user's
declared proof **covers**. `humanActions S user : List Tool` is the exact
**complement** — the endpoints it does **not** cover. Together they partition the
server's endpoints, disjoint and complete. (Scope the agent's `user` narrower
than the human's real authority and the held-back endpoints, e.g. admin-only
ones, fall into `humanActions`.)

```tesl
tools: List.append (serverTools NotesServer user) (humanActions NotesServer user)
```

A `humanActions` tool is **inert by construction** — the guarantee is "the agent
*cannot*", not "the agent *chooses not to*":

- the runtime builder is handed only the server **name** and endpoint metadata,
  never the server value or a handler closure, so there is no in-process path
  from the tool to a call;
- dispatching it returns a `human-action-request` descriptor
  `{ kind, server, action, args, handle }` as the tool_result — the agent can
  only *choose which held-back action to request and prefill its args*;
- `humanActions` charges **no** capability (the opposite of `serverTools`).

The frontend makes it a typed button, not a URL the agent controls.
`tesl generate elm|ts` emits, per server, a `<Server>HumanAction` tag union and a
request decoder that **rejects any `action` the server did not declare** (a
compile-time allowlist), and the real endpoint URL is resolved by the generated
endpoint client the app calls per case — never taken from the wire. So a
prompt-injected agent can neither fabricate an action, relabel it, nor redirect
it. The human clicks; their browser calls the real endpoint under their **own**
session (auth re-checked server-side).

Lesson: [`lesson69-agent-human-handoff.tesl`](../example/learn/lesson69-agent-human-handoff.tesl).

## Feature 2 — long-running work over a queue (agent → worker)

The agent starts work that is **slow**, not forbidden. The tool it calls only
`enqueue`s a job and returns "queued"; the turn ends at once. A `worker` does the
work later and, at completion, `publish`es to the conversation's SSE channel
(and/or `Email.send`s) **and resumes the conversation**.

```tesl
# tool dispatch (captures the conversation id, so the model can't retarget it):
enqueue ReportJob { conversationId: conversationId, kind: spec.kind }
"Queued your report."

# worker, on completion:
let reply = resumeConversation resumeAgent job.conversationId resultMsg  # conversationFrom → converse → save
publish ChatStream(job.conversationId) Chunk { content: "report: …" }
publish ChatStream(job.conversationId) Chunk { content: String.concat "text: " reply }
```

This adds **no new language surface** — it is pure composition of `enqueue`,
`worker`, `publish`, and the conversation primitives (`conversationFrom` /
`converse` / `conversationJson`) that already existed. The conversation id
carried on the job is the "this conversation is awaiting that result" record;
completion re-enters exactly that conversation.

Lesson: [`lesson70-agent-async-work.tesl`](../example/learn/lesson70-agent-async-work.tesl).

---

## Why they are the same feature

|                        | `humanActions`                          | long-running work                       |
|------------------------|-----------------------------------------|-----------------------------------------|
| Why off the turn       | agent **may not** do it                 | agent **should not block** on it        |
| Who completes it       | the human, in the browser               | a `worker`                              |
| What the agent emits   | a `human-action-request` descriptor     | an enqueued job                         |
| Correlation key        | `handle`                                | the job's `conversationId`              |
| How it resumes         | new `converse` turn with the result     | new `converse` turn with the result     |
| Runtime suspends?      | no — a fresh turn                        | no — a fresh turn                        |
| Result delivery        | SSE channel (+ HTTP)                     | SSE channel (+ email)                    |

Both are **resume-after**: emit intent → turn ends → external completion → the
conversation continues itself with `converse`. Neither holds a request open, so
both scale to slow humans and slow jobs the same way (matching the non-blocking
direction of the pool/SSE work).

## New moving parts (the point was to add as few as possible)

- **`humanActions`** — one new builtin (mirrors `serverTools`: a checker special
  form + inert `__tht_human-actions` lowering + a small `tesl/human-actions.rkt`
  that only builds inert descriptors), plus a generated frontend decoder. No new
  runtime subsystem, no new agent loop, no discharge logic.
- **Long-running work** — **nothing new**. It is a documented, tested pattern
  over `enqueue` / `worker` / `publish` / conversation primitives.

Deferred (only if the pattern proves too manual): a first-class `resumeAgent`
binding with an awaiter-registry, broadcast-to-many, dedup, and timeout sweeping
— see `roadmap/completed/agent_queue_resume.md`.
