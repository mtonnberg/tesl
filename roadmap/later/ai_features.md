# AI Features — Tesl for the AI age

> **Status:** Later · **Effort:** XL (language + runtime, phased) · **Shape:**
> vision item with an executable Tier 0 (mostly a library; the only compiler-side
> touch is a vector column type for RAG).

## Why now

Two goals, weighted equally:

- **(A) The best language to _build AI features into_ your app** — adding a
  chatbot, a tool-calling agent, or an MCP integration to a Tesl backend should be
  a first-class, declarative, *safe-by-construction* language feature.
- **(B) The best language for AI _to write_** — when an agent authors a Tesl
  backend, the language's guarantees should make its output correct-by-construction,
  and its errors/help legible enough for the agent to self-correct.

The thesis is that these are the *same* bet Tesl already made. Tesl's identity is
**proof-carrying validation + explicit capabilities** (README: "validate once at
the boundary, then carry the result as evidence … make capabilities and side
effects explicit"). That is *exactly* what agentic AI needs:

- **LLM output is untrusted input.** Tesl already coerces untrusted JSON into
  typed, proof-carrying values at the boundary (`codec` + `via` proof chains).
  Structured model output becomes **provably valid before it reaches business
  logic** — with the same machinery, and the same retry-on-failure, Tesl uses for
  HTTP request bodies today.
- **Agent tool-use is an authority problem.** Tesl already makes effects explicit
  and statically checks them (`requires […]`, `capability … implies`). An agent's
  tool authority can therefore be **provably least-privilege at compile time** —
  the headline differentiator for *safe* agentic AI.
- **A tool is just a typed function.** A signature (typed params, return,
  capabilities, even proofs) *is* the tool schema. One source of truth, no
  parallel tool-definition language to drift.

AI is not a bolt-on for Tesl. It is the next expression of the language's thesis.

## Positioning — Tesl as an AI-first language

This item is also an argument to **re-describe Tesl itself**. Today's pitch is
"unbreakable, production-ready APIs without the infrastructure tax." That stays
true — but it undersells the moment. The proposed positioning:

> **Tesl — the AI-first language for building software.**
> Build AI features into your app as first-class, capability-bounded citizens —
> and build *with* AI safely, because types and proofs let you trust code you
> didn't read.

"AI-first" here is a claim with three concrete legs, not a sticker:

1. **AI features are first-class.** Agents, tools, structured output, and MCP are
   language constructs (capability-bounded, proof-validated), not glued-on SDKs —
   the whole of this document.

2. **AI authors Tesl safely.** The compiler is the verifier: a model that forgets a
   validation, leaves auth implicit, or over-grants a capability gets a *compile
   error*, not a production incident (Goal B). Generation is cheap; Tesl makes the
   *verification* cheap too.

3. **The trust argument — the deepest one. Local inspection, safe extrapolation.**
   In the AI era the bottleneck isn't writing code, it's *trusting* code nobody
   fully read. A human cannot review everything an LLM emits — but Tesl's
   guarantees are **local and compositional**:
   - validation is carried as evidence, so a value that is typed `::: ValidOrderId`
     *is* valid everywhere it flows — you don't re-audit the path;
   - auth requirements live in the signature, not in middleware folklore;
   - capabilities make every side effect visible at the boundary;
   - so reading a **small, high-leverage slice** — the signatures, the proofs, the
     capability grants, the boundary checks — lets you **safely extrapolate to the
     whole**, because the compiler guarantees the rest. The type+proof system is a
     *trust amplifier*: review shrinks from "all the code" to "the contracts."

   Layer Tesl's tests on top — they pin down *intent* (the app does what we meant)
   where types/proofs pin down *structure* (it can't do what we forbade) — and you
   get assurance over AI-generated code that scales the way human review cannot.

That is what earns "AI-first": not that Tesl talks to models, but that it is the
language where **machine-generated code is safe to trust at human-reviewable cost.**

## Goals & success criteria

- A developer adds a working, capability-bounded **chatbot/agent** to a Tesl API
  in a handful of declarative lines.
- An agent's **tool authority is provably bounded** at compile time; a tool that
  needs a capability the agent wasn't granted is a *compile error*, not a runtime
  surprise.
- **Model output never reaches business logic unvalidated** — it lands in a typed,
  proof-carrying value or the call is retried/rejected.
- **Every build emits an MCP server** from the API (no separate generate step),
  and it **runs in-process with the Tesl server** — same host/port, no extra
  process, port, deployment, or config. Run the API and its MCP server is live.
- The MCP server **enforces the same `auth` as the API** — auth'd endpoints stay
  auth'd as MCP tools (same authers, same proofs, same identity), with the option of
  a **different auther** for programmatic MCP clients. No second auth model.
- A Tesl API can **consume external MCP servers** as capability-gated tools.
- **The same agent runs on a shared key or a per-user/per-provider key (BYOK)** —
  the provider binding is resolved per call; the agent's capabilities never change
  with whose key is used.
- **Attaching an external MCP server or a reusable "skill" pack to an agent is one
  declarative line — yet cannot silently widen the agent's authority.** Every
  imported tool is capability-tagged and still bounded by the agent's grant.
- Tesl **errors and help are legible enough for an AI agent** to author Tesl and
  fix its own mistakes (ties into `improved_devx.md`).
- **An agent acting for a user can only access that user's data** — entitlement is
  *proven* (queries/tools carry per-resource proofs), not filtered-and-hoped, so
  prompt injection is bounded to the user's own access. See *Entitlement*.
- **Retrieval (RAG) composes existing primitives** — a vector column on the Postgres
  you already run + a capability-gated, entitlement-scoped retrieval tool; answers
  can carry a proof of their sources (`SourcedFrom`). See *Retrieval & RAG*.
- Tesl's **public positioning is updated to "AI-first"** (README/site/manual),
  leading with the trust argument — *types + proofs make AI-generated code safe to
  review at a fraction of the surface*. See *Positioning* above.

## Current state — what we build on

Almost every primitive an AI feature needs already exists; only the AI-specific
seam is missing.

- **DSL block pipeline** (proven by `queue`/`channel`/`cache`/`email`):
  `compiler/lib/token.ml` → `parser.ml` (`parse_*_form`, dispatched in
  `parse_top_decl`) → `ast.ml` (`*_form` added to `top_decl`) → `checker.ml` →
  `emit_racket.ml` (`emit_*`) → a `tesl/*.rkt` runtime macro (`define-*`). Adding a
  new top-level block is a well-trodden path.
- **Capability system:** `capability … implies […]` declarations; `requires […]`
  on functions/handlers; static enforcement in
  `compiler/lib/validation_capabilities.ml` (`collect_needed_capabilities`,
  `check_handler_capabilities`, with transitive closure of `implies`); runtime
  enforcement via `dsl/capability.rkt` (`require-capabilities!`).
- **Proof + codec validation:** `compiler/lib/proof_checker.ml`; `codec` blocks
  with `via` proof chains coerce untrusted JSON into typed proof-carrying values
  (see `example/todo-api.tesl` — `record NewTodo` + `codec NewTodo` with
  `via (isSafeTitle && lengthLessThan30 && containsAnA)`).
- **Outbound HTTP** (to call a provider): `tesl/http-client.rkt`
  (`HttpClient.get/post/…`), gated by the `httpClient` capability.
- **Secrets/config** (API keys): `tesl/env.rkt` (`env`, `envInt`).
- **Async + streaming** (agent loops, token streaming): `tesl/queue.rkt`
  (jobs + pub/sub via PostgreSQL `NOTIFY`) and `tesl/sse.rkt` (Server-Sent Events).
- **API IR seam:** `tesl generate ir` (alongside `ts`/`elm`) already serializes the
  API surface to JSON — the natural basis for MCP server generation.
- **AI-authoring surfaces already planned:** `roadmap/next/improved_devx.md`
  (AI+human help system, legible errors); the README's "concatenate all docs for
  LLMs" command.
- **Gap:** there is no AI/LLM/agent feature today (a single incidental mention in
  the repo). This is greenfield on top of mature primitives.

## Central analysis — is a declarative `agent {}` block enough?

The hypothesis (and the preferred direction) is a **declarative-only** block, in
the same family as `queue`/`cache`/`email`. The question is whether that is
*sufficient and feasible*, or whether it forces awkwardness that a small
lower-level primitive would avoid. Verdict first, then the reasoning.

**What declarative expresses cleanly:**

- Agent identity: model, system prompt, generation parameters.
- Tool binding: a list of typed Tesl functions the agent may call.
- The capability grant that bounds the agent.
- Session/conversation backing (a `database`/`entity`, like other blocks).
- A streaming channel for token output.

These cover the three headline experiences — **tool-calling agents, chatbots, and
MCP** — without an escape hatch.

**Where declarative-only strains:**

1. **One-off completions** inside a handler ("summarize this comment") where
   declaring a whole long-lived `agent` is ceremony.
2. **Dynamically constructed prompts/params** computed from request data.
3. **Structured extraction** — "call the model, give me a typed `Invoice`" — which
   is a single typed call, not an agent loop.
4. **Custom multi-step orchestration** — branching logic *between* tool calls.

**Recommendation (clarity, not a coin-flip):** make the declarative `agent {}`
block the **primary surface** — it fully carries the headline features — and add
**exactly one minimal typed escape-hatch primitive** for cases (1)–(3):

```tesl
-- one-shot completion, decoded into a typed, codec-validated value:
let summary: Summary = ask SupportAgent "Summarize:\n${comment}" into Summary via summaryCodec
```

Case (4), multi-step orchestration, stays in **ordinary handler control flow**
calling the agent/primitive — *not* a bespoke workflow DSL (explicitly out of
scope for the first cut; revisit only if real usage demands it). This keeps the
language surface small, idiomatic, and feasible while removing the one-completion
awkwardness that pure-declarative would otherwise impose.

## Proposed design

### The `agent {}` block (primary surface)

```tesl
agent SupportAgent {
  provider:     anthropic              -- where the LLM lives: anthropic | openai | local
  model:        "claude-opus-4-8"
  apiKey:       env("ANTHROPIC_API_KEY")   -- secret from env, never inline
  database:     SupportDb              -- conversation/session persistence
  systemPrompt: "You are a support agent for ACME."
  tools:        [lookupOrder, refundOrder]   -- typed Tesl functions
  maxTokens:    2000
}
```

The **`provider`** field selects where the model lives. For a self-hosted or
local model (Ollama, vLLM, an OpenAI-compatible gateway), `provider: local` takes
an explicit **`endpoint`** (and the API style it speaks):

```tesl
agent LocalAssistant {
  provider: local
  endpoint: env("LLM_BASE_URL")        -- e.g. http://localhost:11434/v1
  model:    "llama-3.3-70b"
  -- apiKey optional for local
  …
}
```

Provider, endpoint, and key on the block are the agent's **default** binding, so
one service can mix a hosted model for one agent and a local model for another.
Shared secrets come from `env` (reusing `tesl/env.rkt`), never literal strings.

### Per-user keys & providers (bring-your-own-key)

The block's `provider`/`apiKey`/`model` are a static *default* — fine for a wholly
internal chatbot where every user shares one key. But two common cases need the
binding resolved **per request**: **bring-your-own-key** (each user supplies their
own key) and **per-user provider/model** (user A on OpenAI, user B on Anthropic).

The fix is to separate two axes that the current block conflates:

- **Behavior** (system prompt, tools, capabilities, generation params) — *static*,
  shared, declared on the agent.
- **Provider binding** (provider kind + key + model + endpoint) — a *value* that
  can be resolved at the call site.

So the agent declaration carries a default binding, and `ask`/`agentReply` accept
an optional **`using <provider binding>`** resolved per call. The shared case
stays a one-liner; BYOK becomes "load the user's key, pass it":

```tesl
-- per-user keys are user data, not env: stored in the DB, encrypted at rest
entity UserLlmKey table "user_llm_keys" primaryKey userId {
  userId:   UserId
  provider: String          -- "anthropic" | "openai" | …
  apiKey:   String @encrypted
  model:    String
}

-- resolve a binding for this user, falling back to the shared key
fn providerFor(user: User) -> LlmProvider
  requires [supportDbRead] =
  case selectOne k from UserLlmKey where k.userId == user.id of
    Something k -> LlmProvider { provider: k.provider, apiKey: k.apiKey, model: k.model }
    Nothing     -> LlmProvider { provider: anthropic, apiKey: env("ANTHROPIC_API_KEY"), model: "claude-opus-4-8" }

handler chat(requestUser: User ::: Authenticated requestUser, message: String)
  -> stream AgentReply
  requires [supportAi, supportDbRead] =
  agentReply SupportAgent
    using providerFor(requestUser)     -- per-user provider + key, resolved at call time
    for requestUser
    message
```

**Capabilities are a separate axis and do not change.** The provider binding
decides *whose account pays and which model answers*; capabilities decide *what the
agent may do* (its tools and effects). Swapping in a user's key never widens
authority — `supportAi` still bounds the tools, and `aiProvider` still gates "may
call an LLM at all." BYOK changes the credential, never the capability set. (This
also dovetails with per-user rate limits: with BYOK, the user's own key carries
their cost and quota.)

### Tools are typed functions; the schema is derived

A tool is an ordinary Tesl function. Its signature — typed parameters, return
type, capabilities, and even proof obligations — *is* the tool schema. The `doc`
string (the same one the MCP server uses) becomes the tool description:

```tesl
fact ValidOrderId (orderId: String)

check isOrderId(orderId: String) -> orderId: String ::: ValidOrderId orderId =
  if String.startsWith orderId "ord-" then
    ok orderId ::: ValidOrderId orderId
  else
    fail 400 "Malformed order id"

fn lookupOrder(orderId: String ::: ValidOrderId orderId) -> Maybe Order
  doc "Look up a single order by its id."
  requires [supportDbRead] =
  selectOne order from Order where order.id == orderId

fn refundOrder(orderId: String ::: ValidOrderId orderId, amountCents: Int) -> RefundResult
  doc "Refund an order. amountCents must not exceed the order total."
  requires [supportDbWrite, payments] =
  -- …
```

The compiler (1) **derives the provider tool schema** from the signature, and
(2) **validates the model's tool-call arguments back into typed values** through
the same `check`/codec path an HTTP request uses — so the model's `orderId` string
is run through `isOrderId` *before* `lookupOrder` executes, and a malformed
tool-call argument fails validation instead of running with ill-typed input.

### Native structured tool-calling (how the schema reaches the model)

The format is **not** prompt-engineered. The runtime uses each provider's native
tool API: the compiler-derived JSON Schema is sent as the tool definition, and the
model replies with a structured tool-call block — not free text we parse. From the
`refundOrder` signature above, the compiler derives:

```json
{
  "name": "refundOrder",
  "description": "Refund an order. amountCents must not exceed the order total.",
  "input_schema": {
    "type": "object",
    "properties": {
      "orderId":     { "type": "string", "description": "..." },
      "amountCents": { "type": "integer" }
    },
    "required": ["orderId", "amountCents"],
    "additionalProperties": false
  }
}
```

The `tesl/agent.rkt` runtime sends that on every turn via `http-client.rkt`. To
**Anthropic** it goes in `tools[]` (the shape above is already Anthropic's), and
the model returns a `tool_use` content block:

```json
// Anthropic response content
[{ "type": "tool_use", "id": "tu_01",
   "name": "refundOrder",
   "input": { "orderId": "ord-123", "amountCents": 4999 } }]
```

To **OpenAI** the same schema is wrapped as a function tool, with strict decoding
turned on so arguments are constrained to the schema at the token level:

```json
// OpenAI request
"tools": [{ "type": "function", "function": {
  "name": "refundOrder",
  "description": "Refund an order. amountCents must not exceed the order total.",
  "strict": true,
  "parameters": { /* the same JSON Schema */ }
}}]
// OpenAI response → choices[].message.tool_calls[].function.arguments (a JSON string)
```

The provider layer normalizes both into one internal shape, so the rest of the
loop is provider-agnostic. The runtime then validates `input` against the Tesl
`check`/codec (here `isOrderId`), dispatches `refundOrder` **in-process**, and
sends the result back as a `tool_result` referencing `tu_01`:

```json
{ "type": "tool_result", "tool_use_id": "tu_01",
  "content": "{\"Refunded\":4999}" }
```

For a **local** model that lacks a native tool API, the same JSON Schema drives
**grammar-constrained decoding** (e.g. llama.cpp GBNF, vLLM/Outlines) so output
still conforms by construction — the schema is the single source of truth across
all three providers.

### Capability-bounded authority (the differentiator)

```tesl
-- the agent may read orders and issue refunds — and nothing else
capability supportAi implies aiProvider, supportDbRead, supportDbWrite, payments

agent SupportAgent {
  provider:     anthropic
  model:        "claude-opus-4-8"
  apiKey:       env("ANTHROPIC_API_KEY")
  database:     SupportDb
  systemPrompt: "You are a support agent for ACME. Be concise."
  tools:        [lookupOrder, refundOrder]
}

handler chat(requestUser: User ::: Authenticated requestUser, message: String)
  -> AgentReply
  requires [supportAi] =
  telemetry "support.chat" { user.id = requestUser.id }
  agentReply SupportAgent for requestUser message   -- streams tokens over SSE
```

The compiler enforces that **the agent's granted capabilities cover the union of
its tools' capabilities**. If `lookupOrder` or `refundOrder` needed a capability
`supportAi` doesn't imply (say `email`), that's a *compile error* — the agent can
never call a tool more powerful than its own grant. Provable least-privilege for
AI tool-use, extending the existing check in `validation_capabilities.ml` rather
than inventing a new mechanism.

Capabilities are the *coarse* gate ("what kinds of effect"). Per-resource
entitlement ("whose data") is a separate, finer gate handled by the proof system —
see *Entitlement* for how the two compose to bound an agent to a user's own access.

### Provably valid structured output

Model output is untrusted JSON, so route it through the existing `codec` + `via`
proof chain: it arrives as a typed, proof-carrying value or the call is retried.

The cleanest pairing with Tesl's strict types is **classifying fuzzy text into an
ADT** — fuzzy in, closed-set out. The sum type *is* the contract: the model can
only land on one of the named cases, and any `case` over the result stays
exhaustive:

```tesl
type Intent = Question | Complaint | Praise | Cancellation | Other

fn classifyIntent(message: String) -> Intent
  requires [supportAi] =
  ask SupportAgent "Classify the customer's intent:\n${message}" into Intent via intentCodec
  -- decoded by intentCodec; an out-of-set answer fails decode and is auto-retried,
  -- so downstream `case intent of …` never sees an unexpected value
```

The same mechanism scales from a single ADT to a full record with per-field
proofs — here the model classifies a ticket, and the result *cannot* reach
business logic unless it satisfies the same checks any other input would:

```tesl
type Priority = Low | Normal | Urgent

record Triage {
  category: String   ::: KnownCategory category
  priority: Priority
  summary:  String   ::: LengthLessThan30 summary
}

-- one-shot, typed extraction (the minimal `ask` primitive, see below)
fn triageTicket(body: String) -> Triage
  requires [supportAi] =
  ask SupportAgent
    "Classify this support ticket as JSON matching Triage:\n${body}"
    into Triage via triageCodec   -- decoded by triageCodec, validated by its `via` checks,
                                  -- auto-retried on failure; never returns an invalid Triage
```

### Chatbot / conversation

Session state persists via an `entity`/`database` (already first-class); tokens
stream to the browser over `tesl/sse.rkt`; long or multi-turn agent loops run as
background jobs over `tesl/queue.rkt`. No new infrastructure — these are composed.
The agent's `database:` is where turns are stored; a handler resumes a named
conversation and streams the reply:

```tesl
entity Message table "messages" primaryKey id {
  id:             String
  conversationId: String
  role:           String        -- "user" | "assistant"
  content:        String
  createdAt:      PosixMillis
}

handler sendMessage(
  requestUser:    User ::: Authenticated requestUser,
  conversationId: String ::: ConversationId conversationId,
  message:        String
) -> stream AgentReply           -- response streams over SSE as tokens arrive
  requires [supportAi] =
  agentReply SupportAgent
    for requestUser
    in conversation conversationId   -- prior turns loaded from SupportDb
    message
```

### MCP server — always built, never a separate step

An MCP server is **emitted on every build**, not via an opt-in `tesl generate mcp`
command, and it **runs as part of the Tesl server itself — no extra infrastructure
from the user**. The same `serve` that starts the API mounts the MCP server
**in-process**, on the **same host and port** (e.g. at `/mcp`): no second process,
no separate port to expose, no extra deployment, no config. If the API is running,
its MCP server is running. This reuses the existing `dsl/web.rkt` routing/serve
path — the MCP endpoint is just another route the compiler wires up automatically.

MCP thus becomes part of the language story the way routing and validation already
are — "common API infrastructure part of the language, not an afterthought"
(README). Every Tesl API is an MCP server for free; if you change an endpoint, its
tool definition changes in lockstep, with no second artifact to forget and nothing
extra to run.

This raises the bar on the IR, though: an MCP *tool* needs more than a route and a
type. A good tool definition needs a natural-language **description**, **per-field
descriptions**, **safety annotations**, and **exposure control** — most of which
the `api`/`server`/`handler` blocks don't capture today. So the build-time MCP
server motivates a small amount of extra metadata in those blocks.

### Extra metadata the `api` / `server` / `handler` blocks need

The goal is to add the *minimum* that yields a high-quality MCP surface, and to
**derive whatever we can** from information Tesl already has (method, types,
proofs, capabilities) rather than make authors repeat themselves.

- **Endpoint description** — a doc string per endpoint, used verbatim as the MCP
  tool description (the single most important field for an LLM choosing a tool).
  An optional `mcp` clause controls exposure and the tool name; the safety
  annotation is derived (see below) but can be overridden:

  ```tesl
  api OrdersApi {
    get "/orders/:orderId"
      doc "Fetch a single order by its id."            -- → MCP tool description
      mcp expose as "get_order"                        -- tool name override
      auth requestUser: User ::: Authenticated requestUser via cookieAuth
      capture orderId: String ::: ValidOrderId orderId via orderIdCapture
      -> Order ? FromDb (Id == orderId)                -- (derived: read-only)

    delete "/orders/:orderId"
      doc "Permanently delete an order."
      auth requestUser: User ::: Authenticated requestUser via cookieAuth
      capture orderId: String ::: ValidOrderId orderId via orderIdCapture
      -> Unit                                          -- (derived: destructive)

    post "/internal/reindex"
      doc "Rebuild the search index."
      mcp internal                                     -- never exposed as a tool
      -> Unit
  }
  ```

- **Per-parameter / per-field descriptions** — short docs on captures, query
  params, and `record`/`codec` body fields, surfaced in the tool's input schema.
  Attach them where the field is already declared so there's one source of truth:

  ```tesl
  record NewOrder {
    sku:      String  doc "Catalog SKU, e.g. \"ACME-123\"."  ::: KnownSku sku
    quantity: Int     doc "Number of units; must be >= 1."   ::: Positive quantity
  }
  ```

- **Derived safety annotations (the Tesl angle)** — MCP tool annotations
  (`readOnlyHint`, `destructiveHint`, `idempotentHint`) should be **inferred** from
  what Tesl already knows: HTTP method (`get` → read-only; `delete` → destructive;
  `put` → idempotent) cross-checked with declared capabilities (`requires [dbWrite,
  payments]` ⇒ not read-only). An author can override, but the safe default is
  computed — so an agent sees an accurate "this tool mutates state" signal without
  anyone hand-annotating it.

- **Exposure control** — not every endpoint should be an MCP tool. Need a per-endpoint
  marker (e.g. `mcp expose` / `mcp internal`) and a tool-name/title override.
  Decision pending in open questions: **expose-all-by-default with opt-out**, or
  **opt-in** — the safer default for an auth'd internal API is likely opt-in.

- **Auth — same machinery as the API.** MCP tool calls authenticate through the
  **same `auth` handlers (authers)** the HTTP API already uses. An auth'd endpoint
  stays auth'd as an MCP tool: the auther runs against the MCP request, produces the
  same `Authenticated requestUser` proof, and the tool runs as that identity — so
  the proof obligations are satisfied identically whether the caller is a browser or
  an MCP client. There is no second authorization model and no bypass; auth'd
  endpoints are **exposed and protected**, not excluded.

  Because programmatic clients often carry credentials differently than browsers
  (a bearer token / API key rather than a session cookie), the MCP server can be
  pointed at a **different auther** than the web surface — same proof, different
  credential transport:

  ```tesl
  server OrdersServer for OrdersApi {
    auth cookieAuth              -- browsers
    mcp { auth bearerTokenAuth } -- MCP clients: same Authenticated proof, token-based
  }
  ```

  Both authers establish the same fact, so an endpoint's `auth requestUser: User
  ::: Authenticated requestUser` is honoured by either path. Anchors:
  `dsl/web.rkt`, the auther/proof handling in `proof_checker.ml`.

### MCP client / skills — easy *but controlled*

Attach an external MCP server, or a reusable **skill** pack (a named,
capability-scoped bundle of tools/prompts), to an agent in one line:

```tesl
mcp WeatherServer {
  endpoint:   env("WEATHER_MCP_URL")
  capability: externalWeather          -- explicit gate for this untrusted source
}

agent TravelAgent {
  provider: anthropic
  model:    "claude-opus-4-8"
  apiKey:   env("ANTHROPIC_API_KEY")
  tools:    [WeatherServer.*]          -- imported from MCP, still capability-tagged
  skills:   [SupportSkill]             -- a reusable bundle, also capability-scoped
}
```

Each imported tool is **capability-tagged**, so attaching a server or skill
**cannot silently widen authority** — the agent's grant must still cover the
imported tools' capabilities (the same compile-time bound as above), and untrusted
endpoints sit behind an explicit gating capability. An optional per-tool
allowlist/deny on the agent gives finer control. The capability system becomes the
**single control point for every tool source** — local function, MCP server, or
skill — which is what "as controlled as possible" should mean.

### Goal B — Tesl as the safest target for AI to write

Equal weight, and a natural corollary: **the compiler is the verifier.** When an
AI writes a Tesl handler and forgets a validation, leaves auth implicit, or grants
an over-broad capability, that is a *compile error*, not a production incident —
the language closes loops the model can't be trusted to close. Concretely:

- **AI-legible diagnostics + a machine-readable help/IR surface** (coordinate with
  `improved_devx.md`) so an agent can act on failures without scraping prose.
- A stable IR/spec for agents to target.
- Expose the **Tesl compiler itself as an MCP server**, so a coding agent can
  type-check / validate / format Tesl **in-loop** while authoring it — analyzed
  below.

### Compiler-as-MCP — pros and cons

The idea: ship an MCP server that exposes the toolchain as tools/resources a
coding agent calls while it writes Tesl — `check` (type + proof + capability
analysis, **no codegen**), `fmt`, `lint`, `compile`, `explain <error>`,
`search-manual`, and `list-api` (stdlib functions, capabilities, types). The agent
generates, checks, reads the structured errors, and fixes — before a human or CI
ever runs it.

The mental model is **generator + retriever + verifier**: the LLM generates, the
manual/API tools retrieve ground truth, and the compiler verifies. Tesl is an
unusually good fit for the verifier role because its compiler already proves the
exact things LLMs get wrong — forgotten validation, implicit auth, over-broad
capabilities — and reports them precisely rather than letting them slip to runtime.

**Reality check — shell-capable agents already have all of this.** A coding agent
with a terminal and the toolchain installed (Claude Code, Cursor, Cline, …) can
already run `tesl check`, `tesl fmt`, and crucially `tesl help manual` /
`tesl help manual full` (which exists today and is explicitly "for LLMs with large
context windows") **directly over the shell**. For that audience an MCP server is
largely *redundant* — it re-wraps commands the agent can already invoke. This
sharply narrows the case for compiler-as-MCP and changes where the leverage is:

- **The high-leverage work is making the _CLI + manual_ agent-excellent, not the
  protocol.** Legible, structured `tesl check` output (ideally a `--json`
  diagnostics mode), a well-organized `tesl help manual`, and a discoverable
  `tesl --help` serve the dominant Claude-Code-style case with *zero* MCP work, and
  the same surface backs an MCP server later for free. This is mostly
  `improved_devx.md`, not new AI work.
- **MCP earns its keep only in the no-shell / no-install cases:** hosts that can't
  spawn a terminal or install OCaml+Racket (Claude Desktop, web chat clients), a
  **hosted, version-pinned** compiler endpoint (a playground, CI bots, "try Tesl
  without installing anything"), and exposing `tesl help manual` sections as
  addressable MCP **resources** for hosts that surface them. Real, but a niche
  next to terminal-equipped coding agents.

So the pros/cons below apply mostly to that niche; for everyone else, read
"compiler-as-MCP" as "make `tesl check` + `tesl help manual` great for agents."

**Pros (mostly for the no-shell / hosted niche)**

- **Closes the rare-language gap — the biggest reason to invest in the _surface_.**
  LLMs are weak at low-resource languages they've seen little of; Tesl is brand new.
  An authoritative compiler + searchable manual substitutes *verification and
  retrieval* for *training data*, so a model that has barely seen Tesl can still
  converge on correct Tesl. (Note this gain comes from `tesl check` + `tesl help
  manual` *however* they're reached — shell or MCP; it is not unique to MCP.)
- **A generate→verify loop raises correctness past what the model can do alone.**
  The compiler is a ground-truth oracle; pairing a generator with a strong verifier
  is the classic route to correctness. Tesl's verifier is strong, so the gain is
  larger than for a typical language.
- **Tesl's errors are uniquely actionable.** "Capability `payments` not granted",
  "proof `ValidOrderId orderId` not discharged" map directly onto the fixes an
  agent can make — far more useful than a generic type error.
- **Speed: fewer wasted round-trips.** Errors are caught in-loop instead of at
  human review or CI; a fast check-only path (no Racket emit) keeps iterations
  cheap.
- **Portable + low-ish effort.** MCP means any client (Claude Desktop, Cursor,
  Cline, CI bots) benefits with no per-editor work, and it wraps CLI surface that
  already exists (`check`/`fmt`/`lint`/`compile` in the flake wrapper), riding on
  the help/IR work already planned in `improved_devx.md`.
- **No drift.** The agent checks against the *real* compiler, so its "knowledge"
  of the language stays current as Tesl evolves — no stale model snapshot.
- **Dogfooding.** Building it exercises the same MCP-server machinery and
  machine-legible-error work the user-facing features need.

**Cons / risks**

- **It verifies, it doesn't generate.** A model that can't write Tesl at all isn't
  rescued by a checker; verification catches errors but doesn't teach idioms. It's
  necessary-but-not-sufficient — must be paired with manual/example retrieval, or
  the agent loops on errors it can't fix.
- **Non-convergent repair loops.** The agent can fix one error and introduce
  another, especially around proof obligations it doesn't grasp — burning tokens
  and time. Needs bounded iteration, excellent error explanations, and possibly
  proof *hints* ("discharge this with a `check`").
- **Payoff is gated on error legibility.** If diagnostics are human-prose rather
  than structured/actionable, the agent can't act on them. This is a hard
  dependency on `improved_devx.md`'s failure-rendering work, not a freebie.
- **Latency at scale.** Each call is a compiler invocation; cold starts and any
  Racket-emit path are slow (seconds). Dozens of calls per task compound. Mitigate
  with a check-only mode, a warm/long-lived compiler process, and incrementality —
  overlapping with `optimizations.md`.
- **Sandboxing.** The server processes agent-supplied source. `check`/`fmt`/
  `compile` must be pure (no execution); exposing `run`/`test` would execute
  model-authored code and demands real isolation (no net/FS, resource caps). Even
  compile-only needs limits against pathological inputs. Recommendation: ship the
  analysis tools first, defer execution.
- **Project/workspace model.** Real checking spans multiple files, imports, and
  stdlib resolution — more than "check this string." The server needs a virtual
  workspace abstraction, which is non-trivial.
- **Versioning.** The server must track the compiler version; a mismatch between
  what the agent checks against and what the user builds causes confusing failures.
- **Overlaps the LSP.** Diagnostics/hover/completion are largely what the existing
  stdio LSP already does. Don't fork the analysis — the MCP server should be a thin
  shim over the **same engine** the LSP uses (MCP for headless/non-editor agents,
  LSP for editors), or the two will drift.

**Verdict / sequencing.** The leverage is in the *surface*, not the *protocol*.
Because shell-capable agents already drive `tesl check` and `tesl help manual`
directly, the first and highest-value work is making those **agent-excellent** —
structured/`--json` diagnostics, a navigable manual, discoverable help — which is
mostly `improved_devx.md` and benefits every coding agent immediately with no MCP
code. The compiler-as-MCP server is then a **thin wrapper over that same surface**,
worth building specifically for the no-shell / no-install / hosted cases (Claude
Desktop, web clients, a version-pinned playground/CI endpoint). When built, base it
on the **LSP's analysis engine** (don't fork it), ship pure analysis tools
(`check`/`fmt`/`lint`/`compile`/`explain`/`search-manual`, the last backed by
`tesl help manual`) first, and defer code *execution* (`run`/`test`) until
sandboxing is solved. It remains gated on machine-legible errors (`improved_devx.md`)
and a fast check-only mode (`optimizations.md`).

## End-to-end example — a support assistant

A single file that ties it together: typed tools, a capability-bounded agent with
provider config, an auth'd streaming chat endpoint, and an HTTP API that is *also*
an MCP server (auto-mounted by `serve`). The only non-existent syntax is the AI
surface (`agent`, `ask`, `agentReply`, `doc`, `mcp`); everything else is today's
Tesl.

```tesl
#lang tesl
module SupportApi exposing [SupportServer, SupportDatabase]

import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Http exposing [HttpRequest]
import Tesl.Env exposing [env, envInt]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.String exposing [String.startsWith]
import Tesl.Telemetry exposing [telemetry, initTelemetry]
import Tesl.Cli exposing [cli.args]
import Tesl.Agent exposing [aiProvider, agentReply, ask, AgentReply]

-- Capabilities: the agent may read orders and issue refunds — and nothing more.
capability supportDbRead  implies dbRead
capability supportDbWrite implies dbWrite
capability payments
capability supportAi      implies aiProvider, supportDbRead, supportDbWrite, payments
capability cookieReadHttp

-- Domain --------------------------------------------------------------------
type RefundResult = Refunded Int | Rejected String

entity Order table "orders" primaryKey id {
  id:         String
  customerId: String
  totalCents: Int
  status:     String
}

database SupportDatabase {
  backend postgres
  schema "support"
  entities [Order]
  postgres {
    database env("TESL_POSTGRES_DATABASE")
    user     env("TESL_POSTGRES_USER")
    password env("TESL_POSTGRES_PASSWORD")
    host     env("TESL_POSTGRES_HOST")
    port     envInt("TESL_POSTGRES_PORT", 5432)
  }
}

-- Auth ----------------------------------------------------------------------
fact Authenticated (req: User)

auth cookieAuth(request: HttpRequest) -> requestUser: User ::: Authenticated requestUser
  requires [cookieReadHttp] =
  case Dict.lookup "user" request.cookies of
    Something userId -> ok (User { id: userId, role: "user" }) ::: Authenticated requestUser
    Nothing          -> fail 401 "Missing or invalid user cookie"

-- Tools = typed functions; their signatures are the tool schemas ------------
fact ValidOrderId (orderId: String)

check isOrderId(orderId: String) -> orderId: String ::: ValidOrderId orderId =
  if String.startsWith orderId "ord-" then
    ok orderId ::: ValidOrderId orderId
  else
    fail 400 "Malformed order id"

fn lookupOrder(orderId: String ::: ValidOrderId orderId) -> Maybe Order
  doc "Look up a single order by its id."
  requires [supportDbRead] =
  selectOne order from Order where order.id == orderId

fn refundOrder(orderId: String ::: ValidOrderId orderId, amountCents: Int) -> RefundResult
  doc "Refund an order. amountCents must not exceed the order total."
  requires [supportDbWrite, payments] =
  case selectOne order from Order where order.id == orderId of
    Nothing -> Rejected "no such order"
    Something order where amountCents > order.totalCents -> Rejected "amount exceeds total"
    Something order ->
      update order in Order where order.id == orderId set order.status = "refunded" returning one
      Refunded amountCents

-- The agent: bounded by `supportAi`, model + provider configured inline ------
agent SupportAgent {
  provider:     anthropic            -- anthropic | openai | local
  model:        "claude-opus-4-8"
  apiKey:       env("ANTHROPIC_API_KEY")
  database:     SupportDatabase      -- conversation history lives here
  systemPrompt: "You are a support agent for ACME. Be concise and never invent order ids."
  tools:        [lookupOrder, refundOrder]
  maxTokens:    1500
}

-- A streaming, authenticated chat endpoint ---------------------------------
handler chat(requestUser: User ::: Authenticated requestUser, message: String)
  -> stream AgentReply
  requires [supportAi] =
  telemetry "support.chat" { user.id = requestUser.id }
  agentReply SupportAgent for requestUser message

-- A one-shot typed extraction (no agent loop) -------------------------------
-- The ADT is the contract: the model can only land on one of these cases, and
-- `case` over the result stays exhaustive — fuzzy text in, strict type out.
type Sentiment = Happy | Neutral | Upset

fn readSentiment(text: String) -> Sentiment
  requires [supportAi] =
  ask SupportAgent "Classify the customer's sentiment:\n${text}" into Sentiment via sentimentCodec

-- HTTP API — and, for free, an MCP server ----------------------------------
api SupportApi {
  post "/chat"
    doc "Chat with the ACME support assistant."
    auth requestUser: User ::: Authenticated requestUser via cookieAuth
    body message: String
    -> stream AgentReply
}

server SupportServer for SupportApi {
  chat = chat
  mcp { auth bearerTokenAuth }        -- MCP clients authenticate with a bearer token
}

main with capabilities [supportAi, cookieReadHttp] {
  initTelemetry service "support-api" endpoint "in-memory" console True
  let port = envInt("PORT", 8080)
  with database SupportDatabase {
    -- one process serves the HTTP API AND the MCP server (mounted at /mcp)
    serve SupportServer on port with capabilities [supportAi, cookieReadHttp]
  }
}
```

## Concurrency in practice — sync vs. worker-backed

The AI flows differ in duration, so they want different execution models. Tesl
runs on Racket's `web-server` (a green thread per request), so a synchronous
provider call blocks *that request*, not the server — the real reasons to go async
are **request/proxy timeouts**, **durability**, **rate-limiting**, and **not
holding a DB connection across slow calls**. The rule: keep short calls inline;
push long/agentic loops onto the existing **workers + channel + SSE** (no new
concurrency primitive — the same machinery `example/chat/` already uses).

The four flows, continuing the support example above.

**1. `ask` / one-shot extraction — synchronous.** Short, I/O-yields, composable;
the queue would only add latency:

```tesl
fn classify(body: String) -> Triage
  requires [supportAi] =
  ask SupportAgent "Classify this ticket as JSON matching Triage:\n${body}" into Triage via triageCodec
  -- returns inline; decoded + proof-validated via `codec Triage`
```

**2. Interactive chat turn — synchronous handler streaming over SSE.** A single
turn is short enough to stream directly from the request thread:

```tesl
handler chat(requestUser: User ::: Authenticated requestUser, message: String)
  -> stream AgentReply                         -- SSE: tokens flush as they arrive
  requires [supportAi] =
  agentReply SupportAgent for requestUser message
```

**3. Long / multi-step agentic task — worker-backed.** A "resolve this ticket"
agent may run minutes across many tool calls, so it must outlive the request,
survive restarts, and retry. The handler **enqueues and returns immediately**; a
worker runs the loop and publishes progress to a channel; an SSE endpoint streams
that channel to the client. All existing constructs — only the loop body is new:

```tesl
type ResolveTicket = ResolveTicket { ticketId: String }

queue AgentJobs {
  database:    SupportDatabase
  jobs:        [ResolveTicket]
  maxAttempts: 3
  backoff:     exponential          -- provider calls are flaky; reuse retry/backoff
}

channel AgentProgress (key: String) {   -- keyed by ticketId
  database: SupportDatabase
  payload:  AgentReply
}

-- the long loop runs on a worker, NOT in the request
workers AgentWorkers for AgentJobs {
  ResolveTicket = resolveTicket
}

fn resolveTicket(job: ResolveTicket) -> Unit
  requires [supportAi, queueWrite] =
  agentRun SupportAgent
    goal "Investigate and resolve ticket ${job.ticketId}; refund only if policy allows."
    publishing to AgentProgress key job.ticketId   -- streams steps as it works

-- request side: enqueue + hand back a stream to watch
handler startResolution(
  requestUser: User ::: Authenticated requestUser,
  ticketId:    String ::: ValidTicketId ticketId
) -> String
  requires [queueWrite] =
  enqueue ResolveTicket { ticketId: ticketId } on AgentJobs
  ticketId                                   -- returns at once; DB connection freed

handler watchResolution(
  requestUser: User ::: Authenticated requestUser,
  ticketId:    String ::: ValidTicketId ticketId
) -> stream AgentReply
  requires [pubsub] =
  subscribe AgentProgress key ticketId       -- SSE fan-out from the worker
```

**4. MCP server handling an inbound tool call — same as any handler.** No special
code: the auto-mounted MCP server dispatches a tool call to the very same
function, in-process, synchronously — inheriting that function's auth and
capabilities. `lookupOrder` is the MCP tool; nothing extra to write:

```tesl
-- already defined above; this IS the MCP tool, served in-process by `serve`
fn lookupOrder(orderId: String ::: ValidOrderId orderId) -> Maybe Order
  doc "Look up a single order by its id."
  requires [supportDbRead] =
  selectOne order from Order where order.id == orderId

server SupportServer for SupportApi {
  chat = chat
  mcp { auth bearerTokenAuth }   -- inbound MCP tool calls authenticate like the API,
                                 -- then run lookupOrder synchronously, same as HTTP
}
```

If an MCP-exposed endpoint is itself long-running, it takes path 3 (enqueue +
stream) — the MCP surface inherits whatever execution model the endpoint already
uses.

## Adjacent concerns — observability, testing, approvals, cost

Production AI needs more than the happy path. The good news: each of these rides
on an existing Tesl primitive rather than new AI machinery.

### Observability & cost (reuse `dsl/otel.rkt`)

Every provider call and tool dispatch should emit a span carrying the **model,
prompt/completion token counts, cost, latency, turn count, and stop reason**, and
the agent loop should trace as a tree of those spans. Reuse the existing
OpenTelemetry integration (`dsl/otel.rkt`) and the `telemetry` surface — AI just
adds span attributes. Per-request and per-agent **cost accounting** falls out of
the token attributes; no new observability stack.

### Testing AI deterministically

Provider calls are non-deterministic, networked, and costly, so CI can't gate on a
live model. The key insight: **most of what you own is already deterministic** —
tool dispatch, argument validation, capability bounds, control flow, and
structured-output decoding. Test *that* deterministically and treat the model's
*judgment quality* as a separate, out-of-band eval. Options, with trade-offs:

| Approach | How | Pros | Cons |
|---|---|---|---|
| **Mock provider** *(recommended default)* | `provider: mock` returns scripted completions / tool-call sequences; reuse `dsl/test-support.rkt` | Fully deterministic, fast, no keys/cost/network, CI-friendly; tests *your* logic + the safety properties (capability blocks, validation, retries, exact tool sequence) | Tests your code, not the model; mocks can drift from reality; multi-turn scripts are tedious to write |
| **Record / replay (cassette)** | Record real request/response rounds to JSON once; replay in CI | Deterministic replay of *real* behavior incl. the exact tool sequence; cheap; good for integration tests | Cassettes go stale *silently* on prompt/model change; request-matching is fragile (must normalize dynamic fields like ids/timestamps); JSON blobs in the repo; re-recording needs keys + cost + a human to confirm the new recording is *correct* (a recorded wrong answer is still wrong) |
| **Seeded / temp = 0 vs. a (local) model** | Fixed seed + temperature 0, ideally a local model in CI | Exercises a real model; a local model is free/offline | Not truly deterministic — no bitwise guarantee even at temp 0 (batching/hardware/version drift); heavy/flaky CI; breaks on model-version changes. Better periodic than gating |
| **Behavioral / eval suite (properties, LLM-as-judge)** | Assert *properties* ("never refunds an invalid order", "intent ∈ set") rather than exact text; optional judge model | Tests intent under non-determinism; directly backs the positioning's "tests pin down intent" | The judge is itself fuzzy and costly; assertions can be lenient; it's an eval suite, not a unit test |

**Recommendation — layer them.** Use the **mock provider as the CI default**
(deterministic, exercises the safety-critical logic you actually own); add
**record/replay** for integration coverage of real behavior, accepting the
staleness caveat; and run a **non-gating eval suite** (seeded/real + property or
judge assertions) periodically to catch prompt/model regressions. This makes the
Positioning concrete: types/proofs + mock-based tests give deterministic
structural and logic guarantees in CI, while evals watch behavioral quality out of
band.

### Human-in-the-loop approval (already supported by queues)

A high-authority action — a large refund — shouldn't fire on the model's say-so.
With the existing queue this is a *pattern, not a new feature*, and the
**capability split is the gate**: the agent is granted `queueWrite` (it may *file*
a request) but **not** `payments` (it literally cannot pay one out); only a
human-invoked, capability-gated handler holds `payments`. The job carries the
**`conversationId`** so the continuation runs with full context.

```tesl
type ApproveRefund = ApproveRefund {
  conversationId: String      -- carried so the worker/continuation has the whole thread
  orderId:        String
  amountCents:    Int
}

queue RefundApprovals { database: SupportDatabase, jobs: [ApproveRefund] }

-- Agent tool: may FILE a refund (queueWrite), cannot PAY one (no `payments`).
fn requestRefund(orderId: String ::: ValidOrderId orderId, amountCents: Int, conversationId: String)
  -> RefundResult
  doc "Request a refund; a human must approve before it is paid out."
  requires [queueWrite] =
  enqueue ApproveRefund { conversationId, orderId, amountCents } on RefundApprovals
  Rejected "filed for human approval"        -- the agent learns it is pending, not done

-- Human approval: an ordinary authenticated endpoint that DOES hold `payments`.
-- (claiming/marking the job uses normal queue ops; `pending` is the approved job.)
handler approveRefund(approver: User ::: Authenticated approver, pending: ApproveRefund)
  -> Unit
  requires [supportDbWrite, payments] =
  let _ = refundOrder pending.orderId pending.amountCents
  agentReply SupportAgent
    in conversation pending.conversationId     -- full context restored via the carried id
    "The refund was approved — let the customer know."
```

The same job-carries-`conversationId` trick is the general mechanism for any
worker-backed agent step (flow 3 above): the worker reloads the thread with
`in conversation <id>` instead of threading state by hand.

### Cost control via caching (reuse the `cache` block)

Identical or equivalent prompts can be served from the existing `cache` DSL block
(TTL'd), and the provider layer can pass through provider-side **prompt caching**
(e.g. Anthropic's). Both cut cost and latency with no new machinery.

## Entitlement — least-privilege over identity, effects, and data

The hardest question for an agent acting on a user's behalf is *"can it only touch
what that user is entitled to?"* "Entitled to" actually splits into **three
independent gates**, and Tesl has a distinct mechanism for each — access is the
**conjunction** of all three:

| Gate | Question | Tesl mechanism |
|---|---|---|
| **Authentication** | *Who* is this? | `auth` authers → `Authenticated requestUser` proof (HTTP *and* MCP, same authers) |
| **Capabilities** | What *kinds* of effect may run? | `requires […]` / `capability … implies` — coarse, static |
| **Authorization proofs** | Which *specific resources*? | `fact` + `check`/`establish` + query proofs (`? ForAll …`, `exists …`) — fine-grained, per-row |

Capabilities are too coarse for entitlement on their own — they say "may read the
DB," not "may read *this user's* rows." The per-resource gate is the proof system.

### Data access returns a *proof* of entitlement

The key move: the only way to obtain a resource value is through a query that
**filters by the caller's entitlement and returns a type carrying that proof.** You
cannot hand-construct an entitled value; you can only get one the compiler proved
you may have. Tesl already does this today (`example/todo-api.tesl`):

```tesl
handler listMyTodos(requestUser: User ::: Authenticated requestUser)
  -> List Todo ? ForAll (FromDb (OwnerId == requestUser.id))   -- the type PROVES ownership
  requires [todoDbRead] =
  select todo from Todo where todo.ownerId == requestUser.id   -- forget the `where` → won't compile
```

### Applied to RAG — closing the classic leak

Naive RAG leaks: search the whole corpus, return top-k, *hope* you post-filter.
Tesl pushes entitlement **into** retrieval and proves it — every hit is provably
readable by the caller (see *Retrieval & RAG*):

```tesl
fact Readable (user: User) (doc: Doc)

fn searchDocs(requestUser: User ::: Authenticated requestUser, query: String)
  -> List Doc ? ForAll (Readable requestUser)        -- every hit provably readable by this user
  requires [supportDbRead, aiProvider] =
  let q = embed query
  select doc from Doc
    where doc.ownerId == requestUser.id               -- (or a membership/ACL predicate)
    order by doc.embedding <-> q
    limit 5
```

The agent physically cannot retrieve a document outside the user's scope: the only
retrieval function is typed to filter-and-prove. Sharing/ACLs become richer
predicates (`CanRead` proven via group membership), but the principle holds —
**retrieval is proof-gated, not hope-gated.**

### Applied to agents — bounding the confused deputy

An agent is a *deputy* acting for a user; prompt injection tries to turn that
authority against another user's data. Tesl bounds it two ways at once:

1. **Thread `requestUser` into every data tool** — tools act with the *user's*
   proof, not ambient/service authority, so a tool's reach is the **user's**
   entitlement.
2. **Capabilities cap the action kind** — the agent still can't `payments` unless
   granted (the capability-bounded-authority check above).

```tesl
-- a mutating tool demands BOTH identity and an ownership proof tying the resource
-- to the caller — so it is uncallable on someone else's order:
fn cancelOrder(requestUser: User ::: Authenticated requestUser,
               order: Order ::: OwnedBy order requestUser)
  -> Unit
  requires [supportDbWrite] = …
```

So an agent's effective authority is **`user entitlement ∩ agent capability
grant`**. The worst a prompt injection can achieve is what the *current user* could
already do — never cross-tenant access, never an ungranted effect.

### The composition, end to end

1. **`auth`** establishes `requestUser` at the boundary (HTTP or MCP — same authers).
2. **Every data-access fn and RAG retrieval** is typed to scope by `requestUser` and
   *return the entitlement proof*; no out-of-scope row escapes.
3. **Mutating tools** take the authorization proof as a parameter — uncallable on
   resources the user doesn't own.
4. **Capabilities** cap effect kinds; the **human-in-the-loop capability split**
   handles anything beyond the user's/agent's authority.
5. **The agent runs as the user**, inheriting all of the above.

This is the Positioning argument made operational: you don't audit the agent's
transcript to trust it — you read the **signatures**. If `searchDocs` returns
`? ForAll (Readable requestUser)` and tools demand `OwnedBy … requestUser`, the
entitlement holds for *every* execution, including ones the model improvises.

## Retrieval & RAG

In scope — and it fits
Tesl unusually well because **PostgreSQL is already the datastore**: **pgvector**
puts the vector store *in the database you already run* — embeddings are an entity
column, similarity search is a `select … order by embedding <-> q limit k`, and
Postgres full-text (`tsvector`) gives **hybrid** retrieval in one place. Embeddings
compute through the **same provider layer** (so `aiProvider`, BYOK, and per-user
provider all apply to the embedding model too), and retrieval is **capability-gated**
like any DB read. RAG is mostly *composition of existing primitives*.

Ingestion (chunk → `embed` → store/index) is common to all options; the options
differ on **retrieval mode**:

- **A. RAG as a *tool* (agentic retrieval) — recommended default.** Retrieval is a
  typed function exposed as an agent tool (`searchDocs` above); the model calls it
  on demand. **Pros:** zero new language surface (it's the tools mechanism),
  agentic/multi-hop, capability-gated, and auto-exposed via MCP for free. **Cons:**
  grounding isn't guaranteed (the model decides whether to retrieve); a round-trip
  per search.
- **B. Declarative `knowledge:` on the agent (auto pre-retrieval).** The agent names
  a source; the runtime retrieves top-k and injects each turn. **Pros:** guaranteed
  grounding; simplest "answer from these docs" model. **Cons:** new declarative
  surface (top-k/threshold/injection config); always retrieves; single-shot.
- **C. Plain `Tesl.Vector` stdlib.** Embedding + similarity functions; wire it by
  hand. **Pros:** maximal flexibility, smallest addition. **Cons:** boilerplate;
  inconsistent; no first-class feel.
- **D. Layered (recommended overall).** Ship **C** as the foundation, make **A** the
  idiomatic default, add **B**'s sugar later if "always ground" demand is real —
  mirroring this doc's library-first / sugar-optional staging.

**The Tesl-flavoured differentiator: proof-carrying grounding.** Make a grounded
answer *carry a proof of its sources* — `answer ::: SourcedFrom docIds` — so an
answer claiming to come from the KB must cite real retrieved chunk ids, checked at
the boundary. That turns "did it hallucinate or cite?" into something the type
system tracks, pairing RAG with Tesl's thesis instead of bolting it on.

**Entitlement applies directly:** retrieval must be scoped to the caller and return
the entitlement proof (see *Entitlement* — the `searchDocs` example carries
`? ForAll (Readable requestUser)`).

**Caveats:** poisoned documents are a prompt-injection vector (retrieved text is
untrusted → ties to the taint open question); changing the embedding model means
**re-embedding** the corpus (a migration — see `database-migrations.md`); pgvector
must be present in the Postgres/Nix setup; chunking strategy, dimension, and
optional rerank (a second model call) are real knobs.

## Implementation strategy — reuse over new surface

A guiding constraint: deliver AI as a *first-class, explicit* citizen while adding
as little as possible to the compiler and to what a user must learn. Tesl already
owns the four hard pieces — **codecs + proofs** (validate untrusted output),
**capabilities** (bound authority), **typed signatures** (tool schemas), and a
**codegen seam** (`generate ts/elm/ir`). New surface is reserved for the one thing
that genuinely needs static introspection, and even that reuses an existing seam.

This is *not* a reversal of the "declarative `agent {}`" recommendation: the block
stays the **recommended authoring surface**. "Library-first" is about *build order
and compiler burden* — the block is **sugar that lowers to the library**, so it
costs a small parser + desugaring, not a parallel AI subsystem.

| Feature | Reuse what exists | Net-new |
|---|---|---|
| Structured output (`ask … into T`) | `codec` + `via` proof chains coerce untrusted JSON → typed proof-carrying values, with retry | **None** — biggest freebie |
| Provider calls / agent loop | `http-client.rkt`, `env`, `queue`, `channel`, `sse` | **None** — `Tesl.Agent` library |
| `ask` / `agentReply` | Ordinary library functions | **None** if functions, not keywords |
| Defining a tool | A tool *is* a `fn`/`handler`; referencing by name mirrors `server S for A { … }` | **None** to define |
| Tool / MCP schema from a signature | The **type serializer behind `generate ts/elm/ir`** | New *render target*, not new analysis |
| Capability bounding | The capability model (`implies`/`requires`, `validation_capabilities.ml`) | A *small* check; reused concept, no new primitive |
| Secrets / provider config | `env`/`envInt`; block fields | **None** beyond ordinary fields |
| Conversation state | `entity` + `database` | **None** |
| Streaming reply | `sse.rkt` + `channel` (the chat example streams this way) | One `stream T` return marker, lowering to SSE (see decision) |
| MCP server | `generate ir` + `dsl/web.rkt` mount | Runtime mount + codegen target |
| Retrieval / RAG | pgvector on existing Postgres + provider embeddings + retrieval-as-a-tool | A `Vector` column type/index |
| Tool descriptions | (the one new per-item field — prefer harvesting doc-comments over a `doc` keyword) | Minimal |

**Genuinely-new surface, kept thin:**

1. **Schema-from-signature** — piggyback on the `generate ts/elm` type serializer;
   tool schemas and the MCP server are new *render targets* of code that already
   walks Tesl types.
2. **Capability bounding for dynamic dispatch** — the static checker can't see "the
   model will call `refundOrder`," so the agent must *declare* its tool set and the
   checker verifies the enclosing capability scope covers it. Small extension of the
   existing closure check, existing concept — users learn nothing new.
3. **The `agent {}` block** — thin sugar lowering to the `Tesl.Agent` library value
   (the way a config block lowers to a runtime spec). First-class *feel*, minimal
   *surface*. For descriptions, prefer **harvesting doc-comments** over a new `doc`
   field.
4. **A `Vector` column type/index** (for RAG) — a small addition to the entity/DB
   layer over pgvector; retrieval itself is then an ordinary capability-gated tool.

**Staging (see Workstreams):** Tier 0 ships a usable agent + retrieval as a library
(the only compiler-side touch is the vector column type); Tier 1 reuses the codegen
seam for schemas + the MCP server;
Tier 2 adds the thin block + the small bounding check only if Tier-0 ergonomics
aren't first-class enough.

## Workstreams

**Tier 0 — `Tesl.Agent` library; no new compiler surface**

1. **Provider layer + completion/agent-loop** (M) — `tesl/agent.rkt` over
   `http-client.rkt` + `env.rkt`: per-agent `provider`/`model`/`endpoint`/`apiKey`,
   the tool-call loop, and `ask`/`agentReply` as **functions**. Structured output
   via existing `codec`+`via`; gating via existing capabilities; streaming via
   `channel`/`sse.rkt`; conversation via `entity`/`database`. Delivers a usable
   end-to-end agent with **zero compiler change**.
   Includes the cheap operational reuse: **otel spans + token/cost attributes**
   (`dsl/otel.rkt`), prompt **caching via the `cache` block**, and a **`mock`
   provider** for deterministic tests (`dsl/test-support.rkt`). *Human-in-the-loop
   needs no code — it's the capability-split + `queue` pattern (see Adjacent concerns).*
2. **MCP client + skill packs (library)** (M) — attach external MCP servers /
   reusable skill bundles as library values; each imported tool capability-tagged,
   optional per-tool allowlist.
3. **Retrieval & RAG (library)** (M–L) — a `Vector` column type + index on
   pgvector, `embed` via the provider layer, and entitlement-scoped retrieval as a
   tool (`searchDocs` returning `? ForAll (Readable requestUser)`); proof-carrying
   grounding (`SourcedFrom`). Mostly DB + provider reuse; the one small addition is
   the vector column/index in the entity system. *Anchors:* `database`/`entity`
   forms, `tesl/agent.rkt`, the query-proof system. *Needs pgvector in the runtime.*

**Tier 1 — reuse the codegen seam; new render targets, not new analysis**

4. **Schema-from-signature** (M) — derive provider tool schemas / JSON Schema from
   signatures by extending the `generate ts/elm/ir` type serializer; validate
   tool-call args via codecs. *Anchors:* `tesl generate ts`, codec system.
5. **Build-time, in-process MCP server** (M–L) — emit on every build as a sibling
   of `generate ir`, auto-mounted by `serve`; tool descriptions, derived safety
   annotations (method + capabilities), exposure config; MCP auth reuses authers.
   *Anchors:* `tesl generate ir`, `dsl/web.rkt`, `proof_checker.ml`.

**Tier 2 — thin sugar + small checks; only if Tier-0 ergonomics demand it**

6. **`agent {}` block as sugar** (S–M) — parser + lowering to the Tier-0 library
   value; no new semantic pathway. *Anchors:* `parse_queue_form`, queue emit.
7. **Capability-bounding check** (S) — an agent's declared tool set ⇒ required caps;
   enclosing scope must cover them. *Anchor:* `validation_capabilities.ml`.
8. **`knowledge:` auto-retrieval sugar** (S) — optional declarative pre-retrieval on
   the agent (top-k/threshold), lowering to the Tier-0 retrieval tool. Only if
   "always ground from these docs" demand is real.

**Goal B + polish**

9. **Agent-excellent CLI + manual, then a thin compiler-MCP** (M) — first make
   `tesl check` (structured/`--json`) and `tesl help manual` great for agents
   (mostly `improved_devx.md`), serving shell-capable agents (Claude Code, Cursor)
   directly; *then*, for no-shell/hosted hosts only, wrap that same surface as an
   MCP server on the **LSP's analysis engine** (don't fork it) — analysis tools
   first, defer `run`/`test` until sandboxed. *Gated on:* `improved_devx.md` +
   `optimizations.md`.
10. **AI-legible diagnostics + machine-readable help/IR** (M) — coordinate with
    `improved_devx.md`.
11. **Docs + worked example** (S) — add the support chatbot (tools + MCP + RAG) to
    `example/`.

## Sequencing

Tier 0 (1 → 2 → 3) is shippable on its own — a working, capability-bounded agent
with retrieval and no compiler change (bar the vector column). Tier 1 (4 → 5) runs
after 1. Tier 2 (6, 7, 8) is optional sugar once Tier 0/1 land (8 needs 3 + 6).
Goal B (9, 10) coordinates with `improved_devx`; 11 last.

## Design decisions

- **Reuse over new surface; the block is sugar over a library** — AI ships first as
  the `Tesl.Agent` library (structured output via existing codecs, gating via
  existing capabilities, transport via `http-client`/`env`/`sse`), and the
  declarative `agent {}` block lowers to that library. First-class *feel*, minimal
  compiler burden, almost nothing new for users to learn. See *Implementation
  strategy*.
- **Declarative-primary + one minimal primitive** — small surface, no awkward
  one-off ceremony, no workflow DSL.
- **Tools are existing typed functions** — no separate tool-schema language to
  maintain or drift.
- **Provider-agnostic via a gated capability** — echoes the seam philosophy of
  `swappable-runtime-backend.md`.
- **Provider binding is separate from agent behavior** — the block's
  provider/key/model is a *default*; `ask`/`agentReply` take an optional `using`
  binding resolved per call (BYOK, per-user provider). Credentials and capabilities
  are orthogonal axes: the key decides who pays and which model; capabilities decide
  what the agent may do — swapping keys never widens authority.
- **Reuse codec/proof for output validation** — don't invent a second validator.
- **MCP server reuses the IR, is built every time, and runs in-process** with the
  API (same `serve`, same host/port via `dsl/web.rkt`) — no `generate mcp` step, no
  parallel serializer, no separate process/port, no drift between the API and its
  tool definitions.
- **Safety annotations are derived, not authored** — method + capabilities compute
  `readOnly`/`destructive`/`idempotent` hints; authors override only the exceptions.
- **Every tool source is capability-tagged** — "easy to add, impossible to
  silently over-authorize"; the capability system is the single control point for
  local, MCP, and skill tools alike.
- **Entitlement = three gates (authn ∩ capability ∩ per-resource proof)** — agents
  run *as the user*, data access returns a proof it's in-scope, and mutating tools
  demand an ownership proof; an agent's reach is `user entitlement ∩ capability
  grant`, bounding prompt injection to the user's own access. See *Entitlement*.
- **Workers are the opt-in long path, not the default wrapper** — short `ask`/chat
  turns run inline (green thread, I/O-yields); long/agentic loops go on the
  existing `queue`/`channel`/SSE. No AI-specific concurrency primitive. Implementation
  note: never hold a DB connection across provider calls — acquire per tool-exec.
- **One streaming surface: `stream T`** — a single return marker that lowers to SSE.
  Inline handlers stream directly; worker-backed flows publish to a `channel` that a
  `stream`-returning handler `subscribe`s. One surface, two backends — not two idioms.
- **Human-in-the-loop is a capability split, not a feature** — withhold the
  high-authority capability (e.g. `payments`) from the agent; only a human-invoked,
  capability-gated handler holds it. The queue carries the `conversationId` so the
  continuation runs with full context. Reuses capabilities + `queue`, adds nothing.
- **Observability/cost, caching, and testing reuse existing primitives** —
  `dsl/otel.rkt` for AI spans + token/cost, the `cache` block for prompt caching, and
  a `mock` provider for deterministic tests. See *Adjacent concerns*.

## Open questions

- Conversation-state schema: language-managed entity vs. user-defined?
- Provider streaming integration: how does the agent runtime consume provider
  token streams and fan them to `sse.rkt` — both for inline-handler streaming and
  for the worker→`channel`→SSE path (see *Concurrency in practice*)?
- Tool-schema dialect: normalize OpenAI vs. Anthropic tool formats in the provider
  layer.
- Declarative `cost` / `timeout` / `retry` fields on the agent?
- **Provider failover & error handling:** on a 429 / outage / refusal, fall back to
  another model or provider? (Workers cover *retry*; failover and refusal handling
  are unaddressed.)
- **Per-user / per-tenant rate limits & quotas** — cost and abuse control; named as
  a reason for workers but not yet designed.
- **Context-window management** for long conversations — summarize/trim history when
  it exceeds the model's window (the chatbot section assumes turns just accumulate).
- **Data governance / residency / audit** — *what data goes to which provider*
  (PII to a third party?), an audit log of AI interactions, and the `local` provider
  as the on-prem/residency answer for sensitive data.
- **Prompt management** — templating, reusable fragments, and versioning of system
  prompts; pinning/migrating model versions when a provider deprecates one.
- **BYOK key storage** — does Tesl offer field-level encryption-at-rest
  (an `@encrypted` column annotation) for per-user secrets like API keys, or is that
  the developer's responsibility?
- **Prompt-injection:** could proofs *taint* model-derived values as untrusted
  until explicitly validated, the way unvalidated request data is treated today?
- **MCP credential transport:** the auth *model* is settled (reuse `auth` handlers;
  allow an alternate auther for MCP), but the concrete transport for MCP clients
  (bearer token / API key headers on the MCP request) and how the chosen auther
  reads it still needs spec.
- **Exposure default:** expose-all-with-opt-out vs. opt-in per endpoint. With auth
  now enforced on the MCP surface, expose-all-with-opt-out is more defensible, but
  opt-in remains the conservative choice for sensitive APIs.
- Mapping an external MCP server's **runtime-discovered** tools onto Tesl's
  **static** capability model — declare the granted capability up front and
  reject/skip any advertised tool that exceeds it?
- What a "skill" pack contains and how it is distributed (ties to
  `package_manager.md`).

## Out of scope (first cut)

- A full agent-orchestration / workflow DSL (use handler control flow).
- **Multi-agent orchestration** (agents as tools for other agents) — composes from
  the single-agent primitives later; not in the first cut.
- Fine-tuning / training.
- Local-model *hosting*/inference runtime (provider-agnostic *client* only).

## Relationships

- **`package_manager.md`** — skill-pack distribution and versioning.
- **`improved_devx.md`** — Goal B coordination (AI+human help, legible errors);
  a hard prerequisite for compiler-as-MCP.
- **`optimizations.md`** — a fast check-only compile path gates the compiler-as-MCP
  loop's latency.
- **`swappable-runtime-backend.md`** — the provider abstraction mirrors its
  seam philosophy; a stable IR helps both MCP generation and AI authoring.
- The **codec/proof** and **capability** systems are the load-bearing reuse — this
  feature is largely a new façade over guarantees Tesl already provides.
