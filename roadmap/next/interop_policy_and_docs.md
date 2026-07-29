# Interop policy + docs (how to answer "I want FFI")

> **Status:** Next · **Effort:** S (docs + policy only, no compiler or runtime code)

Carved out of `roadmap/discarded/using_queues_for_ffi.md` (discarded 2026-07-29). That item
analysed FFI and declined it — again. This item writes down the resulting policy so the
question stops being re-litigated from scratch, and so the patterns people *should* use are
documented instead of rediscovered.

Nothing here changes the language. It is prose, one lesson, and one audit clarification.

## Why this is worth doing on its own

A Tesl app can already talk to non-Tesl code today (outbound HTTP + queue + worker +
`publish`), and nothing documents it. So each request arrives as "Tesl needs FFI", gets
re-analysed from first principles, and the *unsafe* shortcut — point an external worker at
the `tesl_jobs` table — is the first idea anyone has. It is also the one variant that breaks
soundness (see the discarded item, §4). Writing the rules down is cheap and prevents that.

## Deliverables

### 1. The triage rule

Document the decision procedure for any "Tesl can't do X, give me an escape hatch" request:

- **Bounded primitive gap** (hashing, regex, a date format) → add a **primitive to the
  trusted core**, behind its own capability, the way `tesl/jwt.rkt` already wraps
  libcrypto's HMAC-SHA256 as `JWT.sign`/`JWT.verify` under the `jwt` capability. Host FFI is
  allowed *maintainer-side*; it is never user-facing.
- **Large third-party ecosystem** (image processing, ML, a vendor SDK) → a separate service
  the app calls over HTTP, per the initiator rule below.
- **A general `foreign fn` / arbitrary host access from app code** → never. The return value
  would enter typed Tesl with no validating boundary, so it could forge any proof-annotated
  field, newtype or ADT tag. See `roadmap/discarded/lift-remaining-stdlib-and-foreign-fn.md`
  and the discarded FFI item.

### 2. The initiator rule

**Tesl always initiates.** A worker makes the outbound call and the reply *is* the HTTP
response. The foreign side learns no Tesl URL, holds no credential, and Tesl exposes no
inbound surface. Durability and retry come from the queue, so a dropped connection just
retries the job.

| | Reply path | Tesl exposes inbound? | Extra machinery |
|---|---|---|---|
| **Tesl initiates** (default) | response to our own outbound call | no | outbound timeout |
| **Inbound webhook** (fallback) | foreign side calls the Tesl API | **yes** | endpoint + auth + replay defence + correlation storage |

Use the webhook only when the work runs long enough (minutes+) that holding an outbound
connection is untenable — and note that once it is an ordinary authenticated Tesl endpoint it
is not interop machinery at all, it is an integration, and the existing `auth` machinery
applies unchanged.

Document the cost of the default: a blocked outbound call pins one of the queue's
`numberOfWorkers` threads, so a hung upstream starves the queue. (The missing outbound
timeout is tracked in `primitive_gaps_and_outbound_hardening.md`.)

### 3. The foreign-work recipe

**The lesson half is DONE:** `example/learn/lesson74-interop-patterns.tesl` (added 2026-07-29,
`validate` clean, 2 api-tests passing) covers both requested problems — file access and
subprocesses — and the foreign-service pattern. What remains here is the
`manual/best-practices.md` prose section, which should reference the lesson rather than repeat
it.

One section in `manual/best-practices.md`, covering the pattern that already works:

handler `enqueue`s a request job → `worker` calls the external service → result is
`insert`ed and/or `publish`ed to the caller's SSE channel.

This is the same shape as the already-specified agent resume-after pattern
(`LANGUAGE-SPEC.md:1287-1299`, `example/learn/lesson70-agent-async-work.tesl`) — reference
it rather than re-explaining it. Must cover:

- **No blocking wait exists.** There is no `sleep` and no await, so a handler cannot enqueue
  and then wait for the answer. Interop is a *workflow*, not a function call. Say this up
  front; it is the thing people trip over.
- **Correlation.** `tesl_jobs` has no `result` column, so a reply is a second job type (or a
  DB row, or an SSE event) carrying a correlation id present in both payloads.
- **Idempotency.** Queue delivery is at-least-once with retry/backoff, so the foreign side
  must tolerate duplicates.
- **Capability naming.** Name the effect, not the transport:
  `capability thumbnailer implies queueWrite` (mirroring
  `capability emailWrite implies queueWrite`, `LANGUAGE-SPEC.md:1024`), so signatures read
  `requires [thumbnailer]`. A bare `requires [httpClient]` on business logic tells a reader
  nothing.
- **The foreign side never gets app database credentials.** State it as a rule with its
  reason (next item).

### 4. `FromQueue` is provenance, not validity

Spec §11.17 (`LANGUAGE-SPEC.md:1074-1082`) should say explicitly that `FromQueue` means
"this value came off the queue" and *not* "this value is valid" — and, if external producers
ever appear, not "our own code enqueued it" either.

Worth pairing with the fact that makes the boundary trustworthy: a job payload decodes
through `jsexpr->typed-value`, and a record field carrying a `:::` annotation **cannot**
decode without a registered `#:check` — it fails closed (`dsl/types.rkt:1394`,
`coerce-record-field-value` at `:974`). So queue payloads are validated as strictly as HTTP
request bodies. That is a genuine strength and is currently undocumented.

### 5. Record that an external `tesl_jobs` consumer is not supported

With the reasoning, so it is not rediscovered as an obvious shortcut:

`tesl_jobs` lives in the app's database (`dsl/sql.rkt:2005`), so "let a non-Tesl worker
consume the queue" means handing that process the app's PostgreSQL credentials. The DB read
path does **not** re-validate record invariants — `vector->entity-row` (`dsl/sql.rkt:1834`)
never calls `coerce-record-field-value`, because the checker enforces invariants at the
write site. A process with DB write access can therefore plant rows that violate declared
invariants, and Tesl will read them back and treat those facts as established. It is the one
grant that defeats the proof system.

Also note the practical blockers, so the answer isn't purely a soundness argument: the table
is internal and unversioned, there is no `result` column, and with no PG runtime the queue is
in-memory (`tesl/queue.rkt:21-22`) so an external consumer cannot attach in dev or tests.

### 6. Keep the audit line, and make it precise

`roadmap/discarded/security_hardening_audit.md:167` counts "no user-facing FFI / `eval` /
`comptime` / `foreign`" as a surface-narrowing factor. The FFI item considered overturning
that line and decided not to — so it **stands**, and should be tightened to say what it
means: app code cannot reach any host facility that is not a declared, capability-gated
stdlib primitive, and every value entering typed Tesl from outside crosses the validating
decode boundary.

## Not in scope

- Any new language surface, declaration, or stdlib module (see
  `primitive_gaps_and_outbound_hardening.md` for the real gaps).
- A supported external queue-consumer protocol. If that is ever wanted it is a project —
  versioned view over `tesl_jobs`, a locked-down PG role, a published payload contract — not
  a doc paragraph.

## Verification

`./compile-examples.sh` green with the new lesson, byte-exact in the integration snapshot.
Anchored headings honoured if any doc gains a contracted anchor (`manual/anchors.md`).

## Related

- `roadmap/discarded/using_queues_for_ffi.md` — the analysis this is carved from
- `roadmap/next/primitive_gaps_and_outbound_hardening.md` — the code half
- `roadmap/discarded/lift-remaining-stdlib-and-foreign-fn.md` — the original `foreign fn` decline
