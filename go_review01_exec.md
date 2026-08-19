# Go migration — executive report

**Date:** 2026-08-18, updated 2026-08-19 · **Branch:** `go_migration` · **Companion:**
[`go_review01.md`](go_review01.md) (technical review: 12 findings fixed, 10 open questions answered
and implemented, 2 new ones raised)

---

## Bottom line

**The Go backend is feature-complete against the corpus, structurally sound, and — after this
pass — no longer carries the class of gap that made it unsafe to default to.**

The review found six `server` declarations the Go backend silently ignored, two of them with direct
security consequence. Those are fixed, and so is the *reason they were possible*: the surface now
fails to compile when a clause is added without a decision about it. The maintainer answered all ten
open questions the review raised, and all ten are implemented and swept across the corpus.

179 of 181 corpus files emit Go, build under nine linters and pass their own tests, with the
Racket backend running the same source as a behavioural oracle. The two exceptions are refused by
design and named as such.

The strategic point was never the six clauses themselves — it was that the *class* was possible.
The standard library had a mechanism that makes a dropped export impossible; the server surface had
none. It has one now, and it is a compile-time one: adding a field to `Ast.server_form` fails to
build until someone records what the Go backend does with it. Verified by adding a probe field and
watching the build fail.

---

## Where the migration stands

| | Status |
|---|---|
| Corpus reach | **179 / 181** files (2 refused by design) |
| Gate stack on emitted code | gofmt, `go build`, `go vet`, `go test`, staticcheck, golangci-lint, gosec, govulncheck, nilaway — all mandatory |
| Differential coverage | 85 oracle cases running the same Tesl source on both backends |
| PostgreSQL | wired end to end, verified against a live cluster on both backends |
| Runtime | 22,790 lines Go, 379 test/fuzz functions, `-race` in CI |
| Misleading refusal messages | 94 → 0 |
| Open questions from the review | 10 raised, 10 answered, **10 implemented** |

Progress on refusals, as a series of re-measurements rather than one number:
49/170 → 112 → 118 → 121 → **179**, with the denominator growing as `example/kanel/` joined and
the gate growing as each linter did.

---

## What this review changed

**Twelve findings fixed.** Four are security-relevant, two were blocking a real migration, one was
a bug in the *incumbent* Racket backend, one was a checker hole, one was a corpus program that did
not build, one was 94 misleading messages.

1. **Six dropped `server` clauses** (high) — `sessionRevoked`, `sessionPreviousKey`,
   `listenAddress`, `healthProbePath`, `contentSecurityPolicy` now wired; `trustedProxies` now
   refused with the reason (the Go backend has no `request.clientAddress` to configure).
   Concretely, before this pass: a revoked session kept renewing, and a service declared
   `listenAddress Loopback` bound every interface.
2. **No security-header floor** (high) — Racket adds `nosniff`, `Referrer-Policy`,
   `X-Frame-Options`, HSTS and a CSP to every response; Go set only `Content-Type`. Now applied
   across the API, static-file and SPA surfaces.
3. **Unbounded request-body read** (medium-high, DoS) — Racket caps at 1 MiB and answers 413; Go
   read the whole body. Now shares the cap, the env override and the status code.
4. **`sessionPolicy ShortSession` only shortened the cookie** (medium) — the JWT itself still
   carried a 1-hour TTL against a 12-hour cap where Racket used 15 minutes against 8 hours.
5. **Go could not read a Racket-written ADT column** (high for migration) — the two backends
   stored measurably different JSONB shapes. A service being ported could not read its own rows.
   This is the finding that would have surfaced on day one of a real migration.
6. **Racket decoded ADT payload fields fail-open** (high, incumbent) — a `Maybe` inside a stored or
   posted variant came back as the raw wire hash instead of `Nothing`, and the type check that
   should have objected was vacuous. Affects request bodies and queue payloads, not just columns.
   Found only because the Go decoder is strict.
7. **A literal pattern against an ADT** compiled and then died at run time on Racket. Now a
   checker error, so neither backend can be handed the program.
8. **`date_trunc` unit** reached SQL as text with no closed-set check (latent).
9. **Refusal messages** — every `"… yet"` claim reviewed. Unreachable arms now say
   `internal error:` and name the invariant; real gaps state the reason; permanent-by-design
   refusals stop implying a fix is coming. Two AST forms turned out to be dead code the parser
   never produces.
10. **A corpus program did not build** (high, regression) — `lesson21-sql-reference.tesl` failed
    with `undefined: PgGroupZone`: a type declared in a Postgres-gated runtime file and used by a
    timezone-gated one, where the gates are exclusion filters. Moved to an ungated file. **Three
    bugs of this exact shape appeared in one session**, which is why the remaining recommendation
    below is about the gated file sets.
11. **No api-test could catch a content-type regression on either backend** — Go's harness sent no
    `Content-Type` at all; Racket's hands the dispatcher an already-parsed body. Go's harness now
    defaults to JSON and a test can assert the 415.
12. **Three deliberate divergences from `net/netip`** in the SSRF host classifier were untested and
    are now pinned, so "make it agree with netip" cannot be mistaken for a fix.

---

## What the ten decisions bought

Each was a maintainer decision on 2026-08-18; all are built and corpus-swept.

| | Decision | What shipped |
|---|---|---|
| OQ1 | compile-time seam | `server_form`, `EServe` and the `App` schema all fail closed on a new field |
| OQ2 | dictionary passing | polymorphic `==` works on Go; `secret` keeps its constant-time compare |
| OQ3 | automatic layout | a wide ADT is boxed (170 → 32 bytes); the corpus's own case is `chat-backend` |
| OQ4 | split equality | per-variant comparison helpers; the 364-column line is gone |
| OQ5 | remove dead forms | two unconstructible AST forms and 43 pattern sites deleted |
| OQ6 | keyed `List.unique` | O(n) where the element type has a key, matching Racket's complexity |
| OQ7 | 415 on non-JSON | both backends now refuse the same request with the same status |
| OQ8 | test `hostname.go` | 11 differential tests against `net/netip`, pinning 3 deliberate divergences |
| OQ9 | load-tests work | baselines behave exactly as Racket's do (neither stores one — a correction) |
| OQ10 | targeted `-race` | on every emitted tree that starts goroutines; zero races found |

Three further findings surfaced while implementing them — including a corpus program that did not
build (`lesson21-sql-reference.tesl`, a runtime file-set gating bug) and the fact that **no api-test
on either backend could catch a content-type regression**. Both are fixed; details in the review.

---

## Risk assessment

**The dominant risk is no longer "does it compile" — it is "does it behave the same where nothing
tests it".**

Findings 1, 4 and 5 share one shape: the Go backend compiled and passed, and behaved differently.
The oracle catches divergence in behaviour a test *exercises*; it is silent everywhere else. Three
corpus programs declared `sessionRevoked` and none asserted revocation.

All three items that were top of this list are now done: the completeness mechanism is built and
verified to trip, every security-relevant clause has a test that fails when the clause stops
working, and `hostname.go` has 11 differential tests.

What remains is one instance of the same reasoning applied to a different surface: **the gated
runtime file sets** (OQ11). A declaration in a file gated on one condition, used by a file gated on
another, builds fine until a program with the wrong combination appears. That happened three times
in one session. Eight probe builds — one per gate — would close it.

The other residual is small and fails closed: a comparing generic cannot be PARTIALLY applied
(`same 1` as a value), because the partial-application combinators have no place for the comparison
argument. No corpus program needs it.

---

## Recommendation

**Proceed, with one gate before default-on.**

The backend has earned confidence on the axis it was built to defend — it refuses what it cannot
lower, 589 times, and every refusal is now honest about why. The differential oracle and the
nine-linter gate on *emitted* code are stronger than what most transpilers ship with.

The three gates I named before default-on are now met:

- **the completeness mechanism** (OQ1) — built and verified to trip;
- **a test per security-relevant clause** — the five wired clauses, the header floor, the body cap
  and the revocation hook each have one, and the revocation test was checked to FAIL when the hook
  is neutered;
- **415 on a non-JSON body** (OQ7) — decided and implemented.

What I would still do before defaulting: **OQ11**, a mechanical check over the gated runtime file
sets. Three bugs of one shape appeared in this session — a declaration in a file gated on one
condition, used by a file gated on another — and only a corpus program with the wrong combination
catches it. Eight probe builds would close it.

**What I would not change:** the refusal-heavy design, the flat ADT layout for the common case,
`Int` that cannot be compared with `==` by accident, JWT that never parses its own header, and the
rule that a lint finding on emitted code is an emitter bug rather than a suppression.
