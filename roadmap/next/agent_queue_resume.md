# Agent resume-after over queues/workers (scale the handoff)

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

## Notes

Deliberately scoped OUT of the `humanActions` v1 so that landed synchronously
and completely. This item is the scalability follow-up the feature was designed
to accommodate.
