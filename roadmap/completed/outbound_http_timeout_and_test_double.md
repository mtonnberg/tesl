# Outbound HTTP: deadlines + an api-test-scoped test double

> **Status:** Completed · Items **1** and **2** of
> `roadmap/next/primitive_gaps_and_outbound_hardening.md`
> (items 3–5 remain open there; item 3 moved to `roadmap/next/tesl_crypto.md`).

Two halves of the same problem. Outbound HTTP had **no deadline** (so a hung
upstream pinned whatever thread called it) and **no way to stub it** (so the
failure branches — including the new timeout — were unreachable from a test).
Item 1 first, because item 2 has to be able to inject item 1's error.

---

## What shipped

### Item 1 — every outbound call has a deadline

`do-http-request` called `http-sendrecv` with no connect deadline and no read
deadline. `http-sendrecv` is exactly `http-conn-open` + `http-conn-sendrecv!
#:close? #t`, so it was split into those two phases without changing the request
on the wire — which is what lets connect and read carry *separate* budgets.

| Phase | Env var | Default | Bounds |
|---|---|---|---|
| Connect | `TESL_HTTP_CONNECT_TIMEOUT_MS` | 10000 | TCP + TLS handshake |
| Read | `TESL_HTTP_TIMEOUT_MS` | 30000 | send + status line + headers + the whole body |
| Stream idle | `TESL_HTTP_STREAM_IDLE_TIMEOUT_MS` | 60000 | `http-post-stream`: the max **gap** between bytes |

Failure shape is unchanged from the rest of the module: `raise-user-error
'HttpClient`, i.e. `exn:fail:user`, never a raw Racket exception. The generic
"HTTP … failed: …" wrapper now lets an already-`HttpClient`-shaped error through
instead of nesting it, so a deadline reads as one clean line.

### Item 2 — an outbound-HTTP double, scoped to the test run

Six new `Tesl.ApiTest` names, usable as ordinary statements in a `test`,
`api-test`, or `load-test` body:

```tesl
stubHttp        : (method: String) (url: String) (status: Int) (body: String) -> Unit
stubHttpFailure : (method: String) (url: String) (message: String)            -> Unit
stubHttpTimeout : (method: String) (url: String)                              -> Unit
httpCalled      : (method: String) (url: String) -> Bool
httpCallCount   : (method: String) (url: String) -> Int
httpLastBody    : (method: String) (url: String) -> String
```

```tesl
test "the upstream-500 branch is reachable" requires [webClient] {
  stubHttp "GET" "https://api.example.com/rates" 500 "upstream exploded"
  let resp = fetchRates "https://api.example.com/rates"
  expect classifyStatusCode resp.status == "server-error"
  expect httpCallCount "GET" "https://api.example.com/rates" == 1
}
```

### Two live bugs the tests uncovered on the way

Both were in the outbound path, both crashed with a **raw Racket contract
violation** rather than an `HttpClient` error, and both are fixed here:

1. **Every request with a custom header died.** A Tesl `List (Tuple2 String
   String)` reaches the runtime as a list of `Tuple2` **ADT values**
   (`tesl/tuple.rkt`), not 2-element lists. The header split assumed the latter
   (`(if (list? h) (first h) h)`) and handed the whole struct to the CR/LF guard
   → `regexp-match?: contract violation`. So the documented way to authenticate
   an outbound call — lesson58's own `buildBearerHeader` example — could not
   work. `http-header-pair` now accepts both shapes and errors cleanly on
   anything else. (Nothing caught this because no test ever sent a real request
   with a header: the runtime suite only ever asserted that *some* error was
   raised.)
2. **Every URL with a `?query` died.** `url-query` yields `(symbol . value)`
   pairs and the query-string rebuild passed the symbol straight to
   `string-append`.

---

## Design decisions

### Timeout configuration: env vars, not per-call and not per-declaration

Env vars, matching the `TESL_HTTP_MAX_RESPONSE_BYTES` cap that already sits ten
lines away in the same function.

- **Per-call argument** would change all four public signatures
  (`HttpClient.get/post/put/delete`), their `stdlib_env` schemes, their doc
  entries, and every call site — pushing an operational concern into the type of
  a business-logic call, forever.
- **Per-declaration clause** has nowhere to live: there is no `httpClient`
  config *block* (unlike `cache` / `email`), so it would need new grammar for a
  deployment knob.
- A deadline is deployment tuning of exactly the same kind as the response-body
  cap, and the env var is the established idiom for that here.
- It also keeps every emitted `.rkt` byte-identical, so no snapshot churn.

Values are read **fresh on each call**, not at module load, so a test can set a
500 ms budget without a restart (which is how the regression suite avoids waiting
out a 30 s default).

### The streaming timeout is idle, not total

An SSE stream is legitimately long-lived, so a total deadline is the wrong shape:
what is broken is an upstream that has *stopped producing*, not one that has been
producing for a long time. The returned body port is wrapped with
`make-input-port/read-to-peek` (which derives correct peeking — `read-line …
'any` needs it — from a single `read-in`), and each blocking read syncs on the
raw port with the idle budget. Syncing on the port is unambiguous here because
one byte is all we need.

The status line + headers get one idle budget as well; after that the per-read
budget takes over.

### How the deadline is imposed at all

Racket's TCP/TLS connect and its port reads take no timeout argument, so it comes
from outside: the phase runs in a child thread whose `current-custodian` is a
per-request custodian, and a timeout kills the thread **and** shuts the custodian
down. Without the custodian a killed thread leaks the half-open socket — the
"timeout" would just become a slower resource leak. The custodian is released on
the success path too (a unary request releases it once the body is in hand; a
stream releases it from the wrapper port's `close`, which the existing
`dynamic-wind` in `agent-provider.rkt` already calls).

### The double's interception seam

`tesl/private/http-stub.rkt` is a new three-line module holding **one parameter**
and no logic. `tesl/http-client.rkt` (production code) consults it; everything
else — the registry, the URL matcher, the canned responses, the call log — lives
in `dsl/test-support.rkt`, which is required only from a `(module+ test …)`
submodule and is therefore never instantiated by a production `racket app.rkt`.
That is the answer to "must not exist in production builds": the *double* does
not exist there, only the inert seam does.

`http-client.rkt` could not simply require the test framework (wrong dependency
direction, and a load cycle), and a `#f`-valued parameter is the cheapest neutral
place both sides can see.

### Scoping: a fresh table per test block, no global mutable state

The scope is installed by **`call-with-fresh-memory-db`**, which already wraps
every `test`, `api-test`, and `load-test` body. Two consequences:

- the rules and the call log live in a struct created per invocation and reached
  through a `parameterize`, so they unwind with the test body — there is no
  module-level registry to leak (unlike the worker registries next door, which
  are global hashes reset by hand);
- **the emitter needed no change at all**, so every committed `.rkt` snapshot
  stays byte-identical, and plain `test` blocks get the double too (which is what
  lets lesson58 — a lesson with no `server` — assert anything).

Outside a test body the parameter is `#f` and every entry point raises a targeted
error rather than silently doing nothing.

### Matching: patterns, not regex; first match wins

Method matching is case-insensitive, URL matching is exact. `"*"` matches
anything and a trailing `*` matches a URL prefix (which covers a query string or
a path parameter). Deliberately not a regex — a stub pattern is a test fixture,
and a second pattern language in the surface is a cost with no matching benefit
(and would pre-empt the regex design questions in item 4 of the parent roadmap).

Rules are consulted in **declaration order, first match wins**, so a specific
stub declared before a `"*"` catch-all keeps winning. Re-declaring the *same*
method+URL pair replaces the earlier rule in place rather than shadowing it, so a
later line in the same test overrides an earlier one.

### Unmatched calls: opt-in strictness

A test that declares **no** stub behaves exactly as before — outbound calls reach
the network, so no existing test changes meaning. From the **first** stub onward,
an unmatched call is a loud error naming the declared rules, so a test can never
half-stub and quietly hit a live service. This is the smallest rule that is both
backward-compatible and safe.

### The canned response carries status + body, not headers

`stubHttp` answers with an empty header list. Response headers would need a fifth
argument (or a builder) for a case no lesson needs; the request-side assertion
that matters — *what did my code send* — is covered by `httpLastBody`. Adding
response headers later is additive.

### Timeout/failure messages are the production messages

`stubHttpTimeout` raises byte-for-byte the message the real deadline produces
(including the currently-configured budget), and `stubHttpFailure` uses the real
connection-failure wrapper. A test written against the stub therefore matches
what production logs, and `dsl/test-support.rkt` reads the budgets from
`http-client.rkt` rather than re-declaring the defaults.

---

## Files

| File | Change |
|---|---|
| `tesl/private/http-stub.rkt` | **new** — the interception seam (one parameter, no logic) |
| `tesl/http-client.rkt` | connect/read/idle deadlines, custodian-backed deadline guard, idle-timeout port wrapper, stub interception, Tuple2-header fix, `?query` fix |
| `dsl/test-support.rkt` | the stub engine: per-test scope, matcher, call log, the six entry points; scope installed in `call-with-fresh-memory-db` |
| `tesl/api-test.rkt` | the six `Tesl.ApiTest` names |
| `compiler/lib/type_system.ml` | `stdlib_env` schemes, `Tesl.ApiTest` export list, bare-name home-module rows |
| `compiler/lib/stdlib_docs_entries.ml` | `tesl doc` catalog rows (KFunction, so signature coverage is held with no ratchet entry) |
| `example/learn/lesson58-httpclient.tesl` | now asserts: happy path, request body sent, upstream 500, malformed body, timeout, refused connection, bearer auth — plus a teaching section on deadlines and stubbing |
| `LANGUAGE-SPEC.md` | §21.3 timeout table + §11.14 "Stubbing outbound HTTP" |
| `manual/best-practices.md` | §4b outbound-HTTP testing patterns |
| `ci.sh` | `tests/http-timeout-tests.rkt` added to the Racket suites |

## Tests

**`tests/http-timeout-tests.rkt`** (gated in `ci.sh`, phase 11) — real loopback
servers. Unlike `tests/httpclient-test.rkt` (deliberately *not* gated) every
server here **accepts** the connection, so nothing depends on how the network
filters a connect to a dead port; the suite self-skips if it cannot bind.

- defaults are present; each budget is env-configurable; junk falls back to the
  default rather than disabling the deadline
- a server that accepts and never responds → fails within the deadline
- a server that sends headers then stalls **mid-body** → fails within the
  deadline (the pre-fix code got past `http-sendrecv` and blocked in the body
  read, so this is not the same case as the one above)
- a connect that is never accepted → bounded
- a responsive server is unaffected
- a `Tuple2` header reaches the wire; a `?query` URL reaches the wire
- streaming: survives six events spread over several idle budgets, then fails
  once the upstream goes quiet

**`tests/http-stub-tests.tesl`** (17 blocks, in the normal Tesl test sweep) —
canned responses, method+URL matching, prefix wildcard, first-match-wins,
re-stub-replaces, upstream 500, malformed JSON, injected failure, injected
timeout, unmatched-call-fails-loudly, call assertions, `httpLastBody`, and two
paired blocks pinning that nothing leaks between tests.

**STUB-15 / STUB-16 in that file** are the item-1 × item-2 composition the spec
asked for: a worker whose upstream call times out **fails the job** — the worker
thread survives, the job is retried, and the second attempt exhausts
`maxAttempts` and dead-letters it (`pendingJobCount == 0`, `List.length
(deadJobs …) == 1`), with the stub confirming the upstream was hit exactly twice.
STUB-16 shows the same worker succeeding when the upstream answers.

**`example/learn/lesson58-httpclient.tesl`** — 7 new blocks; the lesson finally
asserts something about the feature it teaches.

## Not done (deliberate)

- **Response headers in a canned stub** — see above; additive when something
  needs it.
- **A per-call / per-declaration timeout override** — see above. If a single
  endpoint ever genuinely needs its own budget, the natural shape is a config
  block for `httpClient`, not a fourth argument on four functions.
- **Stubbing at the `Tesl.Agent` provider layer** — not needed: providers call
  out through `HttpClient.post` / `http-post-stream`, so they are already covered
  by this double (and `mockProvider` remains the ergonomic choice for agent
  tests).
