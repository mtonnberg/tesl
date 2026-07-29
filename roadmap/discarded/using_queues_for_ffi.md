# FFI via queues — DISCARDED (again)

> **Status:** DISCARDED (decision 2026-07-29). Second decline; the first was
> `discarded/lift-remaining-stdlib-and-foreign-fn.md` (2026-06-30, `foreign fn`).
> **Outcome:** no FFI, no new language surface. The parts worth keeping were carved out to
> `roadmap/next/interop_policy_and_docs.md` (docs + policy) and
> `roadmap/next/primitive_gaps_and_outbound_hardening.md` (the real gaps).

## Original item

### Background

Today Tesl does not offer any way of interacting with other programming languages (like
Rust, node or c++). Tesl is by design restrictive and focused on *what* to do.

We can either accept that people "should" only use Tesl the exact way we intended
(whatever that is) and exactly the way we intended — then we do not support any FFI — or we
can offer some kind of FFI capability.

One option is to do that via queues: very slow (compared to direct C++ calls via Racket,
say) but very flexible.

### Goal

* Weigh pros and cons of offering any FFI.
* Analyze, compare and present different FFI options.
* Propose a way forward.

### Notes

We have queues today and I guess a Tesl developer could just use them but make workers that
consume the items or have workers do http calls to another web server.

---

## Decision

**No FFI. No new language surface. The note above is the answer: composing what already
exists is the supported path, and it needs documentation, not machinery.**

Reasons, in the order they became decisive:

### 1. The demand was not what an FFI solves

Two concrete requests arrived (2026-07-29): **file access**, and **spawning a subprocess to
run a large workload in a container**. Neither is "reach a third-party ecosystem we will
never re-implement" — the case a general FFI exists to serve. Both are *local host access*,
and each failed on its own merits (below). The one request class that genuinely blocks
applications — password hashing / crypto — is a **primitive gap**, not an FFI gap, and is now
tracked in `primitive_gaps_and_outbound_hardening.md`.

### 2. File access fails on horizontal scaling

A container filesystem is ephemeral and replicas do not share one. So `File.write` silently
breaks horizontal scaling and contradicts the model the whole system is built on — state
lives in Postgres — while looking like a working feature until the second replica or the
first restart. Read-only needs (config, secrets) are already served by `Tesl.Env`. The
remaining uses each have a better home: uploads → `BYTEA` or an object store; exports →
generate and stream, never persist.

Worth recording, because it *was* the interesting part: a `Tesl.File` could have been
genuinely better than the norm. Audit **L3** already names file paths as an unescaped sink
and warns that a `ValidX` proof validates shape, not sink-safety — so a proof-carrying path
segment (`check File.requireSafeSegment`, in the shape of `Money.requireSameCurrency`) plus
root confinement would have *closed* an open audit item instead of widening it. The
confinement machinery even exists already: `dsl/web.rkt:2079-2110` serves static files with a
two-layer traversal defence (reject `..`/`.`/separator/NUL segments, then re-check the
`simplify-path`-resolved prefix), failing closed before auth. None of that survives the
architecture objection — a well-proven path to a filesystem that shouldn't hold state is
still the wrong feature.

### 3. Declared-program subprocess: safe-able, but bloat for the value

This was the strongest option (the only one that is deterministic, testable, needs no
network, no credential, and no second deploy artifact). A safe design does exist, and it is
worth writing down so a future reader doesn't have to re-derive it:

- The program is **declared**, not composed — an App-root declaration names an absolute
  `exec` path, a request record, a response record, a timeout, and an explicit env allowlist.
  No API takes a command string, so **input cannot select the code**.
- **No user data in argv at all.** All variability travels as JSON on stdin. Argv injection
  isn't escaped, it's *structurally absent* — stronger than parameterized SQL, which still
  has a query string.
- No shell (`subprocess` with an argv vector, never `system`/`sh -c`), absolute path, no
  `PATH` search.
- The reply is JSON on stdout through `jsexpr->typed-value`, so **the child cannot forge a
  proof**: a `:::`-annotated record field without a registered `#:check` fails closed
  (`dsl/types.rkt:1394`, `coerce-record-field-value` at `:974`). This is the line that
  separates it from `foreign fn`, which hands a raw host value straight into typed Tesl.
- The child gets no database credential, a declared timeout with kill-on-expiry, and runs
  from a `worker` (never a handler, since there is no `sleep`/await).

**Why it was still declined:**

- **It is not a sandbox, so the security win is smaller than it looks.** The child runs as the
  app's uid with the container's filesystem and network. Real containment is the container's
  job (read-only rootfs, dropped caps, seccomp, no egress). The honest guarantee is only
  "Tesl's proof and capability guarantees survive the boundary" — and the trust model is
  "code you deliberately shipped in your image", which is code you could have put in the
  runtime anyway.
- **The cost is a permanent widening of the language's shape** for that small win: a new
  App-root declaration, a new capability class, `tesl build` gaining a way to stage binaries
  into the image (with the nix/reproducibility consequences), and fiddly runtime plumbing —
  concurrent stdin/stdout/stderr pumping to avoid pipe-buffer deadlock, process groups,
  kill-on-timeout, no zombie or fd leaks across thousands of jobs.
- **It would overturn a documented strength.** `discarded/security_hardening_audit.md:167`
  counts "no user-facing FFI / `eval` / `comptime` / `foreign`" as a surface-narrowing factor
  in the threat model. Trading that away is a real cost, and it is not worth paying for a
  facility whose main use case (batch compute) has adequate answers already.
- **The container reading is worse still.** If the workload genuinely needs its *own*
  container, that means a Docker socket or a k8s Job credential — **root-equivalent on the
  host**, a far larger grant than the database credential that killed the external-worker
  option below. That belongs in a separate scheduler component, never in the app process.

### 4. Composition already covers the real case, with zero new surface

For an actual third-party ecosystem, the existing primitives compose into the whole pattern:
handler `enqueue`s → `worker` calls the service over `HttpClient` → result `insert`ed and/or
`publish`ed to the caller's SSE channel. That is the already-blessed agent resume-after shape
(`LANGUAGE-SPEC.md:1287-1299`, `example/learn/lesson70-agent-async-work.tesl`) with "an LLM"
swapped for "a Rust service". Durability, retry/backoff and dead-lettering come free from the
queue.

The rule that makes it safe is **Tesl always initiates**: the reply is the response to our
own outbound call, so the foreign side holds no credential, learns no Tesl URL, and Tesl
exposes no inbound surface. A true inbound webhook is a fallback for minutes-long work only —
and at that point it is an ordinary authenticated endpoint, not interop machinery. Both rules
are now in `interop_policy_and_docs.md`.

### 5. The literal proposal — an external worker consuming the queue — is unsound

Kept in full because it is the first idea anyone has, and it is the one that must not be
rediscovered:

`tesl_jobs` lives *in the app's database* (`dsl/sql.rkt:2005`), so "let a foreign worker
consume the queue" means handing that process the app's PostgreSQL credentials. And the DB
read path does **not** re-validate record invariants: `vector->entity-row`
(`dsl/sql.rkt:1834`) never calls `coerce-record-field-value`, because the checker enforces
invariants at the write site. **A process with DB write access can therefore plant rows that
violate declared invariants, and Tesl will read them back and treat those facts as
established.** Of every option considered, the "obvious" one grants exactly the capability
that defeats the proof system.

Note the asymmetry that makes the *payload* boundary fine while the *DB* boundary is not: a
job payload decodes through `jsexpr->typed-value` and re-checks proof-annotated fields
fail-closed (`dsl/types.rkt:1394`), whereas a DB row does not. Data in through the decoder is
validated; rows written behind our back are not.

Practical blockers on top of the soundness one: `tesl_jobs` is internal and unversioned,
there is no `result` column, and with no PG runtime the queue is in-memory
(`tesl/queue.rkt:21-22`), so an external consumer cannot attach in dev or tests. Supporting
it properly would mean a versioned view, a published payload contract and a locked-down PG
role — a project, not a paragraph.

---

## Options considered (for the record)

| # | Option | Foreign side gets | Result re-validated? | Verdict |
|---|---|---|---|---|
| O1 | External worker polls `tesl_jobs` | **full DB credentials** | no, for anything it writes | **Rejected — unsound** (§5) |
| O2 | Queue schedules; Tesl worker calls out and waits | payload only | yes | **Supported today**, no new surface (§4) |
| O3 | Synchronous HTTP sidecar from a handler | payload only | yes | Supported today; needs the outbound timeout |
| O4 | Declared-program subprocess from a worker | payload only | yes | **Rejected — bloat for the value** (§3) |
| O5 | Specific primitives in the trusted core (the `jwt` route) | n/a | n/a | **This is the policy** → `primitive_gaps_…` |
| O6 | `foreign fn` — direct host FFI from app code | **whole process** | **no** | **Rejected**, upholds the 2026-06-30 decline |
| O7 | In-process WASM sandbox | nothing but memory | yes | Rejected — no usable WASM host for Racket |

The load-bearing distinction across the whole table is **data boundary vs. host-value
boundary**. Anything whose result arrives as JSON crosses `jsexpr->typed-value` and cannot
forge a proof; anything whose result arrives as a host value (O6) is a hole in the kernel.
That is why O6 is categorically different from O4, and why it stays declined regardless of
how convenient it looks.

## What would reopen this

- Two or more real applications blocked **after** `tesl_crypto.md` and
  `primitive_gaps_and_outbound_hardening.md` ship. The prediction on record is that crypto +
  regex removes most of the demand; if that is wrong, the evidence belongs here.
- A demand that is genuinely a third-party ecosystem (image/PDF/protobuf/ML) rather than
  local host access — and where an out-of-process service over HTTP has been tried and found
  wanting for a stated reason.
- `swappable-runtime-backend` landing with a non-Racket backend, which would make O7 (a real
  sandbox, not just a narrow interface) cheap enough to change the calculus.

## Related

- `roadmap/next/interop_policy_and_docs.md` — the policy + docs carved out of this item
- `roadmap/next/primitive_gaps_and_outbound_hardening.md` — the code items carved out of this item
- `roadmap/next/tesl_crypto.md` — the one gap that genuinely blocks apps, and the real answer to most FFI requests
- `roadmap/discarded/lift-remaining-stdlib-and-foreign-fn.md` — the first `foreign fn` decline
- `roadmap/discarded/security_hardening_audit.md` — the "no user-facing FFI" strength (§167) and audit L3/L6
- `roadmap/discarded/swappable-runtime-backend.md` — the precondition for revisiting O7
