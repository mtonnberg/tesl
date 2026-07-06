# Email capability is not composable (user report, confirmed 2026-07-06)

> **DONE 2026-07-06.** Both the composability fix and the `email` → `emailCap`
> rename landed. `Tesl.Email` now has a provider row `[("emailCap", [])]` in
> `tesl_stdlib_cap_map`, so `import Tesl.Email exposing [emailCap]` composes like
> `dbRead` — usable in a library `requires [...]` and in `capability … implies
> emailCap`. Rename touched: both `build_cap_map` copies, the effect rows
> (`ESendEmail`/`EStartEmailWorker`), the `Type_system` Tesl.Email allowlist,
> `Ast.builtin_capability_names`, the runtime `tesl/email.rkt`
> (`define-capability emailCap` + provide + `require-capabilities!`), and all
> usages in lesson60/user-service/LANGUAGE-SPEC/tests (+ regenerated `.rkt`
> snapshots + embedded_docs). **Drift class closed by construction:** a new seam
> test asserts `Ast.builtin_capability_names` ≡ the set of caps provided by
> `tesl_stdlib_cap_map` — a builtin capability that forgets its provider row (the
> exact shape of this bug) now fails at build/test time. Tests in
> `compiler/test/test_fail_closed_hardening.ml` ("emailCap composability +
> cap-table drift seam"). No parser change was needed: `emailCap` parses via the
> generic identifier arm, and a stale `requires [email]` now gives a clean
> "undeclared capability 'email'".

## Report

A user reports the `email` capability is "not composable". Reproduced — three
legs, all one root:

1. **No capability hierarchy over email.** `capability notifier implies email`
   in a module without a local `email X = Email {…}` block is rejected:
   `capability 'notifier' implies unknown capability 'email'`. The identical
   pattern over `dbWrite` (`import Tesl.DB exposing [dbWrite]`) works.
2. **No email-requiring helpers in library modules.** `fn helper(...) requires
   [email]` is rejected (`requires undeclared capability 'email'`) unless the
   SAME module declares an email block — so email senders cannot be factored
   into a module the app imports.
3. **The stdlib-import path silently drops the capability.**
   `import Tesl.Email exposing [email]` is ACCEPTED as an import
   (`Type_system` stdlib allowlist for `Tesl.Email` includes `"email"`,
   type_system.ml:846) but `requires [email]` in that module still fails —
   the import succeeds and the capability vanishes.

## Root cause

`"email"` enters the capability map ONLY via a local declaration:
`DEmail _ -> Some ("email", [])` in `build_cap_map`
(proof_checker.ml + the twin copy in validation_capabilities.ml).
`Validation_common.tesl_stdlib_cap_map` (validation_common.ml:1403) — the
declared SINGLE source of truth for stdlib capability providers — has **no
`Tesl.Email` row** (DB/Time/Random/Env/Queue/UUID/JWT/HttpClient/Agent all have
one), and `load_imported_cap_map`'s local-import branch collects only
`DCapability` decls, so an imported module's `email` block does not export the
capability either.

## Is it connected to the fail-open class?

Not a fail-open — the checker over-CLOSES here (deny-by-default doing its job
against an incomplete provider table). But it is the same **generator** as the
fail-open reviews ([[stability-root-diagnosis]]): one fact ("`email` is a
grantable capability provided by Tesl.Email") hand-restated across three lists
that drifted — `Type_system` import allowlist (has it), `builtin_capability_names`
(ast.ml:702, has it), `tesl_stdlib_cap_map` (missing). Same family as
[[env-builtins-import-soundness]] (names importable per one list, unknown to
another). Leg 3 is the dangerous flavour: an accepted import that silently does
nothing.

## Fix — composability

Add the provider row to `Validation_common.tesl_stdlib_cap_map` (single source;
`Proof_checker.stdlib_capabilities` references the same binding, so both checkers pick
it up). Then `import Tesl.Email exposing [emailCap]` composes exactly like `dbRead`:
usable in `requires [...]` and in `capability … implies …` chains. Runtime enforcement
is unchanged (capability grants still flow from `main`/serve scope); this only lets the
NAME be referenced where the import is in scope. Keep the `DEmail`-implies-the-cap
implicit definition for app modules.

Add a seam test asserting every capability name accepted by the `Type_system` stdlib
import allowlist resolves in `tesl_stdlib_cap_map` — that closes the drift *class*, not
just this instance (it would have caught this bug at build time).

## Fix — RENAME `email` capability → `emailCap` (do it in the SAME pass)

**Recommended, decided.** The capability token is renamed `email` → `emailCap`, exactly
mirroring the `cache <Name>` → `cacheCap <Name>` rename already shipped
([[cache_capability_rename]] in roadmap/completed). Rationale:

- `email` is overloaded — it is both the **declaration keyword** (`email X = Email {…}`)
  and the **capability token** (`requires [email]`). `cache` had the identical clash and
  was disambiguated to `cacheCap`; `email` should follow for consistency.
- Doing the rename in the same pass as the composability fix is strictly better than
  shipping a working-but-overloaded `email` capability and renaming it later — the
  rename is a breaking change to the surface, so it should land BEFORE the capability is
  usable in library modules, not after users write `requires [email]`.
- Unlike `cacheCap <Name>`, the email cap is **not** name-specific: it is a single
  `emailCap` token regardless of how many `email` declarations exist (there is one
  `("email", [])` provider entry, not one per email block). So the rename is a plain
  token swap, simpler than the cache one.

Rename touch-points (mirror the cacheCap change): `build_cap_map` twin copies
(`proof_checker.ml` + `validation_capabilities.ml` `DEmail -> ("emailCap", [])`), the
new `tesl_stdlib_cap_map` row (`"Tesl.Email", [("emailCap", [])]`), the
`Type_system` `Tesl.Email` import allowlist (`"email"` → `"emailCap"` for the
capability entry — leave the `Email`/`SmtpConfig`/`Email.send` type/function entries
alone), `validation_common.ml`'s `ESendEmail`/`EStartEmailWorker` → `["emailCap"]`
effect rows, `emit_racket.ml` capability identifier, and all usages in
`example/learn/lesson60-email.tesl`, `example/user-service-api.tesl`, `test_email*.ml`,
and `LANGUAGE-SPEC.md`. Keep the `email` *keyword* (the `email X = Email {…}` decl form)
untouched — only the capability token changes.

## Verification

Red→green: the three probes above (implies-chain, library helper, stdlib-import
path), rewritten against `emailCap`, plus `./ci.sh` 13/13. Antagonistic control:
`requires [emailCap]` with NO import and no email block must still be rejected.
