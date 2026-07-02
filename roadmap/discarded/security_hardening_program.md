# Security hardening — the standing program (deferred remainder)

Split from `next/security_hardening.md` 2026-06-30. The bounded secure-by-default
runtime fixes shipped (`completed/security_hardening_runtime_fixes.md`); this is the
**unbounded/architectural** remainder. Security scope is unbounded by nature — this
file is the prioritized backlog, not a single landable change. The full audit
(findings tables with `file:line`, threat model, layer model) lived in the original
`security_hardening.md`; the headlines are preserved here.

## B. Secure-by-default runtime — policy/design items not in the bounded slice
- **Default-deny auth (#3)**: an endpoint without `Auth` is currently public.
  Needs a `#[public]`-style explicit opt-in + a lint. Framework-default change.
- **SSE per-key authorization (S1, High)**: the channel key is taken from the URL
  with no check the caller may access THAT key (IDOR/BOLA). Needs a key→authz hook
  with a proof-carrying allow decision.
- **SSE CORS allowlist (S3)** + **connection caps (S4)**: replace hardcoded
  `Access-Control-Allow-Origin: *`; cap concurrent streams per-IP/global.
- **Security response headers (#8)**: HSTS/CSP/X-Frame-Options + configurable CORS.
- **Verified TLS (H2 / D2 / D5)**: HttpClient, SMTP, and Postgres use Racket's
  default client context (no peer/hostname verification). Add verified contexts —
  but gate so localhost/self-signed dev still works.
- **HttpClient SSRF allowlist (H1, High)**: a request-derived URL can hit
  `169.254.169.254` / loopback / RFC1918. Resolve-then-check deny-list + scheme pin.
  Deferred from the bounded slice (needs config so legit egress isn't broken).
- **HttpClient request timeout (H4)**: a hung upstream ties up a handler thread;
  needs a `sync/timeout`-based wrapper (control-flow change).
- **Password-hashing primitive (#11)**: ship Argon2id/bcrypt so apps don't roll
  their own.
- **Secret redaction (#7/#10)**: redact DB/SMTP/JWT secrets from error text and
  `TESL_VERBOSE` SQL-param logging.

## C. Lints as executable security policy (zero-effort prevention)
Compile-time lints (building on the opinionated linter): unauthenticated endpoint
without explicit opt-in; raw error/`exn-message` to a client; secret-typed value
into a log; missing body-size limit; non-CSPRNG ID as a token; an `establish`
inventory/audit lint (L1); output-sink escaping lint (L3); telemetry-redaction
lint (L4).

## D. Property/fuzz harness + supply chain
- Fuzz `jsexpr->typed-value` and the parser with malformed/huge/deep inputs;
  assert invariants (no crash, bounded resources, no internal leakage). Fuzz the
  SQL builder asserting always-parameterized.
- SBOM + advisory scan + reproducible-build verification (cheap given the zero-dep
  compiler + pinned nix).

## E. Language-surface / trust-model audits (L1–L7)
`establish` trust escape hatch (L1); crypto-free `auth` root / no signed-session
primitive (L2); no contextual output escaping (L3); telemetry as an ungated egress
sink (L4); codec/deserialization of untrusted input (L5); resource exhaustion via
unbounded computation (L6); auto-migration DDL at startup (L7).

## Coverage matrix + completeness critic
Maintain a table mapping vuln-class → test layer → location → CI gate, and run a
periodic "what has no automated test?" review, converting each gap into a
corpus/property/lint entry. Silence is not coverage.
