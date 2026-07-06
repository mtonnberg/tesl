# GitHub #26 — runtime "ambiguous dot access" on a select-bound entity in a fn

**FIXED 2026-07-06.** `tesl check` passed but a field read off a `select`-bound
entity row inside a plain `fn` trapped at runtime (with rows present):
`dot: ambiguous dot access for field id; candidate record/entity types:
(Organization Project)`, 500ing the request. Route/api-tests that *return* the
entity list serialized fine (typed by return codec), so it slipped the suite and
only showed as a prod 500 (an `asTool` agent tool).

## Root cause

Three-layer trace:
- **Runtime** (`dsl/private/check-runtime.rkt:188` `tesl-dot/runtime` →
  `dsl/types.rkt` `field-access-ref`): with no type hint, the field getter is
  chosen by STRUCTURE. Entity runtime predicates (`dsl/sql.rkt`
  `entity-row-matches-fields?`) are **superset** checks, so a `Project`
  `{id,name,client}` row also satisfies `Organization {id,name}` → two
  candidates → ambiguous → raise. (Removing `Organization` leaves one → works,
  matching the report.)
- **Emitter** (`compiler/lib/emit_racket.ml` `EField`): a field read in a plain
  `fn` lowered to a bare `(tesl-dot/runtime p 'id)` — no type, structural.
- **Checker** (`compiler/lib/checker.ml:1673-1687`): ALREADY resolves
  `p : Project` (from `select p from Project` → `List Project`, `List.head` →
  `Maybe Project`, `Something p` binder → `Project`) and records it in
  `field_accesses` (`fa_record_type = "Project"`, keyed by the EField loc). The
  hint existed; it just wasn't threaded to the emit site.

## Fix (thread the checker type to the dot emit + 1-line runtime passthrough)

- `emit_racket.ml`: new `ctx.field_access_type_tbl` populated from the checker's
  `field_accesses` (via `check_module_with_metadata`, same mechanism as the
  lambda `expr_type_tbl`); both `EField` dot-emit sites (main + `emit_field_inner`)
  now emit `(tesl-dot/runtime p 'field 'TypeName)` when a record/entity type is
  known, else the unchanged 2-arg form (special fields / module-qualified /
  newtype `.value` carry no `field_accesses` entry, so are untouched).
- `dsl/private/check-runtime.rkt`: `tesl-dot/runtime` gains an optional 3rd arg
  `type-hint`; when present it OVERRIDES the structural fallback
  (`(or type-hint expected-type)`). Existing 2-arg call sites unchanged.

Chosen at the emitter layer because the runtime genuinely cannot disambiguate
structurally (both entities satisfy the superset predicate; an exact-field-set
predicate wouldn't help two entities with identical fields), while the checker
already has the exact declared type.

The **case-arm `Something p` symptom is the same root** (same EField emit; the
checker records the binder type) — covered by the one fix.

## Scope note

The hint is emitted for **every** field read the checker resolves to a
record/entity type, not only entity selects — a plain `r.width` now emits
`(tesl-dot/runtime r 'width 'Rectangle)`. This is deliberate and strictly more
correct (two *records* can also share fields and hit the same structural
ambiguity), and the typed getter is runtime-equivalent to the structural one for
records (verified: lesson03-records' 14 tests pass). It changed 28 committed
`.rkt` snapshots (lessons/examples/tests) — all mechanical (only the added
` 'Type` on `tesl-dot/runtime` lines); regenerated and diff-verified as
hint-only.

## Verification

- Regression: `test_emit.ml` "issue-26-ambiguous-dot" asserts the two-entity
  field read emits `(tesl-dot/runtime p 'id 'Project)` and no bare 2-arg dot.
- End-to-end: the issue's exact repro (two same-field entities, seed a Project
  row, `GET /first/Website`) now returns 200 — the api-test passes where it
  previously 500'd. (The repro's api-test also needed `dbWrite` for its seed
  `insert` — a test-cap gap in the repro, unrelated to the dot fix.)
- `./ci.sh` 13/13.

## NOT addressed — separate observation (needs its own repro)

The reporter also noted "a multi-row `select <Entity>` bound to a `let` in a
unit `test` block returns empty." Investigation judged this a SEPARATE root
(row *retrieval* / test data-source wiring in `dsl/sql.rkt` `in-memory-select-many`,
not the dot pathway) and could not prove it's the same class without the exact
failing test. If it recurs, file a dedicated item with that repro. `selectOne`/
equality selects are unaffected.
