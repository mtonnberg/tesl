# Security hardening — secure-by-default runtime fixes (DONE)

Completed 2026-06-30 on `core_polish`. The bounded, high-value slice of the
`security_hardening` program: concrete secure-by-default **runtime** fixes, each a
small change to the trusted Racket runtime (`dsl/`, `tesl/`), landed with a
standing regression suite. The unbounded/architectural remainder is split to
`roadmap/later/security_hardening_program.md`.

## Fixes shipped
| # | Fix | File | Note |
|---|---|---|---|
| F1 | **Static-file path traversal** (High) | `dsl/web.rkt` | `try-serve-static` now rejects `.`/`..`/separator URL segments + a `simplify-path` containment check (resolved path must stay under the static dir). Blocks `GET /../../etc/passwd`. Extracted pure `static-path-segments-safe?` (exported, unit-tested). |
| F2 | **Internal exception text leaked to clients** (Med) | `dsl/web.rkt` | The 500 `details` and the decode-path 400 message no longer echo `(exn-message exn)` by default — generic message; full text only under `TESL_VERBOSE` (and always server-logged). |
| F3 | **No request-body size limit** (High, DoS) | `dsl/web.rkt` | `parse-json-body` rejects bodies over `max-body-bytes` (default 1 MiB, env `TESL_MAX_BODY_BYTES`) with 413, before `bytes->jsexpr`. |
| F4 | **No JSON nesting-depth limit** (Med, DoS) | `dsl/types.rkt` | `jsexpr->typed-value` caps recursion depth (default 64, env `TESL_MAX_JSON_DEPTH`) via a dynamic counter; deep input → clean 400 instead of stack exhaustion. Covers the recursive decode paths (record/ADT/dict/set/newtype). |
| F5 | **Predictable prefixed IDs** (Med) | `tesl/private/runtime.rkt` | `tesl-generate-prefixed-id` now uses `crypto-random-bytes` (128-bit hex) instead of `current-seconds` + `(random 1e6)`. |
| F6 | **Email header CRLF injection** (Med-High) | `tesl/email.rkt` | Recipient/subject rejected if they contain CR/LF (header injection / Bcc exfiltration). Extracted `email-header-field-safe?` (exported, unit-tested). |
| F7 | **Cache `LIKE` over-invalidation + TTL interpolation** (Low-Med) | `tesl/cache.rkt` | Prefix invalidation uses a literal `left(key,length($1))=$1` match (no `%`/`_` wildcards); TTL bound as `$3 * interval '1 second'` instead of string-interpolated. |
| F8 | **SSE auth-failure raised a 500, not 401** (Med) | `dsl/web.rkt` | `(raise (auth-result))` (applied the check-fail as a procedure → uncaught error → 500 + stack leak) → `(raise auth-result)`; the `check-fail?` guard renders a clean 401. |
| F9 | **Outbound HTTP header CRLF + unbounded response** (Med) | `tesl/http-client.rkt` | Outbound header names/values rejected on CR/LF (request splitting); response body capped at `max-response-bytes` (default 10 MiB, env `TESL_HTTP_MAX_RESPONSE_BYTES`). Extracted `http-header-field-safe?` (exported, unit-tested). |

## Tests
`tests/security-test.rkt` — a rackunit suite wired into `tests/internal-all.rkt`
(run by `compile-examples.sh` §3 and `ci.sh`'s `dune test`). One adversarial case
per unit-testable class (the `SQL-INJ-*` precedent generalised): F1 (8 traversal
vectors), F4 (shallow ok / 300-deep rejected), F5 (3000 unique high-entropy ids),
F6 (CRLF rejected), F9 (CRLF rejected). F2/F3/F7/F8 are code-reviewed and
gate-verified (no regression across the full sweep + racket aggregate + the
httpclient/email integration tests); F7 is additionally exercised by
`tests/cache-tests.tesl`.

## Decisions
- Deferred (need allowlist config or could break local/self-signed dev), → the
  later program: HttpClient SSRF allowlist (H1) + verified TLS (H2/D2/D5),
  HttpClient request timeout (H4 — a thread/`sync-timeout` control-flow change),
  default-deny auth (#3), SSE per-key authz (S1) + SSE CORS allowlist (S3) + SSE
  connection caps (S4), security headers/HSTS/CSP (#8), password-hashing
  primitive (#11), secret redaction in logs (#7/#10).
- Did NOT touch the trusted emitter/checker for these (no TCB changes); the
  TCB-soundness program (differential parity gate, emitter mutation, adversarial
  proof corpus, lints-as-policy, SBOM, L1–L7) is the later program.
