# OpenAPI Specification Generation

Automatically generate an OpenAPI spec from `api` and `server` declarations.

## Update 2026-08-03

Moved back from discarded/ to later/ because this would make Tesl compliant
with/a good fit for Dynamic Application Security Testing (DAST) tools, such as
Nuclei or StackHawk.

Design reviewed 2026-08-03 against the current compiler. The review confirmed
the core claim (the IR layer already carries everything the emitter needs) but
changed the shape of the feature: the original design bundled one cheap,
reversible emitter with two default-on language/product commitments (spec
generation on every compile, and a reserved `/api-docs` path on every server).
Those commitments are now split out and made opt-in — see Design below.

## Value

- Zero-effort API documentation.
- DAST tooling (Nuclei, StackHawk) can scan the full declared surface. Note:
  these tools consume a spec *file* — a live endpoint is NOT required for this
  motivation.
- Integration with Swagger UI, Redoc, Postman, etc.
- Type-safe client generation for TypeScript, Python, Go, etc. (secondary —
  Elm/Zod emitters remain the first-class, proof-carrying clients).
- Adoption: teams can evaluate a Tesl API with tools they already know.

## Verified groundwork (2026-08-03)

- `ir_endpoint` (compiler/lib/ir.ml:125) already carries HTTP method, path,
  captures (typed, with `via`), auth binding + via, body wire type / decoder,
  response wire type / encoder, and the full `ir_return`.
- `endpoint_json` (ir.ml:909) already emits a JSON endpoint catalog for
  `--doc-json`. The OpenAPI emitter is essentially a transform of that plus
  the JSON Schema walk the Elm/TS emitters already do over type definitions.
- Existential returns are NOT an open problem: `IRRetExists` erases to its
  body's wire shape in emit_ts.ml (:457) already. The OpenAPI schema mirrors
  the Zod client shape — one representation, already stable.

## Design

### Phase 1 — command-only emitter (this item's core)

`tesl generate-openapi <Server> --output openapi.json` emits the spec for one
server type. Pure emitter over the existing IR, zero language-surface change,
fully reversible. This alone satisfies the DAST motivation and the
move-to-completed criterion.

- One spec per `server` type, containing only the `api`s that server serves
  (matches the two-API allowlist semantics — a spec must not leak endpoints
  of a sibling server sharing handlers).
- Proof annotations go into `description` AND a structured `x-tesl-proof`
  vendor extension, so tooling can read them without parsing prose. The
  narrowing (proofs are informational in the spec, enforced only by the real
  server and the first-class clients) must be stated in the spec's `info`
  section.
- Auth mapping: session cookie auth → `securitySchemes` (apiKey/cookie
  scheme); endpoints with an `auth` binding get the scheme + a declared 401
  response.
- Error responses: the compiler knows enough to emit real `responses`
  entries — 401/403 where auth is declared, 404 for captures, 503 (pool
  exhaustion) on DB-backed handlers. Cheap and high-value for DAST.
- Compiler-added routes must be an explicit decision, not an omission. The
  runtime dispatches, besides `api` endpoints: SSO routes
  (`/auth/<segment>/login|callback`), SSE routes, static files, and the
  metrics endpoint. For the DAST use case the SSO login/callback paths at
  least should be included (they are attack surface); whatever is excluded
  gets listed in the spec's `info.description` so exclusion is visible.
- Pin the OpenAPI version before writing the emitter: 3.1 uses real JSON
  Schema (better fit for ADTs), but some DAST tools are still 3.0-only.
  Verify Nuclei + StackHawk support, then pin — do not target "3.x".

### Phase 2 — opt-in served endpoint (separate decision, later)

If a server should serve its own spec, it is opt-in via server config (e.g.
`apiDocs True`, path configurable). Never default-on.

**Why serving matters at all (verified 2026-08-03):** an externally hosted
Swagger UI cannot exercise a Tesl server from the browser, by design — three
independent protections block it: the `Sec-Fetch-Site: cross-site` refusal
403s every state-changing "Try it out" (dsl/web.rkt:2268), the
`__Host-session` cookie is `SameSite=Lax` so it is withheld from all
cross-site fetches (authenticated GETs 401 too), and api responses carry no
CORS headers so the browser cannot read them cross-origin anyway. Same-origin
serving is therefore the *only* way interactive browser testing works with
auth. None of this affects DAST: Nuclei/StackHawk are not browsers — no
Sec-Fetch-Site header (absent = allowed by design), no SameSite, no CORS —
they work from the Phase 1 file directly.

**Rejected middle ground — serve an empty Swagger UI page without embedding
the spec** (user pastes the generated file in, keeping same-origin behavior
without disclosure): the cost/benefit fails. It requires embedding
swagger-ui-dist (~1.5 MB of third-party JS/CSS) as string constants in every
emitted server — supply-chain surface in a security-audited binary, version
upkeep, and a CDN load instead is its own supply-chain/CSP problem. The only
thing it protects against is spec disclosure, which the auth-gating decision
below already handles — and anyone able to paste the file already has the
spec (they ran the Phase 1 command). The useful axis is dev vs prod, not
spec vs no-spec:

- `tesl run` (dev): serve UI + spec same-origin, **default-on**. This is the
  adoption value prop — a newcomer runs their first server and gets an
  interactive, working docs page for free ("Try it out" works with real
  session cookies because it is same-origin). Disclosure is irrelevant on a
  dev machine, and the UI bundle bloat stays in the dev artifact only.
  Default-on means the path cannot be claimed by injection-plus-
  duplicate-check (a program that never opted in and legitimately uses
  `/api-docs` must keep compiling). So dev docs live under a namespaced
  path — `/__tesl/api-docs` — and one validation rule reserves the `__tesl`
  leading path segment for the runtime (compile error on user endpoints
  using it). Reserving a double-underscore namespace is a small, defensible
  language commitment (cf. Next.js `/_next`), covers every future
  runtime-owned route, and makes silent shadowing impossible by
  construction rather than detected case-by-case.
- Production build: nothing served by default; DAST consumes the Phase 1
  file in CI. Default-on-behind-auth in production was considered for the
  adoption story and rejected: "behind auth" is ill-defined as a default.
  A server with no auth mechanism has nothing to gate behind (a public spec
  by default = reconnaissance disclosure in the default program), and a
  server with multiple proof levels (admin vs plain) gives the compiler no
  reliable "strongest auth" to pick. An ambiguous security default is worse
  than an explicit choice. The default Tesl program's production surface
  must not grow.
- Production `apiDocs True`: full UI + spec, gated behind the server's auth —
  the exposure decision is explicit and owned by the team. To keep it
  discoverable (the adoption half that IS safe in prod), the compiler/CLI
  prints a one-line hint when building a server without it — the issue #55
  lesson: discoverability gaps get fixed with hints, not with default
  surface.

- **No file I/O.** Tesl has no file library by design, and serving from disk
  (the existing static-file mechanism) risks drift between binary and spec.
  Instead the compiler embeds the generated spec as a string constant in the
  emitted server and serves it from memory — atomic with the build by
  construction, same pattern as other compile-time-embedded data.
- **No path reservation.** Instead of a reserved path, the compiler injects
  the docs endpoint into the server's normal route table *before* the
  duplicate-path validation (validation_structural.ml `seen_method_paths`).
  A user endpoint colliding with the configured docs path then fails at
  compile time with the ordinary duplicate-path error — fail-closed, clear,
  and zero new "reserved path" machinery in the language.
- **Auth decision required.** A public spec endpoint discloses the complete
  endpoint + auth map (reconnaissance value). Since DAST consumes the file
  from Phase 1, the served endpoint is a human convenience — default it to
  requiring the server's auth, or leave exposure an explicit config choice.
  (This same gate is what makes the "empty UI" middle ground above
  redundant.)

### Generation cadence

Not on every `tesl run`/`tesl compile` by default — that couples every build
to spec emit and churns files. If automatic emission is wanted, write into
`.tesl-stuff/build/` (the build output dir exists for exactly this) rather
than the repo, or keep it command-only. No `--skip-openapi-generation` flag
needed once generation is not default-on.

## Related latent bug found during this review (fix independently)

SSO routes are dispatched BEFORE api dispatch (dsl/web.rkt:2745, cond clause
0) and match *any* HTTP method on `/auth/<segment>/login` and
`/auth/<segment>/callback`. There is no compile-time conflict check
(validation_structural.ml checks duplicate user paths and empty sso segments
only). A user endpoint declared on one of those paths compiles clean and is
silently shadowed at runtime — the exact hazard the "reserved path" idea would
have institutionalized, already live for SSO. Fix: when a server has an `sso`
clause with segment S, the duplicate-path validation should error on any user
endpoint matching `/auth/S/login` or `/auth/S/callback` (any method). SSO
cannot move under the `__tesl` namespace (callback URLs are registered with
external OIDC providers), so it needs this per-segment rule.

Taken together, the path-protection work is ONE small validation feature at
the `seen_method_paths` site (validation_structural.ml) with three clients:
(1) the `__tesl` reserved leading segment (dev docs page, and any future
runtime-owned route), (2) the SSO `/auth/S/login|callback` conflict error,
(3) the Phase 2 opt-in docs endpoint injected as an ordinary route so
collisions surface as the existing duplicate-path error.

## Challenges

- Proof annotations don't map to JSON Schema — carried as `description` +
  `x-tesl-proof`, narrowing stated explicitly (see Design).
- ~~Existential return types need a stable JSON representation.~~ Resolved:
  mirror the existing TS/Elm wire shape (see Verified groundwork).
- Authentication mechanism mapping (session cookies → `securitySchemes`,
  SSO routes documented as oauth2/openIdConnect flows or plain paths).

## Scope

Medium. Phase 1 is mainly writing the emitter over the existing IR + type
walk. Phase 2 is small once Phase 1 exists (embed string, inject route) but
carries the auth/exposure decision.

Move to `completed/` when: the generated spec validates against the pinned
OpenAPI version and can drive Swagger UI (Phase 1 alone qualifies).

## Notes

- Proof annotations being weaker in OpenAPI-generated clients is acceptable
  as long as the narrowing is clearly stated. The first-class emitters
  (Elm, Zod) remain the proof-carrying path.
- This will potentially make adoption easier as well.
