# Use OpenAPI output for DAST

## Completed 2026-09-04

The checked server-specific OpenAPI 3.1 artifact now feeds the first-party ZAP
workflow. `tesl dast` generates the selected server document, imports it into
ZAP, keeps reports under `.tesl-stuff/dast/`, supports environment-referenced
Authorization headers, and fails on Medium/High findings without starting the
target. `tesl test --with-dast --dast-target URL` remains opt-in and runs only
after generated tests pass.

Completion evidence:

- `tests/dast-openapi-smoke.sh` is a checked-in disposable staging gate. It
  proves PublicServer excludes sibling InternalServer, exercises unauthenticated
  401 and authenticated 200 operations, and runs active ZAP import.
- Active ZAP scans covered all 21 runnable `main() -> App` entrypoints; no
  Medium/High findings were reported.
- `tests/cli-portability.sh` verifies secret placeholders stay out of the plan
  and the report/High/Medium exit-status gate is present.
- `manual/openapi-dast.md` documents local, CI, authorization, retention, and
  runtime-owned-surface boundaries.
- `example/learn/lesson81-openapi-dast.tesl` teaches the workflow and serves as
  the smoke app.

## What

Turn the checked OpenAPI artifact from `tesl generate-openapi` into a first-class Dynamic
Application Security Testing workflow. The completed OpenAPI emitter gives scanners the declared
routes and wire schemas; this item makes that artifact easy to use against a deployed staging app.

## Why

DAST tools such as Nuclei, StackHawk, OWASP ZAP, and Burp can discover and exercise an API from an
OpenAPI file, but a generated file alone does not create a repeatable security gate. Tesl already
has the stronger inputs a scanner needs: typed captures, request/response shapes, auth declarations,
proof metadata, and a server-specific route allowlist. The goal is to connect those inputs to a
staging scan without adding a public production documentation endpoint.

## Scope

- Add `tesl dast <URL>` with ZAP as the first scanner-neutral adapter. Generate the checked
  server-specific OpenAPI artifact automatically, retain reports under `.tesl-stuff/dast/`,
  and install scanner binaries through the Nix flake rather than downloading them at runtime.
- Keep baseline/passive scanning as the default. Require explicit active-scan and non-loopback
  opt-ins, and support environment-referenced authorization headers without serializing secrets.
- Add `tesl test --with-dast --dast-target <URL>` as an opt-in gate that runs after generated
  Tesl tests pass; it must not start a server implicitly.
- Add a documented CI recipe that runs `tesl --check`, generates OpenAPI for the deployed server,
  starts or targets staging, and invokes a selected DAST scanner in OpenAPI-import mode.
- Provide scanner-neutral artifact and secret-handling guidance, including test credentials,
  staging-only targets, rate limits, and retention of scan reports.
- Define how authenticated operations are exercised without putting cookies, bearer tokens, or
  passwords into the generated specification or CI logs.
- Add a scanner smoke fixture that proves every generated path is imported and at least one
  authenticated and one unauthenticated operation is exercised.
- Decide how runtime-owned surfaces omitted from Phase 1 (`/auth/*`, metrics, static files, and
  SSE transport details) are supplied as explicit supplementary targets.
- Prefer a small reusable CI action or script over coupling the compiler to one commercial scanner.

## Non-goals

- No default-on DAST scan during `tesl build`.
- No implicit server startup for `tesl dast` or `tesl test --with-dast`.
- No production `/api-docs` route requirement.
- No claim that proof annotations replace scanner authorization setup; proofs remain compiler and
  server guarantees, while OpenAPI metadata is descriptive.

## Acceptance evidence

1. [x] A checked-in CI example generates a server-specific OpenAPI 3.1 file and runs one supported DAST
   importer against a disposable staging deployment.
2. [x] `tesl dast <URL>` performs the same generation/import flow locally with ZAP installed by Nix.
3. [x] The scan fails the CI job on Medium/High API findings and publishes the report; the generated
   ZAP plan is pinned by the CLI portability test.
4. [x] Credentials are injected from the CI secret store, never serialized into OpenAPI, logs, or
   committed fixtures.
5. [x] The smoke fixture confirms sibling-server endpoints are absent from the selected server's spec.
6. [x] Documentation explains the boundary between declared API coverage and explicitly supplied
   runtime-owned routes.

## Related

- `roadmap/completed/openapi-spec-generation.md`
- `manual/openapi-dast.md`
