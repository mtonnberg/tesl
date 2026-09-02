# Go migration — test-suite drop ledger

`roadmap/completed/migrate_to_golang.md` (requirement, 2026-08-04) said every hand-written
Racket test suite dropped by the migration must be recorded with its justification —
"silence is not acceptable". Commit `286e2ed` deleted 75 hand-written `tests/*.rkt` suites
(26,854 lines) and shipped 51 Go test files (10,725 lines) with no such record. This file
is that record, written after the fact by the 2026-09-02 language review (finding H9).

Legend — **Go home**: where the same behaviour is now asserted. **Gap**: nothing asserts it;
what was done about it. **Obsolete**: the behaviour no longer exists on Go (with the reason).

## Security-relevant suites

| Racket suite (LOC) | What it asserted | Status |
|---|---|---|
| `http-tls-tests.rkt` (310) | self-signed refused even on loopback; wrong-host chain-trusted cert refused; `TESL_HTTP_TLS_INSECURE_DEV` loopback-only, env-gated, off when deployed | **Gap → closed 2026-09-02**: `runtime/go/teslrt/httpclient_tls_test.go` (5 tests) |
| `pg-pool-tests.rkt` (205) | pool lease bounded (10 s, `TESL_PG_POOL_LEASE_TIMEOUT_MS`); timed-out lease answers 503 | **Gap → closed 2026-09-02** (review M13): knob read, acquire timeout → `RequestRejection{503}`; `database_test.go` pool-contention test |
| `session-cookie-tool-confinement-test.rkt` | a tool cannot write the outer request's session cookie | **Go home**: decided at compile time — a scope-writing handler is refused as a tool (`emit_go.ml` "cannot offer … as a tool: it writes a cookie"); pinned by `compiler/test/test_server_tools.ml` "cookie-writing handler is not offered as a tool" (added 2026-09-02) |
| `sse-capabilities-test.rkt` | SSE auth cookie reaches the response; cookie accumulator does not leak past the request; no `ACAO: *` beside a session cookie | **Partly obsolete**: Go never sets `Access-Control-Allow-Origin` (stricter). Cookie accumulator is per-request by construction (`RequestScope`, `request_test.go`). SSE auth path: `sse_http_test.go` (2026-09-02) covers the stream under the production server; the auth-failure status shape is covered by emitted `tests/*.tesl` api-tests |
| `security-test.rkt` F1 (traversal) | `..`/encoded traversal refused | **Go home**: `serve_test.go` static tests (+ dotfile/symlink cases added 2026-09-02, review M5) |
| `security-test.rkt` F4 (JSON depth 64) | deep JSON → clean 400 | **Obsolete**: `encoding/json` caps nesting at 10,000 with no stack growth (probed: 1,000,000 `[` rejected in 1.4 ms); input bounded by the 1 MiB body cap |
| `security-test.rkt` F5 (id entropy) | generated ids unguessable | **Go home**: `TestGeneratedIdsAreUnguessableAndShaped` |
| `security-test.rkt` F6 (email CRLF) | CRLF in recipient/subject refused | **Go home**: `TestSendEmailRejectsHeaderInjection` |
| `security-test.rkt` F9 (outbound CRLF, response cap) | header CRLF refused; response body capped | **Go home**: `TestOutboundHeaderCRLFIsRejected`, `TestResponseBodyCapIsEnforced` |
| `http-ssrf-tests.rkt`, ssrf guard | forbidden ranges refused at dial | **Go home**: `hostclass_test.go`, `hostname_test.go`, `TestSsrfContainmentRefusesTheDial` (+ NAT64/6to4/reserved ranges 2026-09-02) |
| `http-client-address-test.rkt` | trusted-proxy XFF walk, fail-closed | **Go home**: `request_test.go` `TestClientAddress*` |
| `response-security-headers-test.rkt` | header floor, HSTS rule, CSP precedence | **Go home**: `serve_test.go` `TestSecurityHeaderFloor*`, `TestHstsOnlyFromConfiguredHttpsOrigin`, `TestContentSecurityPolicyPrecedence` |
| `sso-adversarial-*.rkt`, `machine-login-tests.rkt` (1300) | OIDC claim validation, state/nonce/PKCE, provider errors not reflected | **Go home**: `sso_test.go` (14 + 2026-09-02 additions: unconditional `state`, previous-key cookie) |
| `jwt-test.rkt` (1023), `jwt-tests.rkt`, `jwt-session-policy-test.rkt`, `jws-verify-test.rkt` | signing, verification, renewal caps, revocation hook, JWS header refusals | **Go home**: `jwt_test.go`, `jws_test.go` (+ strict base64url 2026-09-02) |
| `crypto-runtime-tests.rkt` (625), `password-login-tests.rkt` (508) | Argon2id parameters, constant-time verify, timing equaliser | **Go home**: `password_test.go`, `crypto_test.go` (+ stored-parameter ceiling 2026-09-02) |
| `proxy-binding-http-tests.rkt` (284) | authenticating-proxy binding | **Go home**: `TestProxyVerifyBinding*` in `request_test.go`/`crypto_test.go`; `tests/*.tesl` lesson79 api-tests |
| `http-timeout-tests.rkt` (286) | outbound connect/read deadlines | **Go home**: `httpclient_test.go` timeout knobs; `TestUnreachableUpstreamTrapsCleanly` |
| `web-test.rkt` risks 49/61, 50/60 | health-probe Host exemption; mount path composition | **Go home**: `TestHealthProbePathExemptFromHostCheck`, `TestHandlerWith*` (1:1 with deleted `test_mount_path_integration.ml`) |

## Feature suites

| Racket suite | Status |
|---|---|
| `adt-indexed-fact-tests`, `adversarial-review-tests` (1904), `critical-review-*` (26 files), `body-proof-test`, `exists-*`, `multiparam_test`, `filter-check-partial-tests`, `lifted-list-tests`, `int32-runtime-tests`, `money-tests`, `civil-time-tests`, `cache-tests`, `email-tests`, `agent-*-tests`, `api-*-tests`, `http-methods-tests`, `http-stub-tests`, `httpclient-tests`, `issue-80-*`, `db-write-test-body-tests`, `memory-backend-regressions`, `postgres-test`, `port-test` | **Go home**: the paired `tests/<name>.tesl` sources compile to Go test functions and run under `scripts/run-go-test-manifest.sh` (73 sources, byte-exact `.go.snap` gate). The Racket file was the compiled form of the same `.tesl`. |
| `dap-*-smoke.rkt` (10 files), `dap-server-test.rkt` (723), `dap-value-tree-tests.rkt`, `checkpoint-condition-test.rkt` | **Go home**: `runtime/go/teslrt/debug_test.go`, `debug_control_test.go`, `debug_control_auth_test.go` (2026-09-02), `debug_state_test.go`, `internal/dap/*_test.go`, `cmd/tesl-debug-attach/main_test.go`; `tests/protocol/dap-core.json` transcript |
| `otlp-exporter-test.rkt` (278), `otlp-metrics-test.rkt` (477), `otlp-traces-test.rkt` (753) | **Partial**: `telemetry_test.go` (164 LOC + 2026-09-02 cardinality/drain/NaN tests). Trace-propagation cases: `tests/trace-propagation-tests.tesl`. The OTLP wire-shape assertions of the Racket suites were not ported one-for-one — **open** |
| `agent-provider-norm-test.rkt` (835), `agent-runtime-tests.rkt` (949) | **Go home**: `agent_test.go`, `agent_provider_test.go` (+ 2026-09-02 budget/transcript tests) |
| `codec-specialization-test.rkt`, `opaque-type-registration-test.rkt`, `memory-db-registry-test.rkt`, `emit-incidentals-regressions.rkt` | **Obsolete**: Racket emitter internals (specialised codec procedures, opaque struct registration, the memory-db registry) that have no Go counterpart; the observable behaviour is covered by `test_emit_go.ml` / `test_emit_incidentals.ml` |
| `example-api-test.rkt`, `example-test-batch.rkt`, `all.rkt`, `frontend-all.rkt`, `internal-all.rkt` | **Obsolete**: Racket-side aggregators; replaced by `ci.sh` phases 7–10 |
| `bench/*.rkt` | **Obsolete**: Racket benchmarks; Go has `bench/*.tesl` + `migration_benchmark_test.go` |

## Deleted OCaml integration tests

| File | Go home |
|---|---|
| `test_debug.ml` (1570) | `test_emit_go.ml` debug/release cases; runtime `debug*_test.go` |
| `test_integration.ml` (1191) | `.go.snap` exact-match phase; `run-go-corpus-build.sh`; `test_emit_go.ml` |
| `test_email_integration.ml` (722) | `scripts/run-go-integration.sh` chain 3 (real SMTP); `email_test.go`, `email_worker_test.go` |
| `test_httpclient_integration.ml` (550) | `run-go-integration.sh` chains 1+2; `httpclient_test.go`; `tests/http-methods-tests.tesl` |
| `test_mount_path_integration.ml` (509) | `serve_test.go` `TestHandlerWith*` (1:1) |
| `test_sql_crossseam.ml` (185) | **Obsolete by design**: Go has no runtime capability guard; the checker is sole enforcement (`test_proofsuite_capability.ml`, `test_aisuite_capability.ml`) |
| `test_emit.ml` (1374) | `test_emit_go.ml` |
| `test_racket_discover.ml` (214) | `run-go-test-manifest.sh` (git ls-files) + `go-corpus-build.json` expected_count; `test_go_discover.ml` is a stub and should be made real or deleted — **open** |

## Still open after this ledger

- OTLP wire-shape assertions (metrics/traces payload structure) — thin on Go.
- `test_go_discover.ml` stub.
- Differential Memory/Postgres suite (review M19) — the class of bug that H1/H2/M9/M11/M12 belong to has no standing oracle; `database_test.go` now carries side-by-side cases for the ones found.
