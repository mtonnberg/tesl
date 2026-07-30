# Secret-wrapped credentials — does validation compose with `secret X = T`?

> **Status:** Done · 2026-07-30. `secret Password = String` (redaction) was already
> shipped (Phase 4 of `tesl_crypto_phases_1_to_4.md`). The open question was whether
> a proof (`::: P`) composes with `secret`. The DECLARATION form
> (`secret Password = String ::: P`) does not, by grammar, and does not need to.
> The FIELD form (`password: Password ::: P`) does — but composing it surfaced a
> real compiler bug (a `secret`'s plaintext reaching an arbitrary `via` check
> function unwrapped), fixed below. Wiring a `secret` through `Crypto.hashPassword`
> in a realistic multi-statement lesson (not a one-line probe) surfaced a SECOND,
> unrelated bug in the same subsuming-rule machinery — a `let`-bound secret-accepting
> call failed to type-check at all — also fixed below.

## The repro that settled the declaration question

`secret Password = String ::: LongEnough` is a parse error:

```
error[E000]: unexpected token at top level: ::: (pos 63)
```

`TypeNewtype`'s `base_type` is a plain `type_expr` (`checker.ml:665`), and a proof
annotation only ever attaches to a param binding or return spec (`ast.ml`
`param_binding.proof_ann`) — never to an arbitrary type expression. Confirmed,
not inferred from reading the grammar. This is fine: a `secret` newtype never
needed to carry the proof itself, because a record FIELD already can.

## First pass: sequence the two protections (still valid, still shipped)

Decode into a plain, proof-annotated `String` field; the handler then
constructs the `secret` newtype from the already-validated value:

```
record RegisterBody { password: String ::: LongEnough password }
codec RegisterBody {
  fromJson [ { password <- "password" with_codec stringCodec via isLongEnough } ]
}
handler register(body: RegisterBody) -> RegisterOut =
  let secretPassword = Password body.password   # redacted from here on
  ...
```

`tests/secret-proof-composition-tests.tesl` is the runnable proof of this
shape. It works, and needed zero compiler changes.

## Second pass: the field can BE the secret type directly — but this exposed a real bug

The more direct shape — the field IS the secret newtype, proof and all —
looked like it should also just work, since record fields already carry proof
annotations (`tests/server-tools-tests.tesl`'s `TextSafe` field) and the
inbound path already mints a secret straight from a bare JSON string
(`tests/secret-inbound-tests.tesl`):

```
record RegisterBody { password: Password ::: LongEnough password }
codec RegisterBody {
  fromJson [ { password <- "password" with_codec stringCodec via isLongEnough } ]
}
handler register(body: RegisterBody) -> RegisterOut =
  body.password   # no manual wrap — already Password
```

It compiled and passed a basic accept/reject test. It was NOT sound. Emission
wrapped the decoded value into the `secret` newtype constructor **before**
`via isLongEnough` ran, so `isLongEnough` — declared `(text: String)` — was
actually invoked with the wrapped secret struct at runtime. It worked only
because the stdlib's string helpers (`raw-str` in `tesl/string.rkt`) unwrap
ANY `newtype-value?`, secret or not, with no regard to secrecy. Concretely:
change the check function's `fail` message to interpolate its own argument —
a completely ordinary validation-message mistake — and the plaintext rode the
wrapped struct straight out through `String.length`'s unwrap and into the
400 response body:

```
actual (the 400 response's "error" field):
  "Password too short, you sent: #(struct:newtype-value #s(type-ref ...
   Password) short)"
```

`compiler/lib/validation_sql_codec.ml`'s `check_codec_proof_coverage` only
checks that a `via` function is declared and covers the required proof
predicate NAME — never that its parameter type matches what will actually be
passed once the field's type is a newtype. Nothing in the existing shipped
corpus hit this: every `via`-checked field in the codebase decodes into a
plain `String`/`Int`, never directly into a newtype (confirmed by grep before
changing anything), so this was a real, previously-untested composition, not
a regression.

## The fix

`compiler/lib/emit_racket.ml`: a `via`-checked field used to decode straight
into its newtype-wrapped form (`decode_call`) and hand THAT to the `via`
function. Now (`decode_call_pre_via` + `emit_via_checked_field`) the raw base
value decodes first, `via` runs on that — matching what the check function's
own signature, and the checker's proof-coverage validation, already promised
— and the newtype constructor wraps only the value a successful check
returned (`(ensure-named ... (Ctor (check-ok-value _r)) ...)` instead of
wrapping pre-check). This is strictly a superset fix: it applies to any
`via`-checked newtype-typed field, not just secret ones, closing the same
looseness for plain newtypes too (previously masked there only because
non-secret values have no confidentiality expectation to violate).

Zero emitted-byte drift for existing code: every shipped `via` field decodes
into a plain base type today, so `decode_call_pre_via` returns the identical
string `decode_call` did for all of them (verified: `dune test`, 145/145,
including the exact-match `.rkt` snapshot ratchets, unchanged before/after).

Ratcheted at `compiler/test/test_secret_surface.ml` ("a via-checked field
typed as the secret itself"): asserts the emitted decode does NOT contain
`(Ctor (tesl-decode-prim-field ...))` (wrap-before-check) and DOES contain
`(Ctor (check-ok-value ...))` (wrap-after-check). Verified this test fails
against the pre-fix emitter (stashed the fix, reran, confirmed the failure,
restored it) before trusting it as a real regression guard.

## The second bug: a `let`-bound secret-accepting call didn't type-check at all

Wiring `secret Password = String` through lesson64's actual functions (not a
one-line probe) — `registerAccount`, `changePassword`, `logIn` all taking
`Password` instead of `String`, feeding `Crypto.hashPassword` /
`Crypto.checkPassword` — surfaced a second, unrelated bug:

```
fn registerAccount(id: String, email: String, password: Password) requires [accountWrite] -> Bool =
  let hash = Crypto.hashPassword password   # <- error[T001]: cannot unify String with Password
  ...
```

but the same call as the function's bare tail expression compiled fine. Two
near-duplicate implementations of "apply a function to an argument, widening
a secret-accepting parameter" exist in `checker.ml`: one in `check_expr` (used
for a fn's tail expression, checked top-down against the fn's declared return
type) and one in `infer_expr` (used for a `let`-bound RHS with no declared
type, inferred bottom-up) — `secret_relaxed_param`, the shared widening
decision, was called correctly by both, but `infer_expr`'s copy then did
something `check_expr`'s never did: it unified the CALLEE'S OWN function type
against `TFun (widened_param, ...)`. When the widened param is `Password` and
the callee's real, concrete signature says `String` (`Crypto.hashPassword :
String -> PasswordHash`), that unification itself fails — the callee's type
was never supposed to change, only the judgment of whether THIS argument
satisfies it.

Fixed in `compiler/lib/checker.ml`'s `EApp` arm of `infer_expr`: when the
callee's type is already a concrete `TFun (p, r)`, use `r` directly as the
next return type and unify only the ARGUMENT against the (possibly widened)
target — never re-unify the callee's own parameter slot. The pin-via-unify
trick (introducing a fresh var and unifying the callee type against it) is
now only used when the callee's type isn't resolved yet, exactly where it's
actually needed. Ratcheted in `test_secret_surface.ml` ("the same shape still
compiles when let-bound, not tail"); verified it fails against the pre-fix
checker the same way as the emit ratchet (stash, rerun, confirm, restore).
Full corpus: 152 test binaries, zero failures, exact-match snapshots
unchanged for everything except the two lesson64 files edited below.

## What shipped

- `compiler/lib/emit_racket.ml` — the via-checked-field ordering fix
  (`decode_call_pre_via`, `emit_via_checked_field`), applied to both the
  single-`via` and the `&&`-combined multi-`via` decode arms.
- `compiler/lib/checker.ml` — the `let`-bound secret-accepting-call fix in
  `infer_expr`'s `EApp` arm (above).
- `compiler/test/test_secret_surface.ml` — both ratchets: "a via-checked field
  typed as the secret itself" and "the same shape still compiles when
  let-bound, not tail".
- `tests/secret-field-proof-tests.tesl` (+ committed `.rkt`) — the end-to-end
  runtime proof of the direct field shape: too-short 400s, long-enough 200s,
  `body.password` is already `Password` with no manual wrap.
- `tests/secret-proof-composition-tests.tesl` (+ committed `.rkt`) — the
  sibling proof, also using the direct field shape now.
- `example/learn/lesson64-password-storage.tesl` — the lesson's OWN functions
  (`registerAccount`, `storeNewPassword`, `changePassword`, `logIn`) now take
  `Password` instead of plain `String`, so `Crypto.hashPassword` /
  `Crypto.checkPassword` demonstrate accepting a user-declared secret directly
  in the actual lesson code, not only in a comment. Its committed `.rkt`
  snapshot was regenerated twice (`scripts/regen-rkt-snapshots.sh
  example/learn`) — once for a comment-only edit (shifts every subsequent
  line number; `register-sql-read-lines!` bakes them into the emit) and once
  for the `Password` type change itself.

## The residual leak question, checked

"Does telemetry/tracing ever capture a raw request body before JSON decode?"
No: `dsl/web.rkt`'s server span only ever gets `http.request.method`,
`url.path`, `tesl.request.id`, `tesl.operation`, and
`http.response.status_code` (`web.rkt:1960-2034`) — never the body. The
`[TESL][HTTP]` request/response log line matches (method + path + status +
timing only). A malformed-JSON decode failure's `exn-message` comes from
Racket's `json` library, which reports a position/type mismatch, not the raw
payload (verified directly). What a `via` check function's OWN `fail` message
says is still the author's responsibility — the fix here is that the
compiler no longer hands that function a value it wasn't typed to receive;
echoing input in a validation error is an ordinary hygiene concern like any
other field, not a `secret`-specific containment failure anymore.

## Related

- `roadmap/completed/tesl_crypto_phases_1_to_4.md` (Phase 4 — the shipped
  inbound `secret` half), `roadmap/completed/tesl_crypto.md`.
- `tests/secret-inbound-tests.tesl` — the sibling proof that a bare `secret`
  decodes from JSON with no validation at all.
- `tests/secret-runtime-tests.rkt` — the generic redaction proof both shapes
  above rely on rather than re-proving (redaction is per-VALUE, not
  per-construction-site, so it covers a secret built either way).
