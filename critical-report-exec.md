# Tesl Critical Audit: Executive Summary

**Reviewed:** commit `b80264f2a36df179d1f2ca2176b133a4095a17d6`, 2026-09-04.  
**Scope:** language/proof thesis, compiler, Go runtime, PostgreSQL resources, editor/agent interfaces, security, product maturity, and funding readiness.  
**Full report:** [`critical-report.md`](critical-report.md)

## Remediation Update

The findings below describe the audited revision. A 2026-09-04 remediation pass fixed every confirmed non-migration technical finding with regressions. The resulting working tree passed the authoritative `./ci.sh` gate, 22/22 phases in 754 seconds, including race/fuzz/static analysis, live PostgreSQL, generated-code corpus, Nix clean install, DAST, and browser SSO.

Fixed areas include standard MCP JSON-lines transport, imported diagnostic identity and LSP importer invalidation, fenced queue/email claims, bounded commit-ordered SSE recovery, PostgreSQL and Memory concurrency, execution-isolated live debugging, exact-origin CSRF, shell-free trusted VS Code tasks, total compiler JSON envelopes, recursive schema validation, complexity limits, backend-aware acceptance, accurate LSP capabilities, hover/lint coverage, and stale test/documentation removal.

General application schema migration and rolling-deploy queue-payload evolution remain deferred by explicit scope. Runtime-internal idempotent columns for claim fencing and SSE dispatch do not close that lifecycle gap. Product, adoption, distribution, concentration, and funding conclusions therefore remain unchanged.

## Verdict

Tesl's technical core is credible. It implements a meaningful proof-carrying API model in which validation and authorization evidence can be introduced only at explicit trusted boundaries and then tracked statically. The proof kernel is small and fail-closed, the compiler rejected attempted evidence forgery, and the project has an unusually comprehensive quality gate.

Tesl is not production-ready or commercially validated. The audit found a broken standard MCP transport, unfenced durable work claims, no production schema evolution, incorrect cross-file diagnostics, and several concurrency, security, and tooling defects. No proof-kernel bypass, SQL injection, remote-code-execution path, or critical authentication bypass was confirmed.

**Funding recommendation:** do not fund Tesl as a broad mainstream API platform today. A small milestone-based pre-seed investment may be rational around the narrower thesis of compiler-enforced proof continuity for APIs.

## Proof Claim

Tesl does not mathematically prove arbitrary business predicates. User-authored `check`, `auth`, and `establish` declarations are trusted assertion boundaries. The compiler proves that evidence came from an allowed source and remains attached to the correct subject; proof and capability data are then erased with no runtime re-check (`LANGUAGE-SPEC.md:49-51,84-123`; `compiler/lib/proof_kernel.ml:1-53`).

This is valuable, but the accurate claim is:

> Tesl statically preserves evidence introduced by explicit trusted boundaries and rejects unauthorized evidence flow.

## Principal Findings

| Severity | Finding | Consequence |
|---|---|---|
| **Critical** | MCP uses LSP/DAP `Content-Length` framing instead of MCP newline-delimited stdio (`runtime/go/cmd/tesl-mcp/main.go:44-47`). | Conforming MCP clients cannot initialize. Internal tests repeat the same wrong framing and pass. |
| **High** | Queue and email claims have no attempt token (`runtime/go/teslrt/pgstores.go:382-472,665-697`). | An expired worker can delete, retry, or unlock a replacement worker's active claim. Reproduced on live PostgreSQL. |
| **High** | Existing database schemas are never evolved (`runtime/go/teslrt/postgres.go:222-260`). | Normal production upgrades leave Tesl's safety model; the migration design is explicitly unimplemented. |
| **High** | `agent-context` removes source file identity from imported-module errors (`compiler/lib/compile.ml:4041-4068,4182-4193`). | Agents can be directed to edit the wrong file. |
| **High** | LSP discards all dependency diagnostics (`runtime/go/internal/lsp/server.go:1682-1702`). | An editor can report a clean project while `tesl check` fails. |
| **Medium** | PostgreSQL initialization and process-global binding are unsafe under concurrency. | Duplicate pools, bootstrap traps, missing or stale database bindings. |
| **Medium** | SSE recovery advances an allocation-order cursor past late commits (`runtime/go/teslrt/pgpubsub.go:499-535`). | A committed event can be silently lost during LISTEN reconnect. |
| **Medium** | Debug snapshots are not stop-the-world or request-isolated. | Agents can receive mixed stacks, mismatched SQL, and non-atomic state despite stronger documentation claims. |
| **Medium** | Same-site sibling origins bypass exact-origin CSRF validation. | A compromised sibling subdomain can submit authenticated state-changing requests. |
| **Medium** | VS Code commands interpolate paths/names into shell text. | User-invoked commands can execute shell substitution embedded in repository-controlled names. |
| **Medium** | Compiler JSON APIs emit plain text on lexer-fatal input; `agent-context` can report `ok:false` with exit 0. | Editor and agent automation becomes unreliable on malformed in-progress files. |
| **Medium** | Checker-visible stdlib exports are unavailable in the only backend. | Programs can be editor-green and build-red. |

Additional Medium findings cover deep-expression complexity, MCP debug timeout/default drift, LSP capability and formatting mismatches, and fail-open compiler schema decoding. Lower findings include unbounded unauthenticated debug handshakes, Unix socket path failure, incomplete hover coverage, and stream desynchronization after malformed frames.

## Strong Evidence

The authoritative `./ci.sh` gate passed all 22 phases in 564 seconds. Coverage included:

- OCaml compiler and proof tests
- 574 metamorphic tests and all 13 registered language invariants
- Go runtime, emitted-code, race, fuzz, vet, and static-analysis gates
- exact generated-code snapshots and mutation testing
- live PostgreSQL and integration tests
- Nix clean-install and CLI portability
- OpenAPI DAST and browser SSO end-to-end tests
- documentation and playground/compiler parity

Other verified strengths include parameterized SQL, centralized identifier quoting, hardened JWT/JWS and Argon2id handling, SSRF enforcement over resolved peers and redirects, secret redaction, bounded requests and responses, generated-code inspection, and candid beta documentation.

## Product Assessment

The investable wedge is proof continuity for API validation, authorization, and effects, particularly where compiler diagnostics can guide human and AI edits. The broader claim of a complete mainstream API platform is unsupported.

No repository evidence was found for production customers, paid pilots, retention, or comparative defect/productivity improvements. A public snapshot showed 3 GitHub stars, 0 forks, no releases or tags, and effectively one contributor identity. Private traction was not available, so the correct conclusion is that demand is unproven.

Adoption is constrained by Nix-only installation, no tagged releases, no reusable package ecosystem, deliberately narrow host interop, and a platform surface spanning compiler, runtime, data, auth, messaging, observability, agents, deployment, LSP, DAP, and MCP. That scope is too broad for the publicly visible team and traction.

## Funding Gates

1. Fix MCP conformance, cross-file diagnostics, extension command execution, and durable claim fencing.
2. Ship safe schema and queue-payload evolution, or refuse unsupported changes before deployment.
3. Secure several independent design partners running real services with credible willingness to pay.
4. Narrow to one ICP and one high-value workflow; freeze unrelated platform expansion for six months.
5. Publish versioned non-Nix Linux/macOS installation paths.
6. Demonstrate upgrades, restarts, rolling deploys, schema changes, retries, and recovery on real services.
7. Obtain an independent proof-boundary/runtime security review against a tagged release.
8. Measure defect reduction and agent/human review effort against a credible established stack.
9. Add another regular compiler/runtime contributor and explicit release/security ownership.

## Conclusion

Tesl is an impressive and technically substantive compiler project, not yet a dependable platform or validated company. Its narrow proof-carrying API thesis deserves further testing. Funding should remain conditional on protocol correctness, production lifecycle safety, focused demand, and independent operational evidence.
