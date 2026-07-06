# Server endpoints as agent tools (`serverTools`)

**Status: IMPLEMENTED (2026-07-06).** Shipped as designed below, with one refinement
over the original design: endpoint inclusion is **per call site** — an endpoint becomes
a tool iff the user variable's declared proof annotation covers the endpoint's `auth`
predicates, so a plainly-`Authenticated` user gets the plain endpoints while an
`Authenticated && Admin` user additionally gets the admin-gated ones (including via a
`let admin = check requireAdmin u` upgrade). Implementation: checker arms +
per-site inclusion (`checker.ml`, threaded to emit like the dot-hint tables), capability
charging (`validation_common.ml`/`validation_capabilities.ml`), compile-time
name/description/schema metadata + lowering (`emit_racket.ml`), runtime builder reusing
the HTTP boundary pipeline (`tesl/server-tools.rkt`, new provides in `dsl/web.rkt`).
Tests: `compiler/test/test_server_tools.ml` (11 static cases),
`tests/server-tools-tests.tesl` (8 mock-driven runtime tests; wired into ci.sh AI
suites). Spec: LANGUAGE-SPEC.md §11.1 "Server endpoints as tools".

## Original idea

> We today support adding tools when interacting with llms. But it would be nice to have
> an easy way of adding all endpoints in the server, preauthenticated (through partial
> application or something), so the llm gets all endpoints on the server "for free" in
> addition to tools that is not customer facing through the api but only as an agent tool.
>
> It is important that the mcp agent only can do things that the user can so we need to add
> plumbing to forward the session so the agent acts on the user behalf. Maybe a security
> risk but I'm not sure. Another option is to create a very shortlived token that the agent
> can use that in combination with a backend-only secret gives access to act on behalf of
> the user.

## Refined design

### Security model: partial application, not tokens

The agent loop runs **in-process**, inside a handler that has already authenticated the
request. The handler holds a proof-carrying value `user: User ::: Authenticated user` that
can only be minted by an `auth` function. `serverTools` partially applies every bound
endpoint handler with exactly that value.

- The agent's authority is the user's authority **by construction**: the tools are the same
  handler functions the HTTP API dispatches to, called with the same proof-carrying user
  value; every ownership/authorization check in the handler bodies (`fail 403 ...`) runs
  unchanged.
- No session forwarding, no token minting, no new trust boundary. The proof system already
  makes "acting on behalf of the user" a static requirement: you cannot call `serverTools`
  without a value proving `Authenticated`.
- The short-lived-token option from the original note is only needed for **out-of-process**
  agents (a remote MCP client calling back over HTTP). Deferred as future work; nothing in
  this design precludes it.

### Surface

```tesl
import Tesl.Agent exposing [serverTools, ...]

handler assistant(user: User ::: Authenticated user, q: Question) -> String
  requires [todoWebService, aiProvider] =
  let agent = Agent {
    provider: anthropic (requireEnv "ANTHROPIC_API_KEY") "claude-opus-4-8"
    systemPrompt: "You act on the user's todos via the provided tools."
    maxTokens: 512
    tools: serverTools TodoServer user
  }
  ask agent q.text
```

`serverTools <ServerName> <userExpr> : List Tool` — combines freely with hand-written
tools: `tools: List.append (serverTools TodoServer user) [asTool internalOnlyFn]`.
(Agent-only, non-customer-facing tools are the existing `asTool` mechanism — unchanged.)

### Semantics

For every **non-SSE** endpoint of the server's api, one `Tool` is derived:

- **name** — the server-binding name (`createTodo = createTodo` → `createTodo`); unique per
  server by existing validation.
- **description** — the bound handler's doc-comment (same harvest as `asTool`); falls back
  to `"METHOD /path"`.
- **input schema** — one required property per remaining handler parameter, in declared
  order: each `capture` (agent-prim scalar, same whitelist as `asTool` params) and the
  `body` binder (an object schema derived from the body record's `fromJson` codec keys;
  field codecs that aren't structurally known degrade to `{}` — schema is model guidance,
  the decode below stays authoritative).
- **validator** — reuses the endpoint's HTTP boundary pipeline: captures run the same
  capturer parser + `via` check + proof attach as a path segment; the body property runs
  the same codec decode + `via` checks as an HTTP body. Malformed/rejected args become an
  `is_error` tool_result (loop continues) exactly like today's tools.
- **dispatch** — applies the bound handler positionally `(user, captures..., body?)`.
  A `fail status "msg"` from the handler is a returned `check-fail` → `is_error`
  tool_result (`"tool failed: ..."`), keeping the loop alive — the agent-level analogue of
  the HTTP error response. Runtime exceptions are caught and normalized the same way
  (HTTP-500 parity) instead of killing the loop.
- **result** — encoded through the same response path as HTTP (`prepare-response-value` →
  structural/codec JSON), returned to the model as a JSON string.

Endpoints **without** an `auth` line are included too (public endpoints; no partial
application). SSE endpoints are excluded (no handler, no request/response shape).

### Static rules (all fail-closed, compile errors)

1. `serverTools` takes a **bare reference** to a `server` declared in this module —
   anything else is rejected (same posture as `asTool`, issue #24).
2. Every authed endpoint's auth binding must have the same type, the user expression must
   have that type, and **each declared auth predicate becomes a proof obligation on the
   user expression at the call site**, discharged by the ordinary proof checker — no new
   discharge path, no name-spelling shortcut.
3. Every capture parameter type must be an agent-prim (`String`/`Int`/`Float`/`Bool`/
   `PosixMillis`) — the single `agent_prim` registry stays the source of truth.
4. The enclosing fn must `require` the (expanded) union of all bound handlers'
   capabilities — charged through the existing `collect_needed_capabilities` dataflow, so
   the standard V001 error/hint applies.

### Implementation map

- **Checker** (`checker.ml`): special-case the curried app shape
  `serverTools <Server> <expr>` (server names are declarative, not expression values —
  same reason `App { api: S }` is skipped); type the user expr, resolve api+server,
  enforce rules 1–3; result type `List Tool`.
- **Proof checker**: emit one obligation per auth predicate on the user argument,
  discharged by the existing call-site machinery.
- **Capabilities** (`validation_common.ml` / `validation_capabilities.ml`): charge the
  union of bound handlers' declared capabilities at the `serverTools` site.
- **Emit** (`emit_racket.ml`): lower to
  `(tesl-server-tools <Server> <user> (list (list "name" "desc" "schemaJson") ...))` —
  name/description/schema derived at compile time (same code path family as
  `emit_tool_from_fd` / `agent_prim_schema_prop`).
- **Runtime** (`tesl/server-tools.rkt`, new): walk `server-spec-routes`, build one
  `tool-spec` per route from the route's `capture-spec`/`payload-spec` closures — the
  HTTP pipeline itself, not a re-implementation — so tool-arg validation can never be
  weaker than the HTTP boundary.
- **Stdlib surface**: export `serverTools` from `Tesl.Agent` as a compile-time-lowered
  name (present in the export list, absent from the bare runtime module, emit-gated) so
  the import-soundness class stays closed.

### Future work

- Out-of-process agents (remote MCP): short-lived token + backend secret exchange.
- Per-endpoint opt-out / subsetting (`serverTools S user except [...]`) if the all-in
  default proves too broad in practice.
- Flattening single-body schemas (`{"title": ...}` instead of `{"newTodo": {"title": ...}}`)
  if models handle the nested binder poorly.
