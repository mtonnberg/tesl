# Agent resume-after over queues/workers (scale the handoff)

## STATUS: IMPLEMENTED as a composition pattern (2026-07-08) — zero new language surface

The whole feature turned out to need **no new primitives**: it is a composition of
things Tesl already has, and the deliberate outcome (fewest moving parts) is a worked,
tested pattern rather than a new construct.

- **Agent enqueues slow work:** a tool the agent calls (`serverTools` handler, or a
  `tool` whose dispatch captures the conversation id) just `enqueue`s a job and returns
  "queued". The turn ends at once. The conversation id is CAPTURED (not model-supplied),
  so the model cannot point the work at another conversation.
- **Worker completes + fans out:** the `worker` does the slow work, then `publish`es to
  the conversation's SSE channel (an `Email.send` fits at the same point) **and resumes
  the conversation** — `conversationFrom` the persisted transcript → one more `converse`
  with the result as the message → `conversationJson` back. All existing surface.
- **"Active conversation awaiting" = the conversation id on the job.** Completion
  re-enters exactly that conversation. Nothing is suspended (a resumed turn is just
  another `converse`, run on the worker), so a never-completed job never pins a request —
  matching the non-blocking direction of the pool/SSE work (issue #31/#32).

Delivered: `example/learn/lesson70-agent-async-work.tesl` (two deterministic `api-test`s —
the tool enqueues and the turn returns; `processNextJob` runs the worker and the resumed
conversation's follow-up is `collect`ed off the SSE channel). Spec: LANGUAGE-SPEC §11.1
(AI agents). Manual: `tour.md`, `examples.md`, `ai-testing.md`.

**Implementation note (harness gotcha, folded into the lesson):** a `publish` issued
*inside* a helper fn that also runs a DB `transaction` is transaction-deferred and can be
lost; do the DB work (turn + persist) first and `publish` from the worker body afterwards.

**Not yet done (kept as future surface, below):** a first-class `awaitHumanAction` /
`resumeAgent` binding, a runtime awaiter-registry with broadcast-to-many, dedup/
exactly-once, and timeout sweeping. The pattern covers the single-awaiter case cleanly;
these are ergonomic/scale refinements to add only if the pattern proves too manual.

The original design follows.

## Motivation

`humanActions` (see `roadmap/completed/ai_agent_prompting_human_actions.md`)
landed with a **synchronous** resume-after: when the human completes a held-back
action in the browser, an ordinary HTTP handler appends `{action, handle,
result}` to the persisted conversation and runs another `converse` turn inline.
That is correct and simple, but it couples the resume turn to a live request and
does not scale to: many concurrent handoffs, long human latency (minutes/days),
slow provider turns, or an agent that should be *notified* when work it is
waiting on completes rather than being re-driven by whoever happens to POST.

The same shape recurs beyond human actions: an agent kicks off *any* slow/async
work (a batch job, an external webhook, another agent) and wants to continue when
it finishes. Queues are the natural backbone.

## Why it fits the current design

- Resume-after is already a **fresh turn**, not a suspended one — the runtime
  never holds continuation state (`agent.rkt` run-loop runs to completion; state
  is the developer-persisted transcript). A fresh turn is exactly what a queue
  job body runs. `agentRun` already exists and is meant to be invoked from a
  worker.
- The pool/SSE scale work (issue #31/#32) made leases blocking-with-503 and SSE
  delivery non-blocking precisely so long-lived work does not pin a slot. A
  human click that may never come must not hold a request thread — enqueue and
  return.
- The correlation `handle` minted with each `human-action-request` is already
  the join key a queue job would carry.

## Sketch (not yet designed in detail)

1. **Enqueue on request, not just on completion.** When the agent emits a
   `human-action-request`, optionally record `{conversationId, handle, action}`
   as a pending job so completion can be matched and (later) timed out.
2. **Completion → job, not inline turn.** The browser's "action done" POST
   enqueues a `resumeAgent` job carrying `{conversationId, handle, result}`
   instead of running `converse` in the request. A worker loads the
   conversation, appends the result, runs the turn, persists, and publishes the
   new reply on the existing SSE channel the frontend already listens to.
3. **Generalize beyond humans.** The same `resumeAgent {conversationId, handle,
   result}` job is how *any* completed async work (a finished queue job, an
   inbound webhook) re-enters an agent loop — a general "agent await" primitive.
4. **Timeouts / never-completed.** A pending handoff that is never completed
   should expire (a swept job), so a stalled human action does not leak state.

## Agent-enqueued async work (the general case)

The human-action handoff is one instance of a broader pattern: an agent tool
whose job is to **start slow work on a queue**, not to do it inline. A
serverTools endpoint (say `requestReport`) is granted to the agent, but its
handler only `enqueue`s a `GenerateReport` job and returns immediately
("queued, ref R"). The heavy lifting runs on the report-generator workers,
off the agent turn and off any request thread. This is strictly more scalable
than a tool that computes synchronously, and it is the same shape as a
`humanActions` request — the difference is only WHO does the work (a worker vs.
a human), so both should share the completion/resume machinery.

On completion the worker fans the result out through effects Tesl already has:

- **email** — `Email.send` to the requester (report ready / here it is);
- **publish → SSE** — `publish ReportStream(userId) …` so any browser subscribed
  to that channel updates live (the server→client path is already there);
- **resume the conversation** — enqueue the `resumeAgent {conversationId, ref,
  result}` job so the agent turn that asked for the report can continue.

So there is no bespoke "human vs. machine" plumbing: an agent enqueues work,
the worker on completion does {email, publish, resumeAgent} as appropriate.

### Active conversations awaiting an update (the crux)

A conversation that is **actively waiting** for a specific queued result must be
told when it lands — not merely have the result sit in a table until someone
next POSTs. Two delivery targets, both keyed by the correlation `ref`/`handle`:

- **the conversation** — its `resumeAgent` job runs the next turn with the
  result, and the reply is published on the conversation's SSE channel; a
  browser watching that conversation sees the agent resume by itself.
- **the UI at large** — the domain SSE channel (`ReportStream(userId)`) so
  non-conversation views (a dashboard, a bell) update too.

Design question this raises: how does the runtime know a conversation is
"active / awaiting `ref`" so completion can target it? Candidates:
- a pending-await record `{conversationId, ref, channel}` written when the agent
  enqueues the work (mirrors the human-action pending record in item 1), swept
  on completion or timeout;
- the worker, on completion, looks up awaiters by `ref` and enqueues one
  `resumeAgent` per waiting conversation + one `publish` per subscribed channel.

Fire-and-forget (no awaiter) stays valid: the worker just emails/publishes and
no conversation resumes. "Awaiting" is opt-in, recorded at enqueue time.

## Open questions

- Surface: a language-level `awaitHumanAction` / `resumeAgent` binding, or a
  documented convention over the existing `queue` + `converse` primitives (the
  minimal-addition path, consistent with how `humanActions` reused existing
  machinery)?
- Where the pending-handoff record lives (developer entity vs. runtime table)
  and who owns expiry.
- Delivery of the resumed reply: reuse the conversation's SSE channel (server→
  client, already there) — confirmed sufficient; no new inbound conduit needed.
- Exactly-once resume per `handle` (dedup) if the browser retries the completion
  POST.
- Awaiter registry: how a conversation registers "awaiting `ref`", how a worker
  looks up all awaiters on completion, and whether one completion can fan out to
  MANY waiting conversations (broadcast) or just the originator.
- Does an agent-enqueued tool return a `ref` the agent can mention to the user
  ("your report is queued as R"), and is that `ref` the same id the completion
  and the SSE update carry?
- Should the agent's turn END after enqueuing (report "queued", resume later) or
  be able to BLOCK-await a fast job? Prefer end-then-resume for scale; a bounded
  block may be worth it for sub-second work.

## Notes

Deliberately scoped OUT of the `humanActions` v1 so that landed synchronously
and completely. This item is the scalability follow-up the feature was designed
to accommodate.
