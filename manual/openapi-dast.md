# OpenAPI and DAST

Tesl can export the declared surface of one server as an OpenAPI 3.1 document. The
document is generated from the checked `api` and `server` declarations, so route paths,
captures, request bodies, response schemas, auth requirements, and proof annotations stay
aligned with the program.

## Generate a specification

Run the command against the source file and select the server to document:

```bash
tesl generate-openapi app.tesl AppServer --output .tesl-stuff/build/openapi.json
```

The command runs the normal whole-program checker first. It refuses to emit a specification
for a program with compiler errors. A server's document contains only the API named by that
server, which matters when one module declares separate public and internal servers.

Path captures use OpenAPI syntax. Tesl's `/users/:userId` becomes `/users/{userId}`. Session
authentication is represented as an `apiKey` cookie security scheme named `__Host-session`,
and authenticated operations declare a 401 response. Captures also declare a 404 response.

Proofs are documentation, not a replacement for Tesl enforcement: the proof text appears in
the operation description and in `x-tesl-proof`. The compiler and the running server remain
the authority for proof and authorization checks.

## Use it in DAST

DAST scanners need a specification file, not a special runtime endpoint. Generate the file in
CI after checking the program, then give it to the scanner's OpenAPI import mode or project
configuration:

```text
tesl --check app.tesl
tesl generate-openapi app.tesl AppServer --output build/openapi.json
<DAST scanner> import build/openapi.json and scan https://staging.example.com
```

This exposes the complete declared route inventory to tools such as Nuclei, StackHawk,
OWASP ZAP, and Burp without hand-maintained route lists. Run scans against a disposable
staging deployment, provide test credentials through the scanner's secret store, and keep
production credentials out of the specification and CI logs.

Tesl also provides a local ZAP workflow. The default is a passive baseline scan; it never
starts the application or downloads scanner add-ons:

```bash
tesl dast https://staging.example.com app.tesl --server AppServer
```

Reports are written to `.tesl-stuff/dast/`. Active checks require an explicit opt-in, and
active scans outside loopback require a second opt-in:

```bash
tesl dast http://localhost:8090 app.tesl --server AppServer --active
tesl dast https://staging.example.com app.tesl --server AppServer --active --allow-remote
```

Inject an authorization header from the environment without writing its value to the
OpenAPI file or scan plan:

```bash
TESL_AUTH_HEADER='Bearer ...' tesl dast https://staging.example.com app.tesl \
  --server AppServer --authorization-env TESL_AUTH_HEADER
```

`tesl` installed from the Nix flake includes OWASP ZAP and Nuclei. Nuclei is available for
separate scanner workflows through the same Nix environment; `tesl dast` currently uses ZAP
as its supported first-party backend.

The generated file describes the declared API only. Runtime-owned SSO login/callback routes,
static files, metrics, and other deployment surfaces are outside this Phase 1 export; include
separate scanner targets for those surfaces when they are enabled.

## Keep the artifact reproducible

Generate into `build/` or `.tesl-stuff/build/`, not by editing a checked-in copy manually. The
same source commit, compiler version, and selected server should produce the artifact used by
the scanner. Store the artifact as a CI result when audit or review history requires it.

See [Deploying a Tesl web API](deploy.md) for container builds and
[the language specification](../LANGUAGE-SPEC.md) for the API declaration rules.
