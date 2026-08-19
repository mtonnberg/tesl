# Formal review — Go backend (emitter + runtime)

**Date:** 2026-08-18, updated 2026-08-19 · **Branch:** `go_migration` · **Reviewer stance:**
senior language designer, adversarial where it counts.

**Status:** the ten open questions this review raised were answered by the maintainer and are all
implemented — see §7. Three further findings surfaced while implementing them (§7b), and two new
open questions replaced them (§7c).

---

## 1. Scope and method

Reviewed:

| Component | Size |
|---|---|
| `compiler/lib/emit_go.ml` | 15,076 lines OCaml, 589 refusal sites |
| `runtime/go/teslrt/` | 101 files, 22,790 lines Go |
| `runtime/go/teslrt/*_test.go` | 44 files, 8,512 lines, 379 test/fuzz functions (now 46 files, 408) |
| `compiler/test/test_emit_go.ml` | 12,272 lines, 220 alcotest cases, 85 differential-oracle runs (now 230 / 89) |
| `compiler/test/test_go_stdlib_export_seam.ml` | 160 lines, the whole stdlib inventory, asserted both ways |

Method: read the emitter's refusal surface end to end; diffed the Go runtime against the Racket
runtime clause by clause for the `server` surface; audited the runtime for the standard web
classes (headers, body limits, timing, injection, TLS); emitted and ran representative programs
against a live PostgreSQL cluster with **both** backends interleaved, in both write orders.

Every claim below was reproduced. Where a claim is a measurement, the measurement is quoted.

---

## 2. Verdict

**The design is sound and unusually well-defended for a second backend. The implementation had a
class of hole the design was specifically meant to prevent: silent clause drops.** Six `server`
clauses were parsed, validated and honoured by the Racket backend, and *ignored* by the Go
backend — including two with direct security consequence. That is the one finding in this review
that rises above "gap".

Ranking, honestly:

- **Architecture:** strong. The differential oracle, the emitted-code gate stack, and the export
  seam test are three independent mechanisms that each catch a different failure mode. I did not
  find a better-defended transpiler design to compare against in this repo's history.
- **Emitted Go:** good. Idiomatic, `gofmt`-stable by construction, `//line`-mapped to source,
  readable by a Go reviewer who has never seen Tesl. Two performance notes, one readability note.
- **Runtime Go:** good, with the caveat above. The security-sensitive primitives (constant-time
  comparison, JWT with no header parse, `noCompare` on `Int`, resolved-path static serving) are
  right and for stated reasons.
- **Test strategy:** strong on the emitter, uneven on the runtime. 14 runtime files had no direct
  unit test; more importantly, **no test asserted the six dropped clauses**, which is exactly why
  they went unnoticed. Both are now addressed for the security-relevant surface (§7).

---

## 3. Architecture assessment

### What is right, and why it matters

**The differential oracle is the load-bearing idea.** `racket_behavior_oracle` runs the *same
Tesl source* on the incumbent backend and compares behaviour, so "compiles and runs" is never
mistaken for "is correct". 85 of the 220 emitter cases carry one. This is what makes a second
backend defensible at all.

**Refusal is the default.** 589 refusal sites is not a smell — it is the design. The emitter
refuses what it cannot lower rather than emitting something plausible. The Tesl-wide failure mode
this repo has fought repeatedly ("checker accepts what codegen cannot lower") is closed here in
the right direction.

**Gates run on the *emitted* tree, not just the runtime.** `gofmt -l`, `go build`, `go vet`,
`go test`, `staticcheck`, `golangci-lint`, `gosec`, `govulncheck`, `nilaway` — all status-enforced
(`run_command` fails the case on any non-zero exit). A missing linter is a failure, not a skip.
The stated contract — *a lint finding on emitted code is an emitter bug, never a suppression* — is
the right contract, and it is enforced.

**`Int` cannot be compared with `==` by accident.** `noCompare [0]func()` makes raw `==` and
`map[Int]` compile errors. This is the correct use of the type system to make a semantic rule
mechanical, and it has an int64 fast path so the safety is free.

**JWT verification never parses the header.** Fixed HS256, `kid` derived from the key. Immune to
`alg=none` and algorithm confusion by construction rather than by a check that could be reordered.

### Where the architecture leaves a seam

**The `server` clause surface has no completeness mechanism.** `Type_system.tesl_module_exports`
is walked by a seam test that asserts the stdlib inventory in both directions, so a new stdlib
export cannot be silently dropped. **`Ast.server_form` has no equivalent.** It is a 16-field
record, and the Go emitter reads 10 of them. Adding a field is invisible to every test.

That is the structural cause of Finding 1. **Now closed** (§7, OQ1): the emitter rebuilds
`server_form` and `EServe` from their own fields, so a new field fails to compile until it is
accounted for, and a test does the same for the `App` schema. Both were verified to trip.

---

## 4. Findings fixed in this pass

### F1 — Six `server` clauses were silently dropped (severity: **high**)

`Ast.server_form` carries 16 fields. `emit_racket.ml` honours all of them. `emit_go.ml` read 10.
The six it ignored — not refused, *ignored*:

| Clause | Racket behaviour | Go behaviour before this pass | Consequence |
|---|---|---|---|
| `sessionRevoked <fn>` | installs a renewal-time revocation hook (fail-closed) | nothing | **a revoked session kept renewing** |
| `sessionPreviousKey "VAR"` | rotation overlap; verify accepts either key | nothing | key rotation logs every user out |
| `listenAddress Loopback` | binds `127.0.0.1` only | bound every interface | **a proxy-only service was publicly reachable** |
| `trustedProxies [...]` | scopes which XFF `request.clientAddress` may believe | nothing | clause promises an edge model that does not exist |
| `healthProbePath "/healthz"` | the one path exempt from Host validation | nothing | a load balancer's probe got 421 |
| `contentSecurityPolicy "…"` | default CSP on runtime-served HTML | nothing | no CSP on the static/SPA surface |

Three of these are used by corpus programs *today* — `example/sso-demo.tesl`,
`example/learn/lesson78-sso.tesl`, `lesson79-authenticating-proxy.tesl`, `lesson80-testing-sso.tesl`,
`tests/proxy-binding-http-tests.tesl` — and those programs **passed** on the Go backend while
behaving differently from the same source on Racket. The corpus was green over a real divergence.

**Fixed:** all five implementable clauses are now wired
(`emit_go.ml`, the server boot-`init` block), with the runtime halves added:

- `teslrt.SetSessionRevokedHook` — consulted only on renewal, after the lifetime checks, before
  minting; a panicking hook *denies* (`runtime/go/teslrt/jwt.go`), matching `tesl/jwt.rkt`'s
  "any error from the hook denies the renewal".
- `teslrt.SetPreviousSessionKey` existed already and was simply never called — a one-line miss.
- `ServeOptions.ListenAddress` → the bind address.
- `teslrt.SetHealthProbePath` — exempts that path from the Host check only; the cross-site guard
  still applies.
- `teslrt.SetContentSecurityPolicy` — clause > `TESL_CSP` > `frame-ancestors 'none'`, the same
  precedence `dsl/web.rkt` uses.

`trustedProxies` is now **refused** with a message that says why: the Go backend has no
`request.clientAddress`, so the clause would configure a reader that does not exist. Refusing beats
accepting a security declaration that does nothing.

### F2 — No security-header floor on Go responses (severity: **high**)

`dsl/web.rkt` wraps every response in `harden-servlet` → `add-security-headers`:
`X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`,
HSTS when the *configured* public origin is https and not loopback, a CSP on HTML, and
`Cache-Control: no-store` on the JSON API. The comment records that this exists precisely because
two direct-response paths had been found carrying none.

Go's `writeResponse` set exactly one header: `Content-Type: application/json`. The static-file and
SPA-fallback paths set none.

**Fixed:** `runtime/go/teslrt/serve.go` now wraps the whole surface — API, static file and SPA
fallback — in a `hardenedWriter` that applies the floor at `WriteHeader` time, which is the first
point where the `Content-Type` is known, so the CSP lands on HTML and `no-store` on JSON exactly as
Racket splits them. A header the producer already set wins. `Flush` passes through, so SSE still
streams.

HSTS is derived from `PublicOrigin()` only — never from a request Host — which is the same rule
Racket states (Risk 44).

### F3 — Unbounded request-body read (severity: **medium-high**, DoS)

The emitted handler did `io.ReadAll(teslRequest.Body)` with no limit. Racket caps the body at
`TESL_MAX_BODY_BYTES` (default 1 MiB) and answers **413** before parsing, because the body is read
whole into memory and parsed.

**Fixed:** emitted handlers now call `teslrt.ReadRequestBody`, which reads
`LimitReader(body, cap+1)`, answers `(bytes, 0, "")` when usable, `(nil, 413, "Request body too
large")` over the cap, and `(nil, 400, "Missing JSON payload")` on a read failure — the same
variable, the same default, the same status as Racket.

### F4 — `sessionPolicy ShortSession` only shortened the cookie (severity: **medium**)

Go's `SessionPolicyTTL` returned 900s, but only `ssoCookieLine` read it. `JwtSign` and `JwtRenew`
used the fixed `jwtTTLSeconds = 3600` and `jwtAbsoluteMaxSeconds = 12h`. So a `ShortSession`
server on Go minted **1-hour tokens against a 12-hour cap** while the same source on Racket minted
15-minute tokens against an 8-hour cap. The cookie expired early; the token did not.

**Fixed:** both numbers are policy-driven, with `ShortSession` = 900s / 8h — the same pair
`tesl/jwt.rkt` names, and named rather than derived for the reason that file gives (applying a 12×
multiplier to a 15-minute TTL yields a cap nobody chose).

### F5 — Racket could not be read by Go: ADT columns (severity: **high** for migration)

An ADT column is JSONB holding `{"tag": …, "fields": {…}}`. Measured, on one live table:

```
-- written by the Racket backend
t-1 | "{\"tag\":\"Low\"}"                     jsonb_typeof = string
-- written by the Go backend
t-1 | {"tag": "Low"}                          jsonb_typeof = object
```

`dsl/sql.rkt` binds the serialised value as a *string* parameter, so PostgreSQL stores a jsonb
**string** whose contents are the document. Racket's reader accepts either shape. Go's reader
accepted only its own and panicked on the incumbent one:

```
panic: database: a Priority column holds codec: expected a JSON object
```

**A service being ported could not read the rows it already had.** That is the migration's whole
premise.

**Fixed:** `teslrt.ParseColumnJSON` unwraps exactly one layer of JSON-string wrapping. All four
directions now work; verified by running the Racket writer then the Go reader, and the reverse,
against the probe cluster.

### F6 — Racket decoded ADT payload fields fail-open (severity: **high**, incumbent backend)

Found while validating F5, and *not* a Go bug. `Ast`-side, `adt-field-spec-template` holds the
field **form** the declaration was written with — `(label : type)` — not a type. Three sites read it
as a type:

- `jsexpr->typed-value` (`dsl/types.rkt`) — so every payload field decoded **untouched**. A
  `Maybe` field inside a stored or posted variant came back as the raw wire hash
  `#hash((tag . Nothing))` instead of `Nothing`, and a `case … of Nothing / Something` then matched
  no arm.
- `runtime-type-satisfied?` — vacuously true for a datum it does not recognise, so nothing said so.
- `dsl/web.rkt`'s ADT return validator — **this one is correct**: its
  `return-spec-expected-shape` strips the binder itself and handles the `:::` proof form, so
  passing the whole field form is what it wants. Left alone.

Reproduced standalone, outside SQL entirely:

```racket
(define-adt Priority [Low] [Numbered [level : Integer]] [Named [label : String] [note : (Maybe String)]])
(jsexpr->typed-value 'Priority (runtime-value->jsexpr (Named "urgent" Nothing)) 'probe)
;; before: note = #hash((tag . Nothing))
;; after:  note = Nothing
```

This affects **any** JSON decode of an ADT with a typed payload field — request bodies and queue
payloads, not only database columns.

**Fixed:** `adt-field-spec-type` extracts the type from the form (before parameter substitution,
so a type parameter sharing a field's label cannot rewrite the label position) and both broken
sites use it. A field written with no type at all is a bare label and answers `#f`, which keeps
today's pass-through for that one shape.

### F7 — A literal pattern against an ADT compiled and died at run time (severity: **medium**)

```tesl
fn label(p: Priority) -> String =
  case p of
    3 -> "three"          # accepted by the checker
    Low -> "low"
    Numbered other -> "other"
```

The checker accepted it. Racket emitted `(= p 3)` and died at run time:
`=: contract violation, expected: number?, given: (adt-value-data 'Priority …)`. The Go backend
refused it at compile time with a message claiming a missing feature.

Neither backend can run this program, so it is a **checker** hole.

**Fixed:** `bind_pattern_vars` (`compiler/lib/checker.ml`) now unifies a literal pattern's type
with the scrutinee's and reports a type error naming both. A literal inside a *constructor* pattern
(`Numbered 3 -> …`) was always legal and still is — verified on both backends. Corpus sweep of
every `example/` and `tests/` file: zero new errors.

### F8 — `date_trunc` unit reached SQL as text with no closed-set check (severity: **low**, latent)

`PgGroupPlan.statement` interpolates `plan.Unit` into `date_trunc('%s', …)` — the one part of that
statement that cannot be a parameter. Nothing user-supplied reaches it today (`Time.truncHour` and
its four siblings are the only sources), so this is latent, not live.

**Fixed:** the unit is checked against `{hour, day, week, month, year}` and panics otherwise, so a
future surface that lets a unit come from a value cannot inject.

### F9 — Refusal messages: 94 misleading claims → 0

The user's question — *"is `Go backend does not support tuple types yet` correct? We do support
tuples"* — was the right question and the answer was no.

`Tuple2`/`Tuple3` are ordinary ADTs and the Go backend emits them (the live PostgreSQL test uses
`Tuple2`). `Ast.TTuple` is the **comma type form** `(Int, String)`: it parses as a type, *no
expression inhabits it* (`(a, b)` as a value is a parse error), no corpus file uses it, and Racket
lowers it to `(list Integer String)` — a shape no runtime type rule recognises, so the annotation
validates nothing. The message now says exactly that and points at `Tuple2`.

Second example, also from the user: `"Go backend does not support equality on this type yet"` sat
under a comment claiming generic ADTs have no comparable form — a comment made stale by a later
fix. `supports_equality` refuses only function values, streams, raw JSON, proof-carrying wrappers,
opaque runtime records, and **type parameters**. The refusal now carries the *cause*:

- a type parameter is a real gap (Racket compares two `a` values structurally — see OQ2);
- a function value, a stream or a proof is not something either backend compares, and calling
  those "not yet" invites a fix that should not exist.

Across the file, every remaining refusal now falls in one of three honest categories:

1. **Unreachable invariant** — 14 arms now say `internal error:` and name the rule that makes them
   unreachable (`Sql_query.is_sql_comparison`, `Validation_advanced.check_group_by_rules`,
   `bind_pattern_vars`, the import gate). Kept fail-closed rather than asserted, so a future
   grammar change gets a refusal instead of silence.
2. **Real gap, stated plainly** — load-test baselines and regression assertions (the Go harness has
   no recorded-run store), debugger instrumentation, unwired stdlib exports (each pointing at
   `test_go_stdlib_export_seam.ml`, which holds the inventory).
3. **Permanent by design** — proof erasure makes `expectFail` on a proof operation impossible; the
   comma type form; equality on functions/streams/proofs.

Two forms turned out to be **dead code the parser never produces**, and are now labelled as such
rather than as features: `Ast.TypeAlias` (`type X = String` parses as a *newtype*) and
`Ast.field_def.checker` (`via` is parsed on a codec's `DecodeField` and on api `auth`/`capture`
clauses — never on a record, entity or constructor field; no site anywhere constructs
`checker = Some`). See OQ5.

Also fixed while in the file: the renew rejection message diverged from Racket
("Session cannot be renewed" vs "Session cannot be renewed: no usable issued-at claim").

---

## 5. Emitted-code quality

### Readability: good

```go
//line GoPgColumns.tesl:19
type PriorityTag int

const (
	PriorityLow PriorityTag = iota
	PriorityNumbered
	PriorityNamed
)

type Priority struct {
	Tag           PriorityTag
	NumberedLevel teslrt.Int
	NamedLabel    string
	NamedNote     teslrt.Maybe[string]
}
```

A Go reviewer who has never seen Tesl can read this. `//line` directives map every declaration
back to the `.tesl` source, so a panic points at Tesl, not at generated Go. Keyed struct literals
are aligned to the longest key because that is what `gofmt` would do — the emitter matches the
formatter rather than fighting it, which is why `gofmt -l` is clean by construction rather than by
a post-pass.

**One nit:** generated equality for a multi-variant ADT with a `Maybe` payload produces a 364-column
line, and `gofmt` does not split expressions. Longest line measured in a sample: 484 columns. It is
correct and `gofmt`-stable; it is not pleasant to read in a diff. See OQ4.

### Performance: two real notes

**P1 — flat ADT layout.** Every `Priority` value is as large as the sum of *all* variants'
payloads, not the largest. A 12-variant ADT with a string in each is ~192 bytes per value where a
tagged union would be ~24. The alternative in Go is an interface or a pointer per variant, which
allocates on every construction — for the common case (2–4 small variants) the flat struct is
faster and allocation-free. **This is the right default**, but it degrades badly at the tail and
nothing warns. See OQ3.

**P2 — `ListUniqueBy` is O(n²) while its own comment claims otherwise.**

```go
// ListUniqueBy keeps the FIRST occurrence and preserves order, matching Racket's
// hash-based `List.unique`.
func ListUniqueBy[T any](xs []T, equal func(T, T) bool) []T {
	out := make([]T, 0, len(xs))
	for _, value := range xs {
		if !ListMemberBy(value, out, equal) {   // linear scan per element
			out = append(out, value)
		}
	}
```

Racket's is hash-based and linear. On 10⁴ distinct elements that is ~10⁸ comparisons against ~10⁴.
The comment says "matching Racket's hash-based `List.unique`" and the complexity does not match.
Left for OQ6 rather than fixed, because the fix is an emitter decision (which element types can
produce a comparable key), not a local edit — and getting it wrong would silently change `unique`'s
semantics for float/`Int`/newtype elements.

### Security: the primitives are right

- Constant-time comparison wherever it matters: `subtle.ConstantTimeCompare` for secrets and
  password keys, `hmac.Equal` for every MAC. `secret.go` explains *why* per site.
- `Secret` prints as `[redacted]` via `String()`; a `secret` column binds its plaintext (storage is
  not rendering) and reads back into the redacting carrier — the same rule `dsl/sql.rkt` states.
- Static serving resolves the path and then checks containment, so an encoded traversal cannot
  slip past.
- Outbound HTTP has connect and read deadlines with env overrides, a verified TLS chain, and a
  loopback-only development exception.
- Server timeouts are set rather than left at Go's "none", with `ReadHeaderTimeout` named as the
  Slowloris stop. Graceful drain on SIGTERM.
- SSE unregisters its listener and stops its heartbeat with `defer`.
- Header values: Go's `net/http` rejects CRLF in header values at write time, so cookie-value
  injection is closed by the stdlib rather than by our own check. Worth knowing, not worth
  duplicating.

**Residual, now closed:** F1, F2, F3, F4, F8 above.

---

## 6. Test strategy assessment

### Strong

- 85 differential-oracle cases. This is the mechanism that makes the rest credible.
- Gates on the emitted tree, status-enforced, with a *missing* linter treated as failure.
- The export seam test walks `Type_system.tesl_module_exports` and asserts the unsupported list
  both ways — a new stdlib export cannot be silently dropped in either direction.
- `Int` gets three fuzz targets in CI (decimal/JSON round trip, arithmetic against `big.Int`,
  JSON input), plus `go test -race` on the hand-written runtime.
- Corpus reach: **179 of 181** files emit and pass. The two exceptions
  (`tests/critical-review-54-tests.tesl`, `tests/critical-review59-tests.tesl`) assert that a
  *proof* operation fails at run time, which is impossible where proofs erase — refused by design,
  with the reason in the message.

### Weak

**T1 — the corpus was green over F1.** Three corpus programs declare `sessionRevoked` and
`listenAddress`; none asserts either. Green corpus is not evidence of clause parity. This is the
same lesson as `go-tests-need-emitted-isolation`: the oracle catches behaviour a test *exercises*,
and nothing else.

**T2 — 14 runtime files had no direct unit test** (12 now: `hostname.go` and `serve.go` gained
one in this pass — see OQ8 and F1/F2). By exported-symbol reference from any `*_test.go`, as
measured before the fixes:

| File | Lines | Exported funcs referenced by a test |
|---|---|---|
| `hostname.go` | 568 | 0 / 11 → **11 differential tests added (OQ8)** |
| `sso_flow.go` | 541 | 1 / 3 |
| `url.go` | 321 | 0 / 11 |
| `loadtest.go` | 227 | 0 / 5 |
| `sso_route.go` | 223 | 0 / 3 |
| `jws.go` | 184 | 0 / 0 |
| `serve.go` | 281 | 0 / 4 → **8 tests added** (header floor, HSTS, probe path, bind address, body cap) |
| `apitest.go` | 119 | 0 / 4 |
| `agent_endpoint.go` | 117 | 0 / 5 |
| `dbquery.go` | 337 | 10 / 16 |

Most are reached *indirectly* by emitted programs in `test_emit_go.ml` (`Url.`/`Net.` appear 53
times there, `sso` 74). `hostname.go` — 568 lines of hand-rolled IPv4/IPv6/host classification
behind the SSRF guard — is the one I would not accept on indirect coverage alone: it is exactly the
kind of parser where a differential against `net.ParseIP` would find something.

**T3 — no `-race` on the emitted tree.** *Closed (OQ10):* `gate_emitted` now adds `-race` for
every emitted tree that starts goroutines, detected from the emitted source rather than declared
per case. Swept across the corpus: zero races.

**T4 — `dbquery.go`'s `PgGroupPlan.statement` has no direct test.** It renders SQL by string
assembly with two zone branches and integer floor arithmetic for three units. It is covered
end-to-end by the live PostgreSQL test, which requires a cluster and is skipped without one.

### Added in this pass

- `test_pg_columns_*` — a payload-carrying ADT column, a `secret` column, and `isNull` on a
  nullable column, run against a live cluster on both backends. This is the case that found F5 and
  F6; the nested `Maybe` inside `Named` is deliberate.
- The shared live program gained a payload-carrying ADT column (`Binding`), so the ordinary
  PostgreSQL path exercises the JSONB column codec on every run.

---

## 7. Open questions — ANSWERED and IMPLEMENTED

All ten were decided by the maintainer on 2026-08-18 and all ten are now built. What shipped:

**OQ1 — completeness seam. → (a), extended to App/ServeOptions.**
`emit_go.ml` now rebuilds `Ast.server_form` from its own field names, so adding a field fails to
COMPILE until someone records what the Go backend does with it (`Some record fields are undefined:
…`). `EServe` gets the same treatment for the `App`→`ServeOptions` path. The App schema is data
rather than an OCaml record, so its seam is a test (`test_go_stdlib_export_seam.ml`) asserting every
field is either read by `Desugar.lower_main_app` or listed as deliberately inert. **Both seams were
verified to trip** by adding a probe field and watching the build and the test fail.

**OQ2 — polymorphic equality. → (a) dictionary passing.**
A generic whose body compares two `A` values now takes `teslEqualA func(A, A) bool`; each call site
passes the concrete type's own comparator. A generic that only *passes* its `a` to such a function
forwards the dictionary it was given (the requirement is computed to a fixpoint over the call
graph, before emission, so a call site emitted ahead of its callee still knows the arity). A type
parameter that is never compared gets no dictionary. `secret` keeps its constant-time comparison,
because the comparator for a secret *is* that comparison — verified in the emitted output.
Residual: `same 1` used as a VALUE (partial application) is still refused; the combinators have no
place for an argument the caller rather than the caller's caller supplies. It fails closed.

**OQ3 — ADT layout. → automatic, no lint.**
Above an estimated 128 bytes with ≥2 payload variants, the emitter switches from the flat struct to
one payload struct per variant behind a pointer: the value becomes a tag plus a pointer whatever
the payloads do. `example/chat/chat-backend.tesl` is the corpus's own case (three variants, nine
strings, ~170 bytes → 32) and is now emitted boxed; its tests and its Racket oracle both pass.
A dedicated test exercises construction, a five-field `case`, a nested `Maybe` payload, equality
across variants, and a database column through the JSONB codec, on both backends and against a live
cluster.

**OQ4 — long generated expressions. → yes, for equality.**
A variant's payload comparison is now its own function, one field per statement, and a field whose
own comparison is a conjunction goes through the hoisted comparator for its type. The 364-column
equality line is gone; the remaining long lines are config literals and call arguments, which do
not grow with the type.

**OQ5 — dead AST forms. → removed.**
`Ast.field_def.checker` (never set to `Some` anywhere) and `Ast.TypeAlias` (never built by the
parser) are gone, along with 43 pattern sites across 13 files. Corpus `--check` sweep clean, and
`scripts/regen-rkt-snapshots.sh --check` byte-identical — so the frontend surgery changed no emitted
Racket.

**OQ6 — `List.unique`. → keyed fast path.**
`ListUniqueKeyed` (one map pass) is chosen whenever the element type has a comparable key whose
equality is exactly the language's `==`: the value for String/Bool, `Int.Key()` for an unbounded
integer, and `teslrt.FloatKey` for a Float — the last because keying a float by its own value would
make -0.0 and +0.0 one key and every NaN its own, which is backwards on both counts. ADTs, records,
containers and `secret`s keep the closure path.

**OQ7 — 415 on a non-JSON body. → added.**
Emitted handlers with a declared payload now answer 415 for a content type that is not JSON and 400
"Missing JSON payload" for an empty body, before parsing — the same statuses, in the same order, as
`dsl/web.rkt`'s `parse-json-body`. Zero corpus api-tests changed behaviour.

**OQ8 — `hostname.go`. → differential test.**
11 tests against `net/netip` over a generated corpus. They pin the SHAPE of the disagreement rather
than demanding agreement, because disagreeing is the module's purpose: `netip` refuses `2130706433`
and `0x7f.0.0.1`, which a resolver accepts as 127.0.0.1.

**OQ9 — load-tests. → they work; baselines match Racket.**
*A correction to §4 of the original review*: I wrote that a baseline "needs the store the Racket
harness keeps". It keeps none. `dsl/load-test.rkt` prints "in-process baselines; store/compare
deferred" and moves on. Go now says the same thing in the same place, so a `baseline` clause and a
regression assertion compile and run on both backends with byte-identical output. Real baselines
are a language feature owed to both backends, not a migration item.

**OQ10 — `-race`. → on the trees that start goroutines.**
`gate_emitted` detects `StartWorkers` / `Serve` / `Publish` in the emitted source and adds `-race`
for those cases only. Swept across every goroutine-bearing corpus program: zero races.

---

## 7b. Findings from implementing the answers

**F10 — a corpus program did not build (severity: high, regression).**
`example/learn/lesson21-sql-reference.tesl` failed with `undefined: PgGroupZone`. The runtime's
gated file sets are EXCLUSION filters, so a type shared by two differently-gated files belongs in
neither: `PgGroupZone` was declared in `dbquery.go` (Postgres-only) and used by `timetrunc.go`
(timezone-only), so a Memory-backed program that truncates by hour got the user without the
declaration. Moved to `time.go`, which is never gated. **The same class had bitten the session
twice before** (jwt/sso_route in this pass), which makes the gated file sets a place worth a
mechanical check of their own — see the new open question below.

**F11 — no api-test on either backend could catch a content-type regression.**
Go's `ApiRequest` sent no `Content-Type` at all; Racket's `dispatch-api-test-request` hands the
dispatcher an already-parsed body, so its api-tests never reach the check. Go's harness now defaults
to `application/json` when a body is present and the test did not choose otherwise — so a test CAN
now assert the 415, which is what the new case does. Racket's harness still cannot; that asymmetry
is recorded rather than papered over.

**F12 — three deliberate divergences from `netip`, now pinned.**
CGNAT (100.64/10, netip has no predicate), the whole of 0.0.0.0/8 (netip's `IsUnspecified` is only
0.0.0.0 exactly), and `>= 224` covering multicast AND the reserved space above it under one label.
Each matches `dsl/private/host-classify.rkt` rule for rule, and each is now a test that says so, so
"make it agree with netip" cannot be mistaken for a fix. One shared laxity is pinned too: both
backends accept a leading `-` in a hostname label.

---

## 7c. Open questions remaining

**OQ11 — should the gated runtime file sets be checked mechanically?**
F10, and the two like it earlier in this session, are all the same shape: a declaration in a file
gated on condition A, used by a file gated on condition B. Nothing catches it until a program with
B-and-not-A appears in the corpus. A cheap check exists: for each gate, emit a probe program that
pulls exactly that set and build it. That is ~8 builds and would have caught all three. **My
recommendation: add it.**

**OQ12 — partial application of a comparing generic.**
`same 1` as a value is refused (fail-closed). Closing it means the partial-application combinators
carrying dictionaries, which changes their arity contract. It has no corpus use. **My
recommendation: leave it refused until something needs it.**

## 8. What I would not change

- The refusal-heavy design. 589 refusal sites is the reason this backend is trustworthy.
- The flat ADT struct for the common case.
- `noCompare` on `Int`.
- JWT with no header parse.
- The decision to make a lint finding on emitted code an emitter bug rather than a suppression.
- The two `critical-review` refusals: a test that asserts a proof operation fails at run time is
  asserting a property of the Racket runtime, not of Tesl.
