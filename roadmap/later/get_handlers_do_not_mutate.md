# Enforce "GET handlers do not mutate" at compile time

> **Status:** Next · **Effort:** S–M. A checker rule over the api/server surface, no new syntax,
> no runtime change.

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
`dbWrite`, `queueWrite`, or `pubsub` — is a compile error. Then `SameSite=Lax` is safe by
construction rather than by discipline, and the CSRF story has no "iff the author remembers" clause.

Read-only GET is not a burden the language invents: it is HTTP's own semantics (GET is "safe" per
RFC 9110 §9.2.1), so this rule teaches the platform's rule rather than a Tesl-specific one.

## Sketch

- The machinery already exists. The capability system computes, per handler, the transitive
  capability set (`collect_needed_capabilities` in `validation_common.ml`; the `implies` closure).
  The write capabilities are the three named above (`tesl_stdlib_cap_map`), plus any user capability
  whose `implies` chain reaches one of them — the closure already resolves that.
- The route method is known at the api/server checking site (`get`/`post`/… in the `api` block).
  For a `get` route, intersect its handler's resolved capability closure with `{dbWrite; queueWrite;
  pubsub}`; a non-empty intersection is the error.
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
  (`emailCap`) IS a side effect a GET should arguably not perform — decide whether `emailCap` joins
  the forbidden set or stays out (leaning: add it; a GET that sends mail is a spam vector via the
  same cross-site navigation).
- **Existing corpus.** Sweep `example/` and `tests/` for any `get` route whose handler writes; each
  is either a latent bug this catches (good) or a place the rule is too strict (informs the design).

## Verification bar

- A `get` route with a `dbWrite` handler fails to compile with the new code; the same handler under
  `post` compiles.
- The error names the capability and the path by which the GET reaches it.
- The whole existing corpus still compiles (or each newly-rejected route is triaged and fixed).
- `./ci.sh` green.

## Related

- `roadmap/completed/response_metadata_and_cookies.md` — the SameSite=Lax decision and the CSRF note
  this closes the last gap in.
- LANGUAGE-SPEC §21.8 (the cookie), the SEC001/SEC003 lints (the security-code precedent),
  `validation_common.ml` (`collect_needed_capabilities`, `tesl_stdlib_cap_map`).
