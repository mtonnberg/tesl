# Handler with mismatched parameters compiles but crashes at runtime (soundness)

## Why (the bug — "incorrect code through the compiler")
Found 2026-06-30 (pass 2, while writing lesson66). A `handler` whose parameter
list does not match what the API endpoint provides (the auth-proven value(s) +
path params) passes `--check` but raises at runtime when the server dispatches:

```tesl
api SearchApi { get "/search" auth q : String ::: SearchQuery q via requireQuery -> String }
# handler declares an EXTRA param the dispatch never supplies:
handler search(req: HttpRequest, q: String ::: SearchQuery q) -> String requires [] = ...
```
→ `--check` exits 0 (accepted), but `raco test` / runtime:
`define-server: handler for endpoint search does not accept 1 arguments`.

The server passes exactly the endpoint's provided values (here: 1, the auth-proven
`q`); the handler declared 2 params (`req`, `q`). The checker does not verify that
a handler's parameters match the endpoint contract, so the arity mismatch escapes
to runtime — the exact "incorrect code through the compiler" class.

## Investigate / fix
- Where the server binds a handler to an endpoint (`define-server` in dsl/web.rkt
  emits the arity check at runtime). The compile-time gap is in the checker /
  API-validation: it should verify each `server NAME for API { ep = handlerFn }`
  that `handlerFn`'s parameter list matches the endpoint's contract — the path
  capture params + the `auth ... ::: Fact via ...` proven value(s) — by count,
  order, type, and attached proof. Reject with a clear error otherwise.
- Anchor: the API/server validation (validation_*.ml / checker.ml handling of
  DApi / DServer), and how endpoint contracts (path params + auth value) are
  represented.
- Note: handlers do NOT receive the raw `HttpRequest`; request data is read in
  `auth`/`proof` functions and passed as proven values. The error message should
  make that clear if a handler tries to take `req: HttpRequest`.

## Tests (mandatory negatives)
- handler with an extra param vs the endpoint → REJECTED at compile time.
- handler missing a param the endpoint provides → REJECTED.
- handler with a param of the wrong type / wrong proof → REJECTED.
- correct handler (params == endpoint contract) → accepted + runs.

## Status: targeted fix DONE (2026-06-30, core_polish)
`check_server_handler_binding` (validation_structural) already checked
handler-declared + HandlerKind + return-type + auth-proof presence. Added the
canonical missing check: a handler parameter typed `HttpRequest` is REJECTED at
compile time (handlers never receive the raw request — request data is read in the
auth/proof fn; taking `req: HttpRequest` crashed define-server at startup with an
arity error). Safe + zero false positives (verified: handlers map params
POSITIONALLY, so a capture/body param need not match by name — `getTask(x)` validly
receives capture `id`; POST/PUT have an implicit body param). Tests: R65_SH01/02.

The FULL positional count/type/proof contract (incl. POST/PUT implicit body and
auth-value position) is deeper + risk-prone (a name-based attempt false-positived on
valid positional handlers); tracked as soundness_increase Tier-0 #2 (derive the
handler contract from the endpoint).
