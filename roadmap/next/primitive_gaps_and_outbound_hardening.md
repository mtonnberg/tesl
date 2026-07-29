# Primitive gaps + outbound-call hardening

> **Status:** Next · **Effort:** S (timeout) · S–M (api-test stub) · M (regex)

Carved out of `roadmap/discarded/using_queues_for_ffi.md` (discarded 2026-07-29). That item
declined FFI; these are the items from its "Phase B" that stand entirely on their own merit.
**None of them depends on FFI, and each is independently justifiable.**

Ordered by value-to-cost. Items 1 and 2 are the ones with a live defect behind them.

---

## 1. Outbound HTTP has no timeout — live bug

`do-http-request` (`tesl/http-client.rkt:114`) calls `http-sendrecv` with **no connect
deadline and no read deadline**. There is a 10 MiB response-body cap (added for the DoS
case) and nothing else. A slow or hung upstream therefore blocks the calling thread
indefinitely.

Consequences today, with no new features involved:

- A hung upstream in a **handler** pins a request thread. Inside a `transaction` it also
  holds a DB pool slot for the whole time (cf. the pool-lease work in issue #31).
- A hung upstream in a **worker** pins one of that queue's `numberOfWorkers` threads. Enough
  of them and the queue stops draining — the retry/backoff machinery never gets a chance to
  do its job, because the job never fails, it just hangs.
- `Tesl.Agent` calls LLM providers over this path, and provider stalls are routine. This is
  the most likely way a real deployment hits it.

**Work:** connect + read timeouts, configurable with a conservative default, surfaced as a
clean `check-fail`-shaped error rather than a raw Racket exception (the existing handler
already wraps failures as `raise-user-error 'HttpClient`). Decide whether the timeout is
per-declaration, per-call, or env-configured like `TESL_HTTP_MAX_RESPONSE_BYTES`. Same
treatment for `http-post-stream` (`:184`), where an idle SSE stream needs an idle timeout
rather than a total one.

**Tests:** a server that accepts and never responds → the call fails within the deadline; a
server that sends headers then stalls mid-body → same; the streaming variant on an idle
stream; and a test that the failure fails the *job* (retry → dead-letter) rather than
killing the worker thread.

---

## 2. Outbound HTTP is not testable

There is no stubbing or interception for outbound calls anywhere in `tesl/api-test.rkt` or
`dsl/test-support.rkt`. Consequences:

- `example/learn/lesson58-httpclient.tesl` demonstrates the feature and cannot assert
  anything about it.
- Any app whose handler or worker calls an external service has an untestable branch —
  including every `Tesl.Agent` app, which is most of the AI surface.
- The error paths are the ones you most want covered (upstream 500, malformed JSON,
  timeout from item 1) and they are exactly the ones you cannot provoke against a real
  upstream.

**Work:** an api-test-scoped double — declare canned responses for a URL or method+URL
pattern, assert that the expected call was made, and let a stub raise/timeout so the failure
path is reachable. It must be scoped to the test run (no global mutable state leaking between
tests) and must not exist in production builds.

Note this is a **strictly better** answer than the earlier "let an external process handle
the job" idea: the double is deterministic, needs no network, and makes the failure paths
testable, which a real sidecar never would.

---

## 3. `Tesl.Crypto` — split out, see `tesl_crypto.md`

Hashing / HMAC / CSPRNG / password storage was originally item 3 here. It is **much** larger
than its siblings — a native dependency decision (argon2 is not in libcrypto), a proof design
(keeping plaintext passwords out of entity fields), capability granularity, and it is the
unlock for audit gap L2 (no signed-session primitive; the examples model a guessable plaintext
cookie). Moved to its own item: **`roadmap/next/tesl_crypto.md`**.

It is also the item that actually answers most "Tesl needs FFI" requests, so it outranks
everything else on this list by value — it is listed here only to keep the trail.

---

## 4. Regex on `String`

`Tesl.String` has ~20 functions and no regex (`LANGUAGE-SPEC.md` §10.5). Every non-trivial
validation — the `check` functions that mint `ValidEmail`-style facts, which is a *core* Tesl
idiom — is written by hand out of `contains`/`split`/`indexOf`.

**Design questions:**

- **Compile-time-checked patterns?** A literal pattern could be validated at compile time
  and a malformed one become a compile error rather than a runtime raise. That is the Tesl
  move and would make regex better here than in most languages.
- **ReDoS.** Racket's `regexp` is backtracking; a user-supplied pattern (or a hostile input
  against a pathological literal pattern) is audit L6 territory (resource exhaustion). Either
  restrict to literal patterns, or use `pregexp`'s safer subset, or bound execution. Do not
  ship a `String.matches userPattern input` that takes a pattern from request data.
- Surface: `matches`, `find`/`findAll`, `replace`, `split` — and whether capture groups
  return `Maybe (List String)` or something richer.

---

## 5. `Bytes` is an inert type (small, do only if item 3 needs it)

`Bytes` is a primitive type name that maps to `BYTEA` (`LANGUAGE-SPEC.md:1782`,
`dsl/types.rkt:310`), so it can be declared as an entity field — but **nothing in the stdlib
constructs or consumes one**. A user can declare a `Bytes` column and has no way to put a
value in it.

That is a real inconsistency, but low value on its own. If `Tesl.Crypto` returns hex/base64
`String`s, this stays deferred; if anything ever needs real binary, it needs
`Bytes.length` / `toString` / `fromString` (UTF-8, fallible) / base64 / slice first. Decide as
part of `tesl_crypto.md`, not before.

---

## Explicitly dropped from the original Phase B

- **"Foreign-hop dimension in the queue metrics."** It existed only to observe work handled
  by a non-Tesl process. With FFI discarded there is no such hop; the built-in catalog
  already covers enqueue / job-duration / dead-letters for Tesl workers
  (`LANGUAGE-SPEC.md:181`).
- **"Answer a pending job with a payload" api-test double.** Only needed to simulate an
  external worker. `processNextJob` / `drainQueue` already drive Tesl workers synchronously
  (`LANGUAGE-SPEC.md:901`). The *outbound HTTP* half of that item survives as item 2.

## Verification bar

`./compile-examples.sh` green (the authoritative gate), new lessons byte-exact in the
integration snapshot, `test_stdlib_runtime_binding.ml` still passing (every new stdlib name
must resolve to a real Racket provide — this is the seam test that catches
typechecks-but-unbound), and stdlib signature/doc coverage held (`tesl doc` catalog +
`test_stdlib_signature_coverage.ml`).

Per item: the timeout tests in item 1; a stubbed-upstream api-test in item 2; known-answer
tests against published vectors for every hash/HMAC in item 3 plus a constant-time-compare
test; a ReDoS-bound test in item 4.

## Related

- `roadmap/discarded/using_queues_for_ffi.md` — the analysis these were carved from
- `roadmap/next/interop_policy_and_docs.md` — the docs half (item 3 here is the *answer* to
  most FFI requests, so the two ship well together)
