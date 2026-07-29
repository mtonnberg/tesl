# Interop policy + docs (how to answer "I want FFI") — COMPLETED

> **Status:** COMPLETED 2026-07-29 · **Effort:** S (docs + policy only) · **Delivered:** all six
> deliverables. No language surface, no compiler code, no runtime code changed — the only
> non-prose diff is the `dune build`-promoted `compiler/lib/embedded_docs.ml` snapshot.

Carved out of `roadmap/discarded/using_queues_for_ffi.md` (discarded 2026-07-29). That item
analysed FFI and declined it — again. This item wrote down the resulting policy so the
question stops being re-litigated from scratch, and so the patterns people *should* use are
documented instead of rediscovered.

## What shipped, and where

| # | Deliverable | Landed in |
|---|---|---|
| 1 | The triage rule | `manual/best-practices.md` → *Interop and Foreign Work* → **Triage: "Tesl can't do X, give me an escape hatch"** (3-row table + the `tesl/jwt.rkt` precedent) |
| 2 | The initiator rule | same section → **Tesl always initiates** (comparison table + the `numberOfWorkers` starvation cost) |
| 3 | The foreign-work recipe | same section → **The foreign-work recipe**; the lesson half was already done (`example/learn/lesson74-interop-patterns.tesl`) and is referenced, not repeated |
| 4 | `FromQueue` is provenance, not validity | `LANGUAGE-SPEC.md` §11.17, two new paragraphs after the 2-arg-pattern note |
| 5 | External `tesl_jobs` consumer not supported | `manual/best-practices.md` → **Never point an external worker at `tesl_jobs`**, plus a spec-side statement in `LANGUAGE-SPEC.md` §11.15 |
| 6 | Keep the audit line, make it precise | `roadmap/discarded/security_hardening_audit.md` — the "Surface notes (narrowing factors)" paragraph, rewritten in place (same starting line) |
| + | Discoverability (not in the original list) | `manual/FAQ.md` → *"Can I call C, Rust, or Python from Tesl? Is there an FFI?"* under Language Questions, pointing at the policy section |

`manual/best-practices.md` gained one new top-level heading, `## Interop and Foreign Work`,
inserted between *Money and Units* and *Testing*, with a Table-of-Contents entry (Testing and
Performance renumbered 12/13). **No contracted anchor was moved, renamed or added** —
`manual/anchors.md` is unchanged, and the new heading is deliberately *not* registered as a
stability contract. It is cited in prose from `LANGUAGE-SPEC.md` and `FAQ.md` as
`best-practices.md#interop-and-foreign-work`, which resolves by the ordinary slug rule.

## Content notes worth keeping

- **The triage table's spine is "data boundary vs. host-value boundary."** A result that
  arrives as JSON crosses `jsexpr->typed-value` and cannot forge a proof; a result that
  arrives as a host value bypasses every check. That is why `foreign fn` is categorically
  different from "call a service", and why it stays declined.
- **`jwt` is the worked precedent for the maintainer-side escape hatch.** `tesl/jwt.rkt` binds
  libcrypto's HMAC-SHA256 through Racket's FFI and exposes exactly three functions under the
  `jwt` capability. Host FFI is allowed inside the trusted core; it is never user-facing.
- **The default's real cost is now documented.** A blocked outbound call pins one of the
  queue's `numberOfWorkers` threads (`tesl/queue.rkt:1152` spawns exactly `concurrency` worker
  threads, each blocking in the worker body), and there is still no outbound timeout, so a
  hung upstream starves *all* background work — including unrelated job types. Mitigations
  given: more workers, or a dedicated queue. Tracked in
  `primitive_gaps_and_outbound_hardening.md`.
- **The `FromQueue` strength is now on the record.** `FromQueue` is provenance only; what makes
  the boundary trustworthy is the decode. A job payload goes through `jsexpr->typed-value`
  (`tesl/queue.rkt:293`) and is fail-closed on proofs — a `:::`-annotated record field cannot
  decode without a registered `#:check` (`dsl/types.rkt:1394`, `coerce-record-field-value` at
  `:974`). Queue payloads are validated as strictly as HTTP request bodies; database rows read
  back are not (`vector->entity-row`, `dsl/sql.rkt:1834`). That asymmetry is the whole argument
  against an external `tesl_jobs` consumer.

## Citation audit

Every `file:line` in the original item was re-verified against the tree before being written
into prose. All of them still pointed where they claimed:

| Citation | Verdict |
|---|---|
| `LANGUAGE-SPEC.md:1074-1082` (§11.17 `FromQueue`) | correct — §11.17 heading at `:1062`, the worker example at `:1074-1078`, the 2-arg-pattern paragraph at `:1082` |
| `LANGUAGE-SPEC.md:1024` (`capability emailWrite implies queueWrite`) | correct, exact line |
| `LANGUAGE-SPEC.md:1287-1299` (agent resume-after) | correct, exact span; it sits inside §11.18 (AI agents), so the prose cites §11.18 rather than the line range |
| `dsl/types.rkt:1394` (proof-annotated field fails closed) | correct |
| `dsl/types.rkt:974` (`coerce-record-field-value`) | correct, exact definition line |
| `dsl/sql.rkt:2005` (`ensure-queue-tables!`, the `tesl_jobs` DDL) | correct; DDL confirms no `result` column |
| `dsl/sql.rkt:1834` (`vector->entity-row`) | correct, and confirmed it never calls `coerce-record-field-value` |
| `tesl/queue.rkt:21-22` (in-memory fallback with no PG) | correct |
| `roadmap/discarded/security_hardening_audit.md:167` (surface note) | correct; the rewrite starts on the same line, so the citation still lands |

One thing the item did not cite and the prose now does: `tesl/queue.rkt:293`
(`deserialize-job-payload` → `jsexpr->typed-value`), which is the concrete evidence that job
payloads cross the validating decoder.

## Not done (deliberately)

- No new contracted anchor in `manual/anchors.md`. Adding one is a separate deliberate act
  (heading + table row + a case in `manual/tests/test_embedded_docs.ml`); nothing cites the new
  section from compiler diagnostics yet, so there is no contract to make.
- No new language surface, declaration, or stdlib module (see
  `primitive_gaps_and_outbound_hardening.md` for the real gaps).
- No supported external queue-consumer protocol. If that is ever wanted it is a project —
  versioned view over `tesl_jobs`, a locked-down PG role, a published payload contract.

## Verification

- `dune build` (with `TESL_REPO_ROOT` pointed at the worktree) — clean; re-promoted
  `compiler/lib/embedded_docs.ml`.
- `dune test` — green (includes `manual/tests/test_embedded_docs.ml`, which fails the build if
  any contracted anchor stops resolving, and `test_spec_anchors.ml` for the spec §-numbers).
- `./compile-examples.sh` (→ `ci.sh`, 15 phases) — **13/15 OK**, including phase 4
  (embedded-docs sync: the baked copy matches the source tree) and phase 7 (exact-match `.rkt`
  snapshots: the integration snapshot is byte-exact). Phases 13 and 14
  (`tests/dap-attach-value-tree-smoke.rkt`; `tests/all.rkt`, "connect-database: expected a
  database-spec") fail — **pre-existing**, reproduced identically on a clean tree with this
  work stashed, and untouchable by a docs-only change.
- `tesl help manual best-practices#interop-and-foreign-work` resolves and prints exactly the
  new section, so the CLI anchor path works without registering a stability contract.

## Related

- `roadmap/discarded/using_queues_for_ffi.md` — the analysis this was carved from
- `roadmap/next/primitive_gaps_and_outbound_hardening.md` — the code half (outbound timeout, regex)
- `roadmap/discarded/lift-remaining-stdlib-and-foreign-fn.md` — the original `foreign fn` decline
- `example/learn/lesson74-interop-patterns.tesl` — the lesson half of deliverable 3
