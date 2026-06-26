# Testing AI features deterministically

AI features are usually a nightmare to test: replies are non-deterministic, every
run costs tokens, and a green test today can flake tomorrow when the model drifts.
Tesl removes all of that. The **mock provider is a first-class testing primitive**:
you script exactly what the model "says" — its text replies *and* its tool-use
requests — and then assert on the structured outcome in ordinary `test "..."`
blocks. No API keys, no network, no cost, no flakiness, fully reproducible in CI.

The agent code under test is **identical** whether it runs against a real provider
or a mock. You build the agent once (parameterised over its `LlmProvider`), pass a
real `aiProvider ...` in production and a `mockProvider`/`mockToolProvider` in
tests. Nothing about the agent changes — only what feeds it.

The complete, runnable showcase is
[`example/support-assistant.tesl`](../example/support-assistant.tesl): a
capability-bounded support assistant with a read-only lookup tool, a guarded
mutating refund tool, and structured ticket triage — with eight developer-written
deterministic tests covering every primitive described below. Run them with
`tesl test example/support-assistant.tesl` (emit → `raco test`); all eight pass
with zero external dependencies.

## The mock providers

Two functions stand in for a real LLM. Both walk their script by call index, so
successive calls return successive entries.

- `mockProvider [text1, text2, ...]` — a scripted **text** provider. The first
  call returns `text1`, the second `text2`, and so on. Use it for plain `ask`,
  for `converse` turns, and for structured output (including retries, where you
  script a bad reply followed by a good one).
- `mockToolProvider [step1, step2, ...]` — a scripted **tool-calling** provider.
  Each step is either:
  - `toolUseStep name id argsJson` — the model requests a tool call, with the raw
    arguments JSON it "produced"; or
  - `textStep text` — the model emits final assistant text and stops.

  The agent loop consumes tool-use steps (dispatching the tool and feeding the
  result back) until it hits a `textStep`, exactly as a real tool-calling loop
  would against Anthropic or OpenAI — but deterministically.

## The accessors you assert on

`ask` returns plain text; `askReply` returns a richer `AgentReply` you can
inspect:

- `replyText reply` — the model's final assistant text (a `String`).
- `replyToolCalls reply` — how many tool round-trips happened (an `Int`). This is
  how you assert the **exact tool-call sequence length** — that the model took the
  steps you expect, not more and not fewer.
- `replyTokens reply` — the token usage reported by the (mock) provider.
- `decodeAs "T" json` — decode a JSON string into a typed value `T` through the
  same proof-carrying codec path an HTTP request body uses. Raises on malformed
  input. This is the foundation of both tool-arg validation and structured output.
- `askFor agent prompt decoder maxRetries` — ask for **structured output**: run
  inference, decode the reply with `decoder`, and retry (up to `maxRetries`) if
  the decode fails. Returns the typed value; only a well-typed value escapes.

For multi-turn chat: `converse conv prompt` returns a turn carrying both the reply
(`turnReply`) and the advanced conversation (`turnConversation`); inspect history
with `conversationLength` and `conversationJson` (which also lets you persist and
`conversationFrom`-restore a thread). See
[`tests/agent-conversation-tests.tesl`](../tests/agent-conversation-tests.tesl).

## Asserting tool dispatch and validated arguments

A tool is built with `tool name desc schemaJson validateFn dispatchFn` and attached
with `withTools agent [t1, t2]`. The model's raw arguments JSON is fed through
`validateFn` (typically `decodeAs "Args" argsJson`) **before** `dispatchFn` ever
runs, so dispatch only ever sees a validated, typed value — never raw JSON. Because
dispatch reads typed fields, asserting on the final reply proves validation
happened.

```tesl
test "lookup tool: validated args reach dispatch and the loop returns a final reply" requires [supportBot] {
  let call = toolUseStep "lookup_order" "call_1" "{\"orderId\":\"A-100\"}"
  let final = textStep "Your order A-100 has shipped."
  let mock = mockToolProvider [call, final]
  let agent = supportAgent mock
  let reply = askReply agent "Where is my order A-100?"
  expect (replyText reply) == "Your order A-100 has shipped."
  expect (replyToolCalls reply) == 1
}
```

### Malformed model output can't reach your code — and can't crash the run

If the model sends arguments that don't validate (e.g. a missing required field),
`validateFn`'s `decodeAs` raises, and the agent loop turns that into a
`tool_result` flagged `is_error` and **keeps going** — the model gets the error
back and can recover. The run does not throw. You assert this deterministically by
scripting bad args followed by a recovery text reply, then checking you still got a
normal final reply and that the (failed) call still counted as one round-trip.

### Guarded mutating tools

Put the guard *inside* the validated value (e.g. a `confirmed: Bool` field) and let
dispatch refuse the side effect when it's false. Then "did the mutation actually
happen?" is answerable purely by asserting on the tool result — script
`confirmed:true` to prove the action runs, `confirmed:false` to prove it's refused.
`example/support-assistant.tesl` does both.

## Asserting structured output and retries

`askFor` decodes the model's reply into a typed value and retries on decode
failure. Script a clean reply to test the happy path, or a junk reply followed by
valid JSON to **prove the retry fired** (the mock is consumed entry by entry, so a
retry means both entries are read):

```tesl
test "structured output: classifyTicket retries past a bad reply then decodes" requires [supportBot] {
  let mock = mockProvider ["not json at all", "{\"category\":\"shipping\",\"priority\":1}"]
  let triage = classifyTicket mock "Where is my package?"
  expect triage.category == "shipping"
  expect triage.priority == 1
}
```

## The AI boundary is a compile-time capability

A real provider performs outbound HTTP, so every inference call (`ask`, `askReply`,
`askFor`, `askWith`, `converse`, `agentRun`) **requires the `aiProvider`
capability**. Declare a domain capability that implies it
(`capability supportBot implies aiProvider`) and list it in `requires [...]` on the
function or `test` block that runs inference. A caller that omits it does **not
compile** — it's a `V001` error:

```
error[V001]: fn 'unguarded' uses ... callees requiring [aiProvider] but does not declare them
Hint: add `requires [aiProvider]` to the fn declaration
```

This gating applies even to mock-backed calls, because in production the same code
reaches the network. The type system makes it impossible to cross the AI boundary
by accident — the deterministic-testing guarantee extended to capabilities. (A
compile error can't live inside a passing test, so the example documents it as a
companion note rather than a `test` block.)

## See also

- [`example/support-assistant.tesl`](../example/support-assistant.tesl) — the full worked example with eight deterministic tests.
- [`tests/agent-tools-tests.tesl`](../tests/agent-tools-tests.tesl) — the tool-calling loop, validation, and retry primitives in isolation.
- [`tests/agent-conversation-tests.tesl`](../tests/agent-conversation-tests.tesl) — multi-turn `converse` and history persistence.
- [`tests/agent-run-tests.tesl`](../tests/agent-run-tests.tesl) — `agentRun` on a worker, streaming step events to subscribers.
- [best-practices.md](best-practices.md) — capability and validation patterns.
