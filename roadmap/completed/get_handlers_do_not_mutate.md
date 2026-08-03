# Enforce "GET handlers do not mutate" at compile time

> **Status:** DONE 2026-08-03 (see "What shipped" below). **Effort:** was S–M. A checker rule over
> the api/server surface, no new syntax, no runtime change.

## What shipped

Enforced as a hard error under the EXISTING code `SEC005` — which already existed as a lint
*warning* (`linter.ml` `sec005_get_write`) covering only `dbWrite`/`queueWrite`. No new SECxxx code
was minted; the code, its `tesl explain` prose and its manual deep-link were kept and the severity
and owning pass moved.

- `Validation_capabilities.check_get_routes_do_not_mutate` — the rule, wired into `validation.ml`
  next to `check_handler_capabilities`. Forbidden closure `get_forbidden_caps` =
  `{dbWrite, queueWrite, pubsub, emailCap}`. Body-derived via `collect_needed_capabilities` for a
  local handler; for an IMPORTED handler there is no body here, so it falls back to
  `load_imported_func_caps` (declared ∪ body-derived — an over-approximation, i.e. it can only
  over-reject, never launder across a module boundary).
- `validation_error` gained a `code` field (default `""` ⇒ the pass-generic `V001`), so a security
  pass can keep its stable code as a hard error. `compile.ml` honours it for both the rendered code
  and the manual anchor.
- `Validation_common.server_endpoint_bindings` — the endpoint⇄binding pairing, now in ONE place
  (`is_synthetic_endpoint_name` moved there too; `validation_structural` aliases it).
- The linter copy was DELETED rather than kept in sync — two copies of one security rule is the
  divergent-copy class.
- Docs: a new "A GET may not change state" subsection in `manual/best-practices.md` under Security
  (so `embedded_docs.ml` is regenerated — commit the two together, or `ci.sh` phase 5 fails by
  construction).

### Correction to this document's own sketch

The sketch below says the pairing rule needed a by-NAME mode. **It does not, and a by-name mode
would be a bug.** There is no surface syntax for naming an api endpoint — `parser.ml:4240` mints
`endpoint_N` for every one — and `Emit_racket.emit_api` re-attaches the BINDING KEY as the name of
the endpoint at that INDEX. Verified on emitted Racket: for

```tesl
api  { post "/create"; get "/read" }
server { endpoint_1 = mutate; endpoint_0 = readOnly }
```

the emitter produces `[endpoint_1 mutate]` on the POST route, so `mutate` serves POST /create and
the program is SAFE. Pairing is therefore strictly POSITIONAL (binding index ⇄ non-SSE endpoint
index), with SSE filtered out FIRST. The old lint's positional pairing was right; pairing by key
would have falsely rejected the program above. Both directions are pinned by tests.

### Tests

`compiler/test/test_get_no_mutate.ml` (15 checks): GET+dbWrite rejected / same handler under POST
clean / read-only GET clean / GET+dbRead clean; GET+emailCap rejected + POST control; a user
capability that `implies dbWrite`; a write one call away; an imported mutating handler; both
pairing directions plus an SSE-does-not-shift-the-pairing guard; telemetry-in-a-GET stays clean;
and two contract tests (SEC005 stays documented and names its whole closure; the forbidden set is
pinned). `test_security_lints.ml` now asserts the linter does NOT produce SEC005.

### Corpus churn (all pre-existing latent mutating GETs, each a real find)

The shipped `example/`/`tests/` corpus needed no change — the sweep in the analysis was right. Test
FIXTURES did: `test_email_integration.ml` (three email-sending endpoints were GET; migrated to POST
plus a `curl_post` helper) and `test_issues_40_41_42.ml` (four fixtures: a `dbWrite` `/seed`, a
`pubsub` `/send`, a `pubsub` `/x`, a `queueWrite` `/x`).

## Maintainers thoughts

Should we do this? This is good in principle but means that if someone would want to save a users request history for instance (for audit reasons or to auto save used filters or whatever) it wouldn't be possible using a get endpoint. The question is; how many "get" endpoints in a larger app does not change the state *at all*? I'm currently agnostic.

## Background

The session cookie ships with `SameSite=Lax` (`roadmap/completed/response_metadata_and_cookies.md`,
LANGUAGE-SPEC §21.8). Lax is the right default — Strict withholds the cookie on ordinary
top-level navigation, so following a link from email arrives as a phantom logout — but it has one
sharp edge: **the browser DOES send a Lax cookie on a cross-site top-level GET navigation.** So a
GET handler that mutates state is a CSRF hole: an attacker's page can navigate the victim's browser
to `GET /delete-account?...` and the session cookie rides along.

Every other CSRF vector is already closed by construction — Tesl's 415 on non-`application/json`
request bodies, no CORS headers on JSON routes, parameterized SQL — so a cross-site form or `fetch`
cannot reach a state-changing handler. The mutating-GET case is the **only** residual, and today the
defense is a convention the docs teach ("GET handlers do not mutate", lesson06 / lesson76 / the CSRF
note in best-practices), not a compiler-enforced rule. The author carries it.

The whole thesis of Tesl is that the compiler carries invariants like this, not the author. This
item turns the convention into a guarantee.

## Goal

A route declared `get "…"` whose handler's **capability closure** contains any write effect —
`dbWrite`, `queueWrite`, `pubsub`, or `emailCap` — is a compile error. Then `SameSite=Lax` is safe
by construction rather than by discipline, and the CSRF story has no "iff the author remembers"
clause.

Read-only GET is not a burden the language invents: it is HTTP's own semantics (GET is "safe" per
RFC 9110 §9.2.1), so this rule teaches the platform's rule rather than a Tesl-specific one.

## Sketch

- The machinery already exists. The capability system computes, per handler, the transitive
  capability set (`collect_needed_capabilities` in `validation_common.ml`; the `implies` closure).
  The write capabilities are the four named above (`tesl_stdlib_cap_map`), plus any user capability
  whose `implies` chain reaches one of them — the closure already resolves that.
- The route method is known at the api/server checking site (`get`/`post`/… in the `api` block).
  For a `get` route, intersect its handler's resolved capability closure with `{dbWrite; queueWrite;
  pubsub; emailCap}`; a non-empty intersection is the error.
- **Diagnostic quality is the point.** Name the offending capability and where it entered the
  closure ("`get \"/x\"` reaches `dbWrite` via `handler foo` → `fn bar requires [...]`"), and offer
  the two real fixes: make the route `post` (or the appropriate verb), or move the write out of the
  read path. A guided fix, in the house style.
- A new stable error code (SECxxx — this is a security rule, so it belongs with SEC001/SEC003), with
  `tesl explain` prose and a `manual` deep-link.

## Open questions

- **Other verbs.** HEAD is also "safe" and Tesl does not expose it; nothing to do. The rule is
  specifically about GET because GET is the one a Lax cookie rides cross-site.
- **`dbRead` in a GET is fine** (the common case — GET reads). Only the three write capabilities are
  forbidden. Confirm no legitimate GET needs `pubsub` (an SSE `subscribe` is a separate route shape,
  not a `get` handler returning a body — check the SSE surface does not trip this).
- **Telemetry / logging as "writes".** Telemetry is ungated and ambient by design and is NOT a
  state change a CSRF attacker cares about, so it is correctly out of scope. Email
  (`emailCap`) IS in the forbidden set (decided 2026-08-03): a GET that sends mail is a spam
  vector via the same cross-site navigation, so it is forbidden alongside the three write
  capabilities.
- **Cache is out of scope.** `cacheCap` has no read/write split in the capability map, so
  forbidding it would also forbid cache *reads* on GET — and populating a cache during a GET is
  response caching, the canonical benign read-path mutation. Correctly excluded.
- **Existing corpus.** Sweep `example/` and `tests/` for any `get` route whose handler writes; each
  is either a latent bug this catches (good) or a place the rule is too strict (informs the design).

## Verification bar

- A `get` route with a `dbWrite` handler fails to compile with the new code; the same handler under
  `post` compiles. Same for an `emailCap` handler.
- The error names the capability and the path by which the GET reaches it.
- The whole existing corpus still compiles (or each newly-rejected route is triaged and fixed).
- `./ci.sh` green.

## Related

- `roadmap/completed/response_metadata_and_cookies.md` — the SameSite=Lax decision and the CSRF note
  this closes the last gap in.
- LANGUAGE-SPEC §21.8 (the cookie), the SEC001/SEC003 lints (the security-code precedent),
  `validation_common.ml` (`collect_needed_capabilities`, `tesl_stdlib_cap_map`).
