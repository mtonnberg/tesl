# Primitive gaps + outbound-call hardening

> **Status:** Next · **Effort:** S — **items 1, 2 and 4 are DONE** (2026-07-29). What remains is
> item 3 (`Tesl.Crypto`, split out to its own file) and item 5 (`Bytes`, decided: deferred).

Carved out of `roadmap/discarded/using_queues_for_ffi.md` (discarded 2026-07-29). That item
declined FFI; these are the items from its "Phase B" that stand entirely on their own merit.
**None of them depends on FFI, and each is independently justifiable.**

Ordered by value-to-cost. Items 1 and 2 were the ones with a live defect behind them.

---

## ~~1. Outbound HTTP has no timeout — live bug~~ — DONE

~~`do-http-request` calls `http-sendrecv` with no connect deadline and no read deadline, so a
slow or hung upstream blocks the calling thread indefinitely — pinning a request thread (and
its DB pool slot inside a `transaction`), or a queue worker, where the job never fails and
retry/backoff/dead-letter never run.~~

**Shipped — see `roadmap/completed/outbound_http_timeout_and_test_double.md`.**
Connect / read / SSE-idle deadlines with conservative defaults, env-configured
(`TESL_HTTP_CONNECT_TIMEOUT_MS`, `TESL_HTTP_TIMEOUT_MS`,
`TESL_HTTP_STREAM_IDLE_TIMEOUT_MS`) in the style of `TESL_HTTP_MAX_RESPONSE_BYTES`; failures
surface as `raise-user-error 'HttpClient`, never a raw Racket exception. Regression suite
`tests/http-timeout-tests.rkt` (gated in `ci.sh`) plus the worker retry → dead-letter case
STUB-15 in `tests/http-stub-tests.tesl`. Two adjacent live bugs fell out of it: outbound
requests with a `Tuple2` header, and outbound URLs with a `?query`, both crashed with a raw
contract violation.

---

## ~~2. Outbound HTTP is not testable~~ — DONE

~~There is no stubbing or interception for outbound calls anywhere in `tesl/api-test.rkt` or
`dsl/test-support.rkt`, so every handler or worker that calls an external service has an
untestable branch — and the error paths you most want covered are exactly the ones a real
upstream will not produce on demand.~~

**Shipped — see `roadmap/completed/outbound_http_timeout_and_test_double.md`.**
`Tesl.ApiTest` gains `stubHttp` / `stubHttpFailure` / `stubHttpTimeout` / `httpCalled` /
`httpCallCount` / `httpLastBody`, usable as statements in a `test`, `api-test`, or
`load-test` body. The scope is created fresh per test block by `call-with-fresh-memory-db`
(no global mutable state, no emitter change), and the double lives in `dsl/test-support.rkt`
behind a three-line inert seam in `tesl/private/http-stub.rkt`, so it does not exist in a
production build. `example/learn/lesson58-httpclient.tesl` now asserts the happy path and
every error path.

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

## ~~4. Regex on `String`~~ — **DONE**, see `roadmap/completed/string_regex.md`

Shipped 2026-07-29 as `Tesl.Regex` (`LANGUAGE-SPEC.md` §21.6):
`Regex.matches` / `find` / `findAll` / `captures` / `replace` / `split`, pure, no capability.
All three open questions resolved and written up in the completed doc:

- **Patterns are compile-time checked** — parsed by the compiler against a subset of
  `pregexp`; a malformed one is `VREGEX001`, not a runtime raise.
- **ReDoS is fail-closed** — the pattern must be a string literal at the call site
  (`VREGEX002`, no dynamic-pattern form at all), ambiguous repetition does not compile
  (`VREGEX003`, with an exact character-set rule that keeps `(?:-[a-z0-9]+)*` legal), and a
  wall-clock deadline plus input bound in `tesl/regex.rkt` backstops the rest.
- **Capture groups return `Maybe (List String)`** with no inner `Maybe`, because
  `VREGEX004` rejects the two shapes where a group can fail to participate.

Lesson: `example/learn/lesson75-regex-validation.tesl` (regex inside `check` functions that
mint `ValidEmail` / `ValidSlug`). ReDoS bound test: `tests/regex-runtime-tests.rkt`.

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

Per item: ~~the timeout tests in item 1; a stubbed-upstream api-test in item 2;~~ known-answer
tests against published vectors for every hash/HMAC in item 3 plus a constant-time-compare
test; a ReDoS-bound test in item 4 (**done** — `tests/regex-runtime-tests.rkt`).

## Related

- `roadmap/completed/outbound_http_timeout_and_test_double.md` — items 1 and 2 as shipped
- `roadmap/discarded/using_queues_for_ffi.md` — the analysis these were carved from
- `roadmap/next/interop_policy_and_docs.md` — the docs half (item 3 here is the *answer* to
  most FFI requests, so the two ship well together)
