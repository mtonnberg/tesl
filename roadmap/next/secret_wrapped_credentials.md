# Secret-wrapped credentials — does validation compose with `secret X = T` yet?

> **Status:** Next · **Effort:** S. The model decision this item used to gate on is already
> settled in shipped code (2026-07-30 review below). What's left is verifying and, if needed,
> closing one composition gap — not designing a generic type.

## Where this stands today

`secret Password = String` (Phase 4 of `roadmap/completed/tesl_crypto_phases_1_to_4.md`) is
**shipped**, not proposed:

- Parser: contextual `secret UIDENT = T` declaration header (`parser.ml:5081`).
- Checker: registers the newtype ctor + records the name in `secret_types`
  (`checker.ml:665`, `DType (TypeNewtype { secret; ... })`).
- Emit: `define-secret-newtype`, which wires the redaction registry entry (`emit_racket.ml:5779`,
  `crypto.rkt:185`).
- Inbound decode: a JSON body field typed `Password` mints the newtype straight from a bare JSON
  string, and `==` on two secrets lowers to a constant-time compare
  (`tests/secret-inbound-tests.tesl`, exercises exactly `record LoginBody { email: String,
  password: Password }`).
- Sinks: `Crypto.hashPassword` index 0 and `Crypto.checkPassword` index 1 are secret-accepting
  params (`type_system.ml:1104`), so a user's own `secret Password = String` passes into them
  today — no core change needed.

So the original framing — "should `Secret` be generic so a plaintext credential can be redacted
and validated at once" — is answered for the redaction half: declare a domain-specific secret
newtype per credential (`Password`, `ApiKeyInput`, whatever), same as the shipped example. That
keeps `Secret` itself meaning "key material the server holds," which is the correct call: a
password is a transient, hash-and-discard value with a different lifecycle than a signing key, and
collapsing the two types would blur that distinction for no benefit (see "Why not generic
`Secret a`" below, mostly still true and worth keeping as the closed decision).

## The one gap that's real: proof composition

A secret newtype's base is a plain `type_expr` — `DType (TypeNewtype { base_type; ... })` in
`checker.ml:665` calls `ty_of_type_expr base_type` directly. Proof annotations (`::: P`) attach
only to param bindings and return specs (`ast.ml` `param_binding.proof_ann`, `ret_spec`), not to an
arbitrary `type_expr`. So `secret Password = String ::: LengthLongerThan 8` is very likely not
expressible as a newtype declaration — unverified, but the grammar doesn't show a path.

That means today a codec can produce `String ::: LengthLongerThan 8` (validated, inspectable) OR a
decoder can mint `Password` (redacted, un-inspectable) — but not the composition of both in one
declared field type. An author gets to pick exactly one protection.

**Action before anything else:** write a two-line repro — a `with_codec ... via` producing a
proof, feeding a `record` field declared as a secret newtype — and confirm it either compiles (gap
closed, doc done) or fails with a specific error (gap real, scope below).

## If the gap is real — options, smallest first

- **A — teach the pattern without new syntax.** Validate at the boundary with a codec into a
  refined `String`, THEN construct the secret newtype from the validated value inside the handler
  (`Password (validated)`), rather than trying to decode straight into a secret. Costs nothing in
  the compiler; costs a slightly less direct handler body. Write this into lesson64 as the
  supported shape and see if it's actually a problem in practice before building anything.
- **B — let a secret newtype's base_type carry a `::: Proof`.** Extend `TypeNewtype`'s grammar to
  accept a proof annotation on `base_type` when `secret` is set, thread it through
  `ty_of_type_expr`, and have the inbound codec path discharge it during the mint. Bounded: one
  declaration form, one checker rule, one codec integration point — not a new kind, not a generic
  parameter, no stdlib signature rewrite.
- **Reject — generic `Secret a`.** A proof inside an un-inspectable box is nearly inert: proofs are
  consumed by functions that take the *value*, and if `Secret` hides the value the only thing you
  can pass a `Secret (T ::: P)` to is a privileged sink. So the parameter buys boundary validation
  (codec → 400 on a bad shape) and nothing downstream — validation reachable without `Secret` at
  all. Combined with the fact that per-domain secret newtypes already ship redaction, a generic
  wrapper adds a type parameter, a proof-threading story, and a SEC003 rethink (what does `Secret
  Int` even mean?) to buy nothing A/B don't already cover. Closed unless a concrete second use case
  shows up that neither A nor B can serve.

## Verification bar

- The repro above has a definite answer (compiles / specific error), checked in before any code
  change.
- If B is built: a password value still renders `[redacted]` in telemetry, the debugger, and logs
  — a test, not a claim — AND a too-short password is still rejected at the boundary with the same
  4xx a bare codec gives today.
- Also worth a test regardless of A/B: does telemetry/tracing ever capture a raw request body
  *before* JSON decode? If so, a plaintext password can leak through that path regardless of what
  the decoded field type is — redaction on the decoded value doesn't cover it. Pin "a login
  request's captured trace/log contains no plaintext password," not just "the decoded value
  redacts."
- `Crypto.checkPassword` end to end stays green (lesson64).
- SEC003 still fires on a hardcoded key/password and doesn't regress on whatever shape ships.

## Related

- `roadmap/completed/tesl_crypto_phases_1_to_4.md` (Phase 4 — the inbound `secret` half, already
  shipped), `roadmap/completed/tesl_crypto.md`, `tesl/crypto.rkt` (`define-secret-newtype`).
- `tests/secret-inbound-tests.tesl` — the existing end-to-end proof for the shipped half.
- `type_system.ml` `secret_accepting_params` + `secret_param_expected_base` — the per-argument-slot
  opt-in table; extending it is how a new sink would gain secret-acceptance, not a generic type.
- `roadmap/completed/response_metadata_and_cookies.md` (the key unification precedent for "no
  `String` ever holds key material").
