# Email capability is not composable (user report, confirmed 2026-07-06)

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

## Fix

Add the provider row — `"Tesl.Email", [("email", [])]` — to
`Validation_common.tesl_stdlib_cap_map` (single source; `Proof_checker.stdlib_capabilities`
references the same binding, so both checkers pick it up). Then
`import Tesl.Email exposing [email]` composes exactly like `dbRead`:
usable in `requires [...]` and in `capability … implies …` chains. Runtime
enforcement is unchanged (capability grants still flow from `main`/serve scope);
this only lets the NAME be referenced where the import is in scope. Keep the
`DEmail`-implies-`email` implicit definition for app modules.

Consider the same audit for `cacheCap <Name>` (cache caps are also only locally
defined) and add a seam test asserting every capability name accepted by the
`Type_system` stdlib import allowlist resolves in `tesl_stdlib_cap_map` — that
test closes the drift class, not just this instance.

## Verification

Red→green: the three probes above (implies-chain, library helper, stdlib-import
path) plus `./ci.sh` 13/13. Antagonistic control: `requires [email]` with NO
import and no email block must still be rejected.
