# Built-in abuse protection, rate limiting, and admission control

**Status: PLANNED (design pass 2026-09-04).** This supersedes the rejected
handler-capability proposal in `roadmap/discarded/rate-limiting.md`.

## Decision

Build this, but make the promise precise.

Tesl should protect the expensive boundaries it owns without application code,
and make application-specific user/tenant limits short, typed declarations. The
runtime must enforce both at chokepoints that application code cannot bypass.
PostgreSQL is authoritative when the application uses PostgreSQL, so several
instances enforce one budget. A Memory database gives exact single-process
semantics for development and tests, not a horizontal guarantee.

This is application-layer abuse and cost control. It does **not** make an
Internet-facing process volumetric-DDoS-proof. Connection floods, bandwidth
exhaustion, TLS handshakes, globally distributed botnets, and source-address
reputation remain edge/load-balancer concerns. Tesl's existing reverse-proxy
boundary remains correct.

Do **not** add TLS termination with this feature. TLS termination and request
admission solve different problems. Adding one does not make the other more
correct, and Tesl should not duplicate the certificate lifecycle already owned
by the deployment edge.

## Why this now belongs in Tesl

The original proposal was discarded because a process-local counter is bypassed
by sending requests to another instance. The current system has changed:

- Postgres-backed queues, cache, outbox, and pub/sub already establish the
  internal-store pattern and shared-state deployment model.
- Runtime-owned SSO routes cannot be protected by a handler decorator. The
  limiter must therefore live at dispatch, where future runtime-owned routes are
  covered too.
- `Crypto.checkPassword` intentionally spends CPU and memory on missing and
  incorrect accounts. Without admission and concurrency control, authentication
  is a resource-exhaustion amplifier.
- Agent/provider calls can spend host-owned money. A reverse proxy cannot key a
  budget by a verified Tesl user or tenant and cannot understand application
  cost units.
- `HttpRequest.clientAddress` and `trustedProxies` now provide the start of a
  trustworthy client-address contract. Rate limiting must reuse that contract,
  never reinterpret `X-Forwarded-For` itself.

These controls are security properties of generated applications, not optional
library calls every application author must remember to place correctly.

## Goals

1. Protect runtime-owned login and callback routes by default.
2. Bound password brute force and Argon2 CPU/memory concurrency by default.
3. Let an application declare shared per-client, per-user, or per-tenant budgets
   with minimal syntax and compile-time-checked keys.
4. Enforce one budget across horizontally scaled instances without Redis or a
   new deployment dependency.
5. Shed work before the protected expensive operation, with bounded latency and
   deterministic, privacy-safe responses.
6. Make bypasses, unsafe keys, impossible policies, and unsupported deployment
   guarantees compile errors or focused lints.
7. Emit useful low-cardinality metrics automatically and make limits easy to
   exercise in `api-test` and `load-test`.

## Non-goals

- Volumetric DDoS mitigation, bot reputation, CAPTCHA, WAF rules, or replacing a
  CDN/load balancer/reverse proxy.
- TLS termination or certificate management.
- A general distributed lock, counter, or Redis abstraction.
- Exact billing. A request `cost` is an admission unit, not measured provider
  tokens, money, or a transactional monthly invoice ledger.
- Dynamic plan functions executed during admission. They add effects and a new
  failure path before every handler; static policies cover v1.
- User-visible manual increment/decrement APIs. Optional calls are omittable and
  therefore cannot support a security guarantee.
- Claiming a cluster-wide guarantee for a Memory-backed application.

## Protection model

Use three layers. They solve different failure modes and must not be presented as
interchangeable.

### 1. Runtime-owned safety guards: zero user code

Tesl knows where its dangerous work happens and protects those sites directly:

- Separate per-client limits for each runtime-owned SSO login and callback
  route, before cookie minting or outbound provider calls.
- Layered client and `(client, normalized identifier)` budgets at the unique
  mediated password-login gate, before account lookup and Argon2. An
  identifier-only score is explicitly deferred because it creates a lockout
  primitive.
- A process-wide weighted Argon2 memory/concurrency gate covering **all** hash
  and verify calls, including the missing-account timing equalizer. It has a
  bounded wait and no unbounded goroutine queue.
- A bounded process-local concurrency gate at runtime-owned outbound SSO work.
  Agent-provider concurrency should use the same resource-guard pattern; route
  budgets remain the application-specific cost control.
- A cheap, bounded process-local admission guard before shared-store work. This
  protects the limiter database from one hot source and protects the process if
  the store is slow; it is not counted as the distributed policy.

Default values are closed runtime presets, not dozens of knobs. Phase 0 must
benchmark and freeze them before implementation. Initial values to test, not yet
the compatibility contract:

| Gate | Initial candidate |
|---|---:|
| SSO login, per client and provider | 30/min, burst 10 |
| SSO callback, per client and provider | 60/min, burst 20 |
| Password, per `(client, normalized identifier)` | 5/15 min, burst 3 |
| Password, per client | 30/15 min, burst 10 |
| Argon2 | weighted by declared PHC memory, fixed process memory budget |
| SSE connections, per client | 10 concurrent |
| SSE connections, per process | benchmark-derived fixed ceiling |

Do not install a mandatory identifier-only hard limit in v1. It slows a
distributed guess but also gives a distributed attacker a victim-lockout
endpoint and reveals recent activity for that identifier. The pair and client
limits bound one source; the deployment edge remains the botnet control. Revisit
an account-wide failure score only with an explicit lockout/recovery and oracle
analysis. A random-identifier spray is bounded by the client policy.

Every attempt consumes the same admission cost, including success. Missing
account, wrong password, invalid/over-budget stored hash, and throttled failure
paths retain one generic public failure shape where their status permits; a
successful login necessarily remains distinguishable because it succeeds and
mints a session.

There is no `disableAuthRateLimits` escape in v1. If operational evidence shows
the presets need tuning, add a small closed `Standard | HighTraffic` server
preset later, not arbitrary per-route auth internals.

### 2. Declared application budgets: small typed surface

Recommended syntax:

```tesl
rateLimit PublicSearch(key: ClientAddress) {
  allow 60 per 1min
  burst 10
}

rateLimit UserAi(userId: UserId) {
  allow 1000 per 1h
  burst 20
}

rateLimit TenantAi(orgId: OrgId) {
  allow 10000 per 1h
  burst 100
}

api SupportApi {
  get "/search"
    rateLimit PublicSearch(clientAddress)
    -> List SearchResult

  post "/chat"
    auth user: User ::: Authenticated user via sessionOwner
    body request: ChatRequest
    rateLimit UserAi(user.id) cost 10
    rateLimit TenantAi(user.orgId) cost 10
    -> AgentReply
}
```

Local grammar:

```text
<rate-limit-decl> ::= "rateLimit" <ident> "(" <ident> ":" <key-type> ")" "{"
                        "allow" <positive-int> "per" <rate-limit-duration>
                        "burst" <positive-int>
                      "}"

<rate-limit-line> ::= "rateLimit" <ident> "(" <rate-limit-key> ")"
                      [ "cost" <positive-int> ]

<rate-limit-key> ::= "clientAddress" | <authenticated-binding-or-one-field>
<rate-limit-duration> ::= <positive-int> ( "s" | "min" | "h" | "d" )
```

`cost` defaults to 1. A declaration is a shared budget: every endpoint using
`UserAi` with the same key spends from the same bucket. Separate declarations
mean separate budgets. In v1 a policy must be declared in the same module as the
API that uses it; imported policies are deferred. Runtime identity includes the
activated application/server namespace plus the declaration name, so two apps
sharing a database schema do not accidentally merge budgets.

`ClientAddress` is a compiler-only opaque policy-key type;
`clientAddress` is a contextual endpoint value produced by dispatch. This does
not change the existing public `HttpRequest.clientAddress : String`: application
code may still inspect that canonical string, but cannot convert any string into
the unforgeable policy-key provenance. Authenticated keys may be the auth binder
itself or one of its stable scalar/newtype fields, such as `UserId`, `OrgId`,
`String`, or `Int`.

The first cut intentionally rejects body fields, query values, captures, raw
headers, `Float`, `JsonValue`, collections, records, `Maybe`, functions, and
`Secret` values as keys. Public attacker-chosen values create unbounded
cardinality and let a caller choose who gets throttled. Auth output and the
runtime-derived client address are the two trustworthy provenances v1 needs.

### 3. Deployment edge

Documentation and `tesl init` production guidance continue to require an edge
for public deployments. The edge should enforce connection/header/body limits,
TLS, a coarse global/IP limit, and provider-specific network controls. Tesl then
enforces identity-aware and operation-aware policy behind it.

This is defence in depth, not duplicate implementation: edge identity is a
network source; Tesl identity is a verified application principal.

## Dispatch semantics

Enforcement order is part of the security contract:

1. Existing HTTP read/header deadlines and body-size cap apply.
2. Validate `Host` and cross-site request policy.
3. Resolve the route and method.
4. Derive client address once from the socket peer plus declared trusted proxies.
5. Apply process admission and pre-auth client-address policies.
6. Read/decode the bounded body and run endpoint auth.
7. Apply all auth-derived user/tenant policies for that stage atomically.
8. Execute the handler or runtime-owned operation.

An admitted request spends its cost even if later auth, validation, or handler
work fails. There are no refunds: refund protocols create races and let a caller
exercise expensive failure paths for free. Pre-auth cost also remains spent if a
post-auth policy rejects.

All policies at one stage are admitted atomically. If any user/tenant policy at
that stage refuses, none of that stage's policies are charged. Locks/rows are
visited in stable policy/key order to avoid deadlocks.

For SSE, rate admission applies to the handshake; a token is not held for the
life of the stream. Acquire the per-client and process-wide SSE connection slots
before writing `200` or registering listeners; release them on every disconnect,
write failure, panic, and shutdown path. Per-client saturation is `429`; global
process saturation is `503`. SSE slots do not share the ordinary request pool.

Runtime-owned SSO routes, declared HTTP routes, SSE handshakes, and future
runtime-minted routes all pass through the same dispatch admission interface.
Static assets do not consume application budgets. A user-declared health-probe
path is still an ordinary route and receives every policy attached to it; there
is no path-string exemption that can become a bypass. A future runtime-owned
constant-time liveness endpoint may be exempt by construction.

## Client identity and proxy trust

The current implementation computes `HttpRequest.clientAddress` when generated
auth code constructs its request value. Runtime-owned SSO dispatch does not have
that value. Before rate limiting lands, move client-address derivation to one
request context created at the outer dispatch boundary and pass it to auth,
ordinary handlers, SSO, telemetry, and rate limiting.

Required hardening in the same prerequisite:

- `trustedProxies` entries parse at compile/startup time as exact IP addresses or
  CIDRs; non-empty arbitrary strings are no longer accepted.
- Without `trustedProxies`, ignore forwarding headers and use the socket peer.
- With `trustedProxies`, walk `X-Forwarded-For` from the socket toward the client
  and select the rightmost untrusted hop.
- Strictly parse and canonicalize every selected address, including IPv4-mapped
  IPv6. Malformed, empty, or all-trusted chains produce a controlled refusal,
  never a panic and never a fallback to attacker text.
- IPv4 uses the canonical address. The security review must decide whether the
  built-in anonymous key groups IPv6 by `/64`; if it does, that rule is fixed and
  tested rather than configurable per application.
- No policy may read `X-Forwarded-For` through `request.headers` as a substitute.

This closes both spoofing directions: an attacker cannot evade their own budget
or spend a victim's budget by writing a forwarding header.

## Password gate prerequisite

`Crypto.checkPassword` currently accepts only a stored hash and candidate. It
does not know which subject/identifier the credential belongs to, and the
current `loginMethods [Sso, Password via ...]` contract still does not fully bind
a verified credential to the subject placed in the session token
(`LANGUAGE-SPEC.md` section 23.6).

Do not create `checkPasswordWithRateLimit`, and do not infer identity from an
arbitrary handler body. First land one sound, runtime-mediated password-login
gate that:

- binds an opaque stored credential to its canonical subject/identifier;
- verifies the candidate with missing-account timing equalization;
- mints evidence for exactly that subject;
- binds the session token's `sub` to the same subject; and
- receives the dispatch request context for client admission.

The password limiter attaches to this unique gate. Raw password hashing and
verification still receive the process-wide Argon2 resource guard, while only
the mediated login gate receives login-attempt budgets. This roadmap depends on
closing the subject/token witness gap; rate limiting must not make the current
mixed-mode guarantee look more complete than it is.

Argon2 admission parses and caps **all** attacker-influenced PHC work parameters
(`m`, `t`, and `p`) before allocation. It is weighted by requested memory and
also bounded by CPU/concurrency, not just a fixed number of calls. A stored hash
asking for more than the safe process budget is never executed and requires
password reset/rehash, but the path still performs the standard bounded dummy
KDF before returning the generic failure so an invalid/oversized stored row is
not an account-state timing oracle. Permit release is panic-safe. The timing
equalizer is initialized without recursively acquiring the same permit.

## Distributed algorithm

Use Generic Cell Rate Algorithm (GCRA), a token-bucket-equivalent algorithm with
one timestamp per `(policy, key)` and no event log.

For rate `N` per period `T`, emission interval `tau = ceil(T / N)`. For cost `C`
and burst `B`:

```text
candidate = max(theoreticalArrivalTime, databaseNow) + C * tau
allow iff candidate <= databaseNow + B * tau
```

On allow, store `candidate`. On deny, do **not** advance the timestamp. Thus a
client cannot extend another key's lockout by hammering an already-empty bucket.
Use integer microseconds and PostgreSQL time, never process wall clocks or
floating-point refill arithmetic. Ceiling makes rounding conservative.

The PostgreSQL table is runtime-owned and logged (a database crash must not reset
security/cost state):

```text
tesl_rate_limits(
  app_namespace    text,
  policy_id        text,
  key_digest       bytea,
  tat_micros       bigint,
  last_admitted_at timestamptz,
  primary key(app_namespace, policy_id, key_digest)
)
```

Details:

- `app_namespace` is derived stably from the activated main/server identity, not
  from a build hash. `policy_id` is the local declaration name (runtime defaults
  have reserved names). Two servers intentionally sharing a policy need an
  explicit future design; v1 keeps their state separate.
- Policy arithmetic is immutable under `(app_namespace, policy_id)`. Persist a
  canonical definition/fingerprint in runtime metadata and validate all active
  definitions before opening the listener. A mismatched rate, period, burst, or
  key type fails startup instead of interpreting old `tat_micros` under new
  arithmetic. Changing a policy requires a new declaration name and an explicit
  cutover. A rolling rename temporarily has two budgets, so security-sensitive
  deployments must drain the old version or tighten the edge during the cutover;
  this is honest and safer than silently resetting/reinterpreting state.
- Runtime-owned defaults carry an explicit internal policy version. Changing a
  shipped preset follows the same reviewed cutover rule; a compiler/runtime
  upgrade must never silently reinterpret or reset an old auth bucket.
- `key_digest` is HMAC-SHA-256 over a domain-separated canonical typed encoding.
  A runtime-owned random key is generated once in database metadata and shared
  by instances. This keeps raw IPs, emails, user IDs, and API-key material out of
  the limiter table, logs, metrics, and debugger. It does not claim secrecy from
  an attacker who can read the entire database, including its metadata. If the
  metadata key is missing while limiter rows exist, startup fails; generating a
  replacement would silently reset every budget.
- Admission runs outside the application's transaction. A later rollback does
  not refund abuse cost.
- Limiter state belongs to the one database activated by `App.database`. A
  Postgres backend uses its schema and shared store; a Memory backend uses the
  process store. The compiler rejects any future App shape where no unique
  activated database can be selected.
- Use a small dedicated runtime pool and a short deadline. Handler pool
  exhaustion must not indefinitely block the admission decision.
- Bootstrap tables, indexes, metadata key, and policy definitions before opening
  the listener, using the existing concurrent-startup race rules but not lazy
  request-path `ensureTable`. Bootstrap failure fails startup; a store failure
  after startup produces the bounded `503` contract below. No Redis, migration
  service, or operator-created table is required.
- Never silently fall back from PostgreSQL to process memory. That recreates the
  horizontal bypass that caused the original design to be discarded.

Memory and PostgreSQL implementations consume the same pure GCRA decision model.
Memory uses a monotonic clock and a mutex/sharded map. The differential test
suite feeds both the same trace and requires identical decisions/retry times.

For a denied policy, compute
`retryAt = tat + cost*tau - burst*tau`; return the maximum `retryAt` across the
policies that denied the atomic stage. `Retry-After` is
`max(1, ceil((retryAt-now)/1 second))`. Sample PostgreSQL time once per admission
transaction and use it for every policy. All duration multiplication/addition is
checked `int64`; an overflow is a rejected policy at compile/startup, never wrap.

### Bounded state and self-protection

The limiter itself must not become a storage DoS:

- Create/update rows only for admitted attempts. Denials do not refresh
  `last_admitted_at`.
- Keep a bounded per-process cache of known denied keys until their retry time.
  It may avoid a PostgreSQL call for a denial, but it may never grant a request;
  accepted decisions always come from the authoritative store.
- Apply the cheap process admission guard before PostgreSQL, bounding concurrent
  limiter queries.
- Delete only fully replenished, idle rows. Sweep in indexed batches with jitter
  and one advisory-lock-elected instance; never scan/delete on every request.
- Bound per-policy active-key cardinality. At the cap, atomically evict one
  fully replenished least-recently-admitted row before inserting a new key. If no
  safe row is evictable, fail the new key with capacity `503` and emit one
  sampled operational event plus a metric. Never evict active debt and never
  exceed the cap during the eviction/insert race.
- Cleanup failure never disables admission. Recover, report, and retry later.

The cardinality cap and idle retention need benchmark-derived defaults in Phase
0. They are runtime safety limits, not application tuning knobs in v1.

## Failure and response contract

| Condition | Response | State |
|---|---|---|
| Budget exhausted | `429` + integer `Retry-After` | handler/operation does not run |
| PostgreSQL limiter unavailable/timeout | `503` + short `Retry-After` | fail closed; no memory fallback |
| Process/Argon2/SSO capacity saturated | `503` + short `Retry-After` | bounded wait or immediate shed |
| Active-key cap with no safe eviction | `503` + short `Retry-After` | fail closed; existing keys unchanged |
| Cleanup/metrics failure | no client effect | admission remains active |

`429` and `503` are not interchangeable: one says caller budget is empty; the
other says the protection system cannot safely admit work.

For declared JSON APIs, use the existing fixed failure envelope. Runtime-owned
browser routes use a fixed HTML page. Both set `Cache-Control: no-store` and
coarsely ceiling `Retry-After`; neither reflects the key, policy name, submitted
identifier, provider error, remaining tenant budget, or internal failure.
Authentication responses expose no remaining-limit headers because they become
an account oracle. No session cookie is minted on refusal. A refused SSO callback
clears its one-time in-flight cookie so it cannot be replayed later.

No user-selectable `failOpen` mode in v1. Security and cost policies silently
changing meaning during a database outage is not a robust default.

A timeout while PostgreSQL commits has an indeterminate outcome: Tesl may answer
`503` after the budget was charged. This conservative overcharge is allowed.
Never retry by assuming an uncertain commit did not happen; that can double
charge or accidentally grant work.

## Compile-time guarantees and lints

Errors:

- Unknown/duplicate policy, duplicate endpoint application, or reserved
  runtime-policy name.
- Non-positive rate, duration, burst, or cost; overflow; duration outside the
  supported bounded range; `cost > burst` (the request could never pass).
- Policy key type mismatch or an unstable/unsupported key type.
- Key expression not derived from `clientAddress`, that endpoint's proven auth
  binder, or one stable scalar field of that binder.
- Auth-derived key used before/without the corresponding auth line.
- Rate limit placed on a handler/function instead of an API endpoint.
- Policy declared outside the API's module (v1 has no imported policies).
- Any attempt to treat a forwarding header as `ClientAddress`.

Focused lints:

- Unused policy declaration.
- Anonymous endpoint transitively reaching `Crypto.hashPassword`, agent calls,
  or another known costly capability without a client-address policy.
- Agent-capable endpoint without an auth-derived user or tenant policy.
- Endpoint whose `auth` transitively reaches a known costly capability without
  a pre-auth client-address policy.
- Expensive endpoint with only a long-window policy and a very large burst.
- Activated rate limits with a Memory backend: exact per-process behavior, no
  horizontal guarantee.

Do not mint a `RateLimited` GDP fact. Admission is changing runtime state, not a
business fact the handler should consume. The useful proof is structural: the
compiler proves the policy is attached to the endpoint, its key has trusted
provenance and the right type, and emitted dispatch executes it before the
handler. Generated-source tests prove no route kind omits that call.

Endpoint rate limits govern external HTTP/SSE admission. Calling a handler as a
plain function, or invoking it through `serverTools`, does not pretend to be an
HTTP request and does not spend the endpoint bucket. Known costly tool/provider
work remains protected by its runtime resource gate; if identity-aware tool
quotas are needed, add a tool-bound policy surface rather than smuggling an HTTP
request context into direct calls.

## Agent cost semantics

`cost` is deliberately static and conservative. `cost 10` spends ten policy
units before the request starts. It is useful for saying that chat is ten times
more expensive than profile lookup, and it gives a hard admission bound without
letting failures spend for free.

It is not an exact LLM bill: one admitted agent request may retry, call several
tools, or consume varying token counts. Runtime-owned provider concurrency keeps
that work bounded per process; existing telemetry reports actual calls/tokens.
A future exact monetary/token quota needs reserve/settle semantics, idempotency,
provider usage reconciliation, and a durable audit ledger. Keep that separate
instead of making `rateLimit` falsely transactional.

## Observability and audit

Built-in metrics, enabled through the existing telemetry path:

- `tesl.rate_limit.decisions` counter: `policy`, `stage`, `outcome`
  (`allow|deny|store_error|capacity`).
- `tesl.rate_limit.store.duration` histogram: `operation`, `outcome`.
- `tesl.rate_limit.cleanup` counter: `outcome`.
- `tesl.argon2.admission` counter and wait histogram: `operation`, `outcome`.
- `tesl.sso.admission` and agent-provider capacity decisions at their runtime
  chokepoints.

Labels contain only bounded declaration/route-template names and closed enums.
Never label metrics with client address, identifier, user, tenant, key digest,
raw path, or submitted credential.

Denials may emit sampled structured security events with outcome class and route
template. Store failures and cardinality saturation emit loud but rate-limited
operator events. Existing bounded OTel export is observability, not a durable
compliance audit ledger. The auth-event stream can record the final outcome, but
it is not authoritative limiter state and cannot drive pre-admission: it occurs
after work the limiter must prevent.

## Testing ergonomics

Every `api-test` receives a fresh in-memory limiter store and deterministic
limiter clock. Add test-only request and clock clauses:

```tesl
api-test "public search sheds excess requests" for SupportServer {
  let first = get "/search" clientAddress "203.0.113.10"
  # ...consume the declared burst...
  let denied = get "/search" clientAddress "203.0.113.10"
  expect denied.status == 429

  advanceTime 1min
  let recovered = get "/search" clientAddress "203.0.113.10"
  expect recovered.status == 200
}
```

`clientAddress` sets the simulated socket peer; it must not synthesize a
forwarding header. `advanceTime` advances the framework's limiter clock without
sleeping and has no production form.

Add `statusRate <status>` to load-test metrics so expected shedding can be
distinguished from `500` failures:

```tesl
load-test "search sheds predictably" for SupportServer
  rate 100rps
  duration 10s {
  get "/search" clientAddress "203.0.113.10"
  assert statusRate 429 > 0.50
  assert statusRate 500 < 0.001
  assert p99 < 100ms
}
```

These tests prove application behavior, not horizontal atomicity. CI also needs
a Go/PostgreSQL integration test that runs at least two server/runtime instances
against one table, releases simultaneous requests behind a barrier, and proves
the combined accepted cost never exceeds the available burst.

Required test groups:

1. Pure/property GCRA tests: boundaries, weighted cost, refill, conservative
   rounding, retry calculation, clock movement, and denial not extending state.
2. Memory/PostgreSQL differential traces against controlled time.
3. High-contention PostgreSQL tests, multi-policy atomicity, deadlock freedom,
   startup races, pool starvation, timeout, outage, and no fallback.
4. Trusted-proxy spoofing tests: direct peer, repeated headers, CIDRs, malformed
   values, all-trusted chain, IPv4-mapped IPv6, and undeclared proxy.
5. Dispatch tests for ordinary routes, runtime SSO login/callback, mounted APIs,
   SSE handshake, static assets, 404/405, and proof that a declared health path
   is not a policy bypass.
6. Password tests proving admission precedes lookup/KDF; equal charging on every
   attempt; missing/wrong/invalid-hash failure equivalence; successful login;
   weighted memory/CPU ceilings; bounded waiting; panic-safe permit release; and
   `go test -race` coverage.
7. Privacy tests: no raw key/identifier in limiter-owned table rows, SQL
   diagnostics, responses, limiter metrics/events, or generated limiter
   constants; no cookie on refusal. Ordinary application locals/logs are outside
   this claim.
8. Cleanup/admission race, bounded batches, cardinality cap, and cleanup-failure
   recovery.
9. Compiler negative tests for every error above, formatter/semantic-query
   coverage, and generated-source characterization proving every route kind
   passes through admission.

## Phases

### Phase 0: freeze contracts and close prerequisites

- Benchmark auth, PostgreSQL admission, SSO outbound work, and Argon2 on target
  low/medium hosts. Freeze safe presets, cardinality/retention bounds, database
  timeout, and weighted Argon2 memory budget.
- Move strict client-address derivation to the dispatch request context; validate
  trusted proxy IP/CIDR declarations and turn malformed chains into controlled
  refusals.
- Promote and freeze an accepted subject-bound password/session witness-gate
  prerequisite, including credential storage and set-side semantics, then land
  it or make it an explicit blocking dependency. The unresolved document
  currently lives at `roadmap/discarded/session_witness_gate.md`; do not treat
  that path/status as accepted and do not claim password brute-force
  completeness before the prerequisite exists.
- Write the pure GCRA model and response/privacy contract tests first.

**Exit:** security review signs off threat model/defaults; proxy forgery tests
pass; the mediated password gate has a sound subject-to-token argument; no open
question can change table identity, policy semantics, or public syntax.

### Phase 1: engine and horizontal correctness

- Add Memory and PostgreSQL GCRA stores, typed key encoding/digest, dedicated
  pool/deadlines, concurrent bootstrap, bounded deny cache, cardinality cap, and
  batched cleanup.
- Add atomic same-stage multi-policy admission and retry calculation.
- Add built-in metrics with bounded labels.
- Run pure, differential, race, outage, and two-instance PostgreSQL tests.

**Exit:** simultaneous multi-instance accepted cost never exceeds budget;
PostgreSQL failure is a bounded `503`; no memory fallback exists; state growth
and cleanup are bounded.

### Phase 2: zero-code runtime protections

- Wire dispatch admission into runtime-owned SSO login/callback routes.
- Wire layered budgets into the mediated password gate.
- Add weighted Argon2, bounded SSO/provider concurrency guards, and process/per-
  client SSE connection caps with release on every exit path.
- Preserve auth timing, fixed response, no-cookie, and event-redaction rules.

**Exit:** default SSO and password abuse tests pass without a rate-limit
declaration in the application; expensive work counters prove rejected requests
never reach provider calls or Argon2.

### Phase 3: typed application surface

- Add `rateLimit` declaration and API endpoint line through lexer/parser, AST,
  validation, formatter, semantic IR/query output, linter, and Go emitter.
- Enforce key provenance/type and policy arithmetic at compile time.
- Wire pre-auth and post-auth stages, including atomic multi-policy behavior.
- Add one concise lesson using client, user, and tenant limits; update language
  spec, manual, semantic JSON, and `tesl explain` diagnostics. OpenAPI metadata
  waits for the separate OpenAPI feature.

**Exit:** examples compile; generated-source tests show dispatch-before-handler;
all misuse cases fail with stable diagnostics and useful fixes.

### Phase 4: test surface and operational gate

- Add `clientAddress`, deterministic `advanceTime`, and load-test `statusRate`.
- Add production deployment guidance: edge responsibilities, trusted proxies,
  Memory limitation, metrics, 429/503 handling, and rolling policy changes.
- Run an adversarial review focused on bypass, lockout, cardinality, pool
  starvation, privacy, and mixed-version deploys.

**Exit:** full compiler/runtime CI passes, including real PostgreSQL and race
tests; one generated app demonstrates two-instance enforcement; no security
claim exceeds the boundary below.

## Implementation map

- Compiler: tokens/parser/AST for declarations and endpoint lines; structural
  and type validation; formatter; linter; semantic IR/agent-context; Go emitter;
  generated-source tests.
- `runtime/go/teslrt/request.go`, `server.go`, `serve.go`, SSO route files:
  one request context, strict proxy/client identity, dispatch stages, responses.
- New `runtime/go/teslrt/ratelimit.go` and PostgreSQL store section/file: pure
  decision model, Memory store, GCRA admission, cleanup, digest, metrics.
- `runtime/go/teslrt/password.go` plus mediated auth gate: weighted resource
  permits and password-attempt policies.
- Agent/provider runtime chokepoint: bounded concurrent provider work; no claim
  of exact provider spend.
- API/load test runtime and compiler: fresh store, client address, fake limiter
  clock, status-rate metric.
- Docs: `LANGUAGE-SPEC.md`, manual/tour, lesson, `tesl explain`, deployment
  guidance, and cross-links from SSO/agent roadmap material.

## Rejected alternatives

- **Handler decorator or rate-limit capability.** Capabilities describe authority;
  admission describes boundary policy. It also misses runtime-owned SSO routes.
- **`RateLimit.check` library call.** It can be omitted, called after expensive
  work, given attacker-controlled data, or have its result discarded.
- **Auth-event-driven admission.** Events happen after work and are lossy
  observability, not an atomic reservation store.
- **Per-IP only.** NATs create false positives; distributed attackers rotate IPs;
  it cannot enforce user/tenant cost.
- **Per-identifier only.** It gives an attacker a victim-lockout endpoint.
- **Arbitrary `keyBy` expressions.** Effects, secrets, unstable values, and
  attacker-controlled cardinality become policy inputs.
- **Fixed windows.** Boundary double bursts. **Sliding event logs:** unbounded
  rows and cleanup cost. GCRA gives bounded state and smooth refill.
- **Redis in v1.** New required infrastructure when PostgreSQL already provides
  atomic shared state. A backend interface may permit it later if measured
  PostgreSQL contention justifies it.
- **In-memory fallback or sticky sessions.** Restart and instance hopping bypass
  the limit exactly when coordinated protection is needed.
- **Reverse proxy only.** It cannot see Tesl's proven user/tenant or internal
  password/provider chokepoints.
- **TLS termination.** Separate concern with no design dependency.

## Honest completion claim

After all phases, Tesl may claim:

> Runtime-owned authentication paths and declared application budgets are
> protected at their owning chokepoints; declared endpoint budgets run before
> handler work; PostgreSQL-backed deployments enforce one atomic budget across
> instances; key provenance, placement, and policy shape are compiler-checked;
> failures are bounded and fail closed.

Tesl must still say:

> Public deployments need an edge for volumetric/network DoS and TLS. Memory
> backends enforce only within one process. Static admission units are not an
> exact financial quota or provider bill.
