# FFI via queues

> **Status:** Next · design decision (no implementation committed) · **Effort:** S for the
> recommended path (docs + 3 small prereqs); M–L for the optional `foreign` declaration

## Background

Today Tesl does not offer any way of interacting with other programming languages (like
Rust, node or c++). Tesl is by design restrictive and focused on *what* to do.

We can either accept that people "should" only use Tesl the exact way we intended
(whatever that is) and exactly the way we intended — then we do not support any FFI — or we
can offer some kind of FFI capability.

One option is to do that via queues: very slow (compared to direct C++ calls via Racket,
say) but very flexible.

## Goal

* Weigh pros and cons of offering any FFI.
* Analyze, compare and present different FFI options.
* Propose a way forward.

## Notes

We have queues today and I guess a Tesl developer could just use them but make workers that
consume the items or have workers do http calls to another web server.

---

## 1. What already exists (verified in-tree)

The "notes" above are correct — and stronger than they look. **A Tesl app can already reach
foreign code today with zero new language surface.** Four escape hatches exist:

| Hatch | Surface | Capability | Shape |
|---|---|---|---|
| Outbound HTTP | `HttpClient.get/post/put/delete` (`tesl/http-client.rkt`) | `httpClient` | synchronous request/response, any sidecar or remote service |
| Queue + worker | `enqueue` / `worker` / `deadWorker` (`tesl/queue.rkt`) | `queueWrite` / `queueRead` | durable async offload; a worker may itself call `HttpClient` |
| Pub/sub + SSE | `publish` / `channel` | `pubsub` | push a foreign result back to a waiting HTTP client |
| The database | `entity` / `select` / `insert` | `dbRead` / `dbWrite` | any process with credentials can read/write the same tables |

Composed, those give the full async-FFI shape *today*: handler `enqueue`s a request job →
something does the work → a Tesl `worker` folds the result back in → `publish` notifies the
caller. This is literally the blessed **resume-after** pattern already specified for agent
work (`LANGUAGE-SPEC.md:1287-1299`, `example/learn/lesson70-agent-async-work.tesl`) — the
same shape, with "an LLM" swapped for "a Rust binary".

**There is also FFI precedent inside the trusted core.** `tesl/jwt.rkt:19-66` uses
`ffi/unsafe` + `openssl/libcrypto` to get HMAC-SHA256, exposed to app code only as
`JWT.sign` / `JWT.verify` behind the `jwt` capability. So host FFI is not forbidden in
Tesl — it is *maintainer-side and capability-wrapped*, never user-facing.

### What is actually missing from the stdlib

Motivation matters more than mechanism. Enumerating §10.5 of `LANGUAGE-SPEC.md`, the real
gaps that make people ask for FFI are:

1. **Password hashing / general crypto** (bcrypt/argon2/scrypt, sha256, hmac, random bytes
   as a primitive). Today only JWT HS256 is reachable. This is the single most likely
   reason an app *cannot* be written in Tesl at all.
2. **Regex.** No `String` regex surface exists.
3. **File I/O.** No `Tesl.File`; no process spawn.
4. **Object storage / vendor SDKs** (S3, Stripe, …) — reachable over `HttpClient` but with
   no signing primitives (see 1) some are impossible.
5. **Binary formats** — protobuf/gRPC, compression, image/PDF/thumbnailing, CSV/XLSX.
6. **CPU-heavy numeric / ML inference.**

Note the split: **1–4 are primitive gaps** (small, bounded, belong in the trusted core the
way `jwt` does); **5–6 are genuine foreign-code cases** (large third-party ecosystems we
will never re-implement). A general FFI only pays for 5–6.

### Prior decision on record

`roadmap/discarded/lift-remaining-stdlib-and-foreign-fn.md:50-55` already **declined**
`foreign fn`: *"Adding a host-FFI form introduces a new trust boundary and surface; the
security audit explicitly lists 'no user-facing FFI' as a strength. It closes no real gap.
A genuine primitive gap (e.g. password hashing) should be added as a specific primitive,
not a general FFI."* And `roadmap/discarded/security_hardening_audit.md:167` counts *no
user-facing FFI / `eval` / `comptime` / `foreign`* as a surface-narrowing factor in the
threat model. This item must either uphold that decision or overturn it explicitly — it
should not quietly route around it.

---

## 2. Should Tesl offer FFI at all?

**For:**

- **Closes the "can't build it here" cliff.** Without an escape hatch, one missing
  capability (thumbnailing, a vendor SDK) disqualifies Tesl for the whole project. An
  escape hatch converts a hard "no" into "the ugly 5% lives outside".
- **Bounded blast radius, if the boundary is data.** A JSON payload over a process boundary
  is a *narrower* trust surface than the existing `establish` escape hatch, which lets app
  code assert any `fact` with no proof at all (audit L1).
- **We are already the ones paying the cost.** Every primitive gap becomes a maintainer
  task (`Tesl.Money`, `Tesl.Units`, `Tesl.Agent`, TZif reading). An FFI transfers some of
  that from the core team to app authors.
- **The queue-shaped version needs no new language surface** — pure composition of existing
  primitives. Nothing to un-ship if it fails.

**Against:**

- **The value proposition is restriction.** "There is no way to reach arbitrary host code"
  is a *feature* we cite in the security posture. Anything reachable by app code enlarges
  the TCB.
- **Capability legibility dies at the boundary.** `requires [queueWrite]` or
  `requires [httpClient]` says nothing about what the foreign side does — it may read files,
  spawn processes, egress data. Capability chains stop describing effects.
- **Proofs do not cross.** Facts are erased on the wire (`serialize-job-payload` takes
  `raw-value`, `tesl/queue.rkt:280`), so the foreign side can neither consume nor produce
  proof-carrying values. Every foreign result must be re-validated in Tesl to be useful.
- **Determinism and reproducibility.** `tesl build` produces one image
  (`templates/docker/`, `manual/deploy.md`: *"deliberately just an image"*). A sidecar means
  two artifacts, a compose file, version skew, and a deploy story we do not own.
- **Testability.** Tesl's own test surface cannot drive foreign code — see §5.
- **Escape hatches become the norm.** If FFI is easy, "just do it in node" out-competes
  "model it in Tesl", and the proof discipline erodes from the edges inward.

**Reading:** the *general* argument against FFI is strong, and the *specific* argument for
async foreign work (cases 5–6) is real but narrow. That points at "bless a pattern, don't
add a language form" — see §6.

---

## 3. Option catalogue

| # | Option | Round-trip cost¹ | Foreign side gets | Payload re-validated? | Testable today | Language surface |
|---|---|---|---|---|---|---|
| O0 | Do nothing, document nothing | — | — | — | — | none |
| O1 | Foreign worker polls `tesl_jobs` directly (the literal proposal) | ~5–20 ms + poll | **full DB credentials** | yes (in) / **no** (out, if it writes entity rows) | no | none |
| O2 | Queue schedules, Tesl relays over HTTP/stdio; foreign side never sees PG | ~5–20 ms + call | payload only | yes | no (needs stub) | none |
| O3 | Synchronous HTTP sidecar from a handler | ~0.2–1 ms | payload only | yes | no (needs stub) | none |
| O4 | Subprocess stdio worker (`Tesl.Process`-style primitive) | ~0.05–1 ms | payload only | yes | yes (deterministic) | new primitive + capability |
| O5 | Add specific primitives to the trusted core (the `jwt` route) | µs | n/a (in-core) | n/a | yes | new stdlib names |
| O6 | `foreign fn` — direct Racket/C FFI from app code | ns–µs | **whole process** | **no** | yes | new declaration form |
| O7 | In-process WASM sandbox | µs | nothing but memory | yes | yes | new declaration + host runtime |

¹ Order-of-magnitude estimates, **unmeasured**. Benchmarking O2–O4 is a prerequisite for
any decision that leans on these numbers.

### Notes per option

- **O1** is the item's own proposal, and it is the *worst* variant of it — see §4. Blessing
  it also freezes `tesl_jobs` (an internal table, `dsl/sql.rkt:2005`) into a public
  protocol, and there is no `result` column, so responses need a second job type anyway.
- **O2** keeps every queue benefit (durability, retry/backoff, dead-letter, transactional
  enqueue — `enqueue!` commits with the surrounding transaction and NOTIFYs on commit,
  `LANGUAGE-SPEC.md:1986`) while the foreign process holds nothing but the payload.
  Strictly better than O1 at the same cost.
- **O3** is available *right now* with no changes, and is the right shape when the caller
  must have the answer to build its response. Blocking: `do-http-request`
  (`tesl/http-client.rkt:114`) has **no connect or read timeout** — only a 10 MiB body cap
  — so a hung sidecar pins a request thread indefinitely. Inside a `transaction` it also
  holds a DB pool slot for the duration.
- **O4** is the cheapest *general* escape hatch and the only one that is deterministic in
  tests, but it puts arbitrary binaries in the image, breaks the single-artifact deploy
  story, and needs a real capability + argv/environment hardening.
- **O5** is the current de-facto policy and closes gaps 1–4 completely. It does not address
  5–6.
- **O6** is declined on record. Restated: an FFI return value enters typed Tesl with **no
  validating boundary** (at best `runtime-type-satisfied?`), so it can forge any
  proof-annotated record field, any newtype, any ADT tag. It is not "one more capability";
  it is a hole in the kernel.
- **O7** is theoretically the best isolation story and practically unavailable: there is no
  usable WASM runtime for Racket, so hosting one means C FFI to wasmtime *in the trusted
  core* plus a component-model ABI. Revisit only if `swappable-runtime-backend` lands and
  the backend is no longer Racket.

---

## 4. Soundness analysis (the decisive part)

Four facts, verified in the current tree, determine which options are admissible:

1. **The JSON boundary re-validates record field proofs, fail-closed.** Decoding a record
   whose field carries a `:::` annotation *requires* a registered checker — without one it
   raises *"cannot decode proof-annotated field … without an explicit `#:check`"*
   (`dsl/types.rkt:1394`); with one, `coerce-record-field-value` (`dsl/types.rkt:974`) runs
   it. The checker is emitted by `emit_racket.ml:6047`. Job payloads go through exactly
   this path (`deserialize-job-payload`, `tesl/queue.rkt:287`). **So a foreign producer's
   payload is validated as strictly as an HTTP request body.**
2. **The DB read path does *not* re-validate.** `vector->entity-row` (`dsl/sql.rkt:1834`)
   decodes column values and never calls `coerce-record-field-value`. Record invariants are
   enforced by the checker at the write site only. **A foreign process holding DB
   credentials can therefore plant rows that violate declared invariants, and Tesl will read
   them back and treat those facts as established.**
3. **Facts are erased on the wire** (`serialize-job-payload`, `tesl/queue.rkt:280`), so no
   proof survives the hop in either direction. Correct, and it means the boundary is
   honest: everything must be re-established.
4. **`FromQueue` is a provenance predicate, not a validity one** (spec §11.17,
   `LANGUAGE-SPEC.md:1074-1082`). Today "came off our queue" implicitly also means "our own
   code put it there". Admitting foreign producers weakens that reading, and the docs must
   say so explicitly.

**Consequence: (1) + (2) rule out O1.** The queue lives *in the database*, so "let a foreign
worker consume the queue" means "hand a foreign process the app's PostgreSQL credentials" —
which grants exactly the one capability that bypasses the checker's sole enforcement of
record invariants. The narrow, validated boundary we wanted is undermined by the widest
possible grant.

If O1 is pursued anyway, it is only defensible with a **dedicated PG role** whose grants
are limited to `tesl_jobs` (ideally row-level by `queue_name`) and nothing else — no entity
tables, no `tesl_pubsub_outbox`, no DDL. That is a real ops burden pushed onto every user,
which is why O2 (Tesl keeps the credentials, relays the payload) is the better shape at
identical latency.

**Capability legibility** is fixable by convention, not new surface: the existing derived
capability form already covers it —
`capability imageResize implies queueWrite` (cf. `capability emailWrite implies queueWrite`,
`LANGUAGE-SPEC.md:1024`). A signature then reads `requires [imageResize]`, naming the
foreign effect rather than the transport. This should be a documented rule, and a lint
(warn when `queueWrite`/`httpClient` is required directly by app code that talks to a
foreign interface) if the pattern is blessed.

---

## 5. Gaps that must be closed before any foreign-work pattern is blessed

1. **No reply channel.** `tesl_jobs` has no `result` column (`dsl/sql.rkt:2008-2017`).
   Responses need a second job type + a correlation id carried in both payloads. Document
   the convention; do not add a column (it would make jobs bidirectional and break the
   fire-and-forget model).
2. **No blocking wait.** There is no `sleep` and no await; a handler cannot enqueue and then
   wait. Any queue-shaped foreign call is therefore **async at the API level too** — the
   caller gets `202`-ish and learns the result via SSE/email/polling (resume-after). FFI as
   a *function call* is not expressible over queues; only FFI as a *workflow* is. This is
   the single biggest ergonomic con and belongs in the docs up front.
3. **Untestable.** `processNextJob` / `drainQueue` run the *Tesl* worker synchronously
   (`LANGUAGE-SPEC.md:901`) — they cannot drive a foreign worker. There is also **no
   outbound-HTTP stubbing** in `tesl/api-test.rkt`. So today no `api-test` can cover a
   foreign hop in either transport. **Prerequisite:** an api-test double — canned answer for
   an outbound call, and/or "answer this pending job with this payload".
4. **No cross-process queue without PostgreSQL.** With no DB runtime the queue is
   in-memory (`tesl/queue.rkt:21-22`), so a foreign worker cannot attach in dev or tests.
   Document "foreign workers require the PG backend", which makes (3) mandatory rather than
   nice-to-have.
5. **Observability blind spot.** The built-in metric catalog covers enqueue / job-duration /
   dead-letters (`LANGUAGE-SPEC.md:181`), all recorded by the *Tesl* worker. A job handled
   externally simply vanishes from `tesl_jobs`; foreign latency and failure are invisible.
   Needs at minimum a queue-level "handled externally" dimension.
6. **No outbound timeout** (`tesl/http-client.rkt:114`) — must land before any synchronous
   sidecar is recommended.
7. **Poison payloads.** A malformed foreign payload raises inside the worker → job fails →
   retries → `dead`. Verify that a decode error fails the *job* and not the worker thread,
   and that the dead-letter path is reached (dead-letter polling is single-threaded, every
   10 s, no NOTIFY — spec §11.17).
8. **Schema knowledge.** The foreign side must know the PG schema name, the `__type` payload
   tag convention, and the status vocabulary — all internal today.
9. **Deploy story.** `templates/docker/` has all-in-one and app-only only; no sidecar
   template, no compose. Blessing a sidecar means owning a third template.

---

## 6. Proposed way forward

**Do not add a user-facing FFI form. Keep the "no `foreign fn`" decision. Bless a
pattern, close the primitive gaps, and make the pattern testable.**

Concretely, in order:

**Phase A — policy + docs (S, no code).**
- Write down the triage rule that is already de-facto policy: *a bounded primitive gap gets
  a primitive in the trusted core (the `jwt`/libcrypto route); only large third-party
  ecosystems justify a foreign process.*
- Document the **foreign-work recipe** (O2/O3) in `manual/best-practices.md` + one lesson:
  request job type → foreign work → response job type or SSE, correlation id, derived
  capability naming (`capability thumbnailer implies queueWrite`), idempotency because
  retries are at-least-once, and the explicit rule **the foreign process never gets app
  database credentials**.
- Document that `FromQueue` is provenance-only and what it does *not* mean once foreign
  producers exist.
- Explicitly record that **O1 (foreign consumer of `tesl_jobs`) is not supported**, with the
  §4 reasoning, so it does not get rediscovered as an obvious shortcut.

**Phase B — prerequisites that stand on their own merit (S–M each).**
- Outbound HTTP connect/read timeout (fixes a live DoS-shaped bug regardless of FFI).
- api-test doubles: stub an outbound HTTP call; answer a pending job with a payload.
- Foreign-hop visibility in the queue metrics.
- Close primitive gaps 1–2 from §1 (`Tesl.Crypto`: sha256/hmac/random bytes/password
  hashing; regex on `String`) — each behind its own capability, each following `jwt`.

**Phase C — only if demand is demonstrated (M–L, do not start speculatively).**
A declarative `foreign` interface: declare the request/response record types and the
transport once, and let the compiler emit the wiring plus a **typed stub for the foreign
side** (the `emit_ts` client generator run in reverse — we already generate typed clients;
generating a typed server skeleton is the same machinery). Validation stays at the JSON
boundary; the capability is derived automatically; the transport (queue-relayed or
synchronous HTTP) is a field, not a rewrite.

**Rejected outright:** O1 as specified, O6 (`foreign fn`), O7 (no viable Racket WASM host).

**Trigger to revisit:** two or more real applications blocked by cases 5–6 *after* Phase B
lands, or `swappable-runtime-backend` making O7 cheap.

### Verification bar (if Phase B/C ship)

`./compile-examples.sh` green (the authoritative gate), the new lesson byte-exact in the
integration snapshot, an api-test that covers a foreign hop end-to-end via the new doubles,
a negative test that a malformed foreign payload fails the job and reaches the dead-letter
path, and a soundness test that a proof-annotated field on a foreign payload **cannot**
decode without its checker.

---

## 7. Open questions

1. Is the motivating demand actually cases 5–6, or is it cases 1–4 in disguise? If it is
   1–4, Phase B alone closes it and Phase C never runs. **This should be answered before
   any implementation.**
2. Does anyone want the *synchronous* shape (O3/O4) badly enough to accept a blocking
   handler, or is async-only acceptable? That choice decides whether O4's new primitive is
   needed at all.
3. If a foreign interface is declared, should its capability be *inferable* — i.e. can the
   compiler reject `requires [queueWrite]` in favour of the named foreign capability?
4. Do we ever want the reverse direction — a foreign process *initiating* work (external
   producer)? §4(1) says the payload boundary is already safe enough for it; the question is
   whether an HTTP endpoint is simply the better answer for that case.
5. Should `tesl doc` publish the foreign interface contract (payload schema + transport) the
   way it publishes the stdlib catalog, so the foreign side has a generated, versioned
   spec rather than a hand-copied one?
