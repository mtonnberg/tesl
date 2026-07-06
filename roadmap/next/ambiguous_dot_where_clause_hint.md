# Ambiguous-dot: SQL where-clause operand field reads are not type-hinted

The systemic follow-up to [[issue_26_ambiguous_dot]] / [[issue_27_ambiguous_dot_interpolation]].
After unifying every EXPRESSION-level field-read emit path through one hinted
emitter (`emit_field_dot`, 2026-07-06 — see below), one field-read context still
emits an **un-hinted** `(tesl-dot/runtime obj 'field)` and so can trap
("ambiguous dot access") on a field name shared across entities: **operands
inside a SQL `where` clause**.

## Repro (emit is bare)

```tesl
entity Org  table "o" primaryKey id { id: String  name: String }
entity Proj table "p" primaryKey id { id: String  name: String }
fn find(pr: Proj) -> Maybe Org requires [dbRead] =
  selectOne o from Org where o.name == pr.name    -- pr.name emits (tesl-dot/runtime pr 'name), NO hint
```

`pr` is a select-bound `Proj` row; a Proj row `{id,name}` superset-matches
`Org {id,name}`, so at runtime the structural resolver sees candidates
`(Org Proj)` for `name` and traps. `tesl check` passes; it 500s with rows. This
is a **live** instance (same shape as #26/#27), just in a less-common position.

## Confirmed as the real #27 cause (2026-07-06)

The reporter's full app (`bug_repro.tesl`) reads shared fields (`orgId`,
`projectId`, `userId` — declared by many entities) in `where` operands off typed
params, e.g. `selectSum e.minutes from TimeEntry where e.orgId == r.orgId && …`
inside a fold helper `addExternalCost(acc, r: CostRate)`. `r.orgId` emits the
bare `(tesl-dot/runtime r 'orgId)` and traps at runtime on the shared field.
This — NOT the `++ p.name` minimal snippet (already hinted) — is the actual #27
trap. Closing it requires the checker fix below.

## Attempted fix + why it needs more care (2026-07-06)

First attempt: record `field_accesses` for the where-operand value reads by
inferring them in the select-typing arm of `infer_expr`
(`EVar {name="select"|"selectOne"|…}` at `checker.ml:~2000`). It did NOT fire:
a select **with a where clause** is not `EVar "select"`-headed in the surface
AST — a compound `where A && B` is `EBinop BAnd`-headed (`checker.ml:1976`,
routed through `classify_lowered_query`), and a single `where a == b` is
`EBinop BEq`-headed. Both are typed by `classify_lowered_query`
(`checker.ml:1454`), which returns the entity type structurally and **never
infers the where-operand sub-expressions** — so no `field_accesses` are
recorded. Reverted the arm-2000 hook as dead for this case.

The correct fix must hook the **`classify_lowered_query` / EBinop-headed select
path** (where `ctx` is available, e.g. at `checker.ml:1976`): identify the
select's binder + entity from the lowered tree, bind the binder to the entity
type, and infer (for `field_accesses` side-effect only, errors rolled back) the
**value side** of each comparison — inferring the `EField` nodes directly, NOT
the whole `col == value` (which re-enters `classify_lowered_query` and skips the
value side). A generic "walk the select expr, infer every `EField` in a
binder-bound ctx" is the shape; the care is (a) extracting binder/entity from
the tangled EBinop-headed AST, and (b) not perturbing inference of valid
programs (snapshot/restore `ctx.errors`).

## Root cause — checker-side, not emit-side

The emit path is fine: `emit_sql_clause`'s `SqlPred` operand goes through
`emit_expr` (`emit_racket.ml:1284`), which consults the hint table. The gap is
that the **checker never records a `field_accesses` entry** for a field read that
lives inside a SQL `where`-clause operand — SQL clauses are type-checked by the
SQL-validation path, which does not run the operand through the `infer_expr`
`EField` arm that populates `ctx.field_accesses` (`checker.ml:1683`). No entry →
`field_access_type_tbl` miss → `emit_field_dot` emits the bare 2-arg form.

## Fix

Make the SQL where-clause (and, check: `select`/`insert`/`update` value
positions) operand type-checking record `field_accesses` for the field reads it
contains — i.e. route those operands through the same `infer_expr` path that
records `{ fa_loc; fa_field; fa_record_type }`, or call a small "record field
accesses in this expr" walk over each operand. Then `emit_field_dot` picks up
the hint automatically (no emit change needed). Verify the column side
(`entity-field-ref Org 'name`) is unaffected — only the VALUE operand needs it.

## Why not fixed in the 2026-07-06 pass

The expr-level unification (below) closed every field-read emit path that goes
through `emit_expr`; this one is a distinct CHECKER omission (field_accesses not
populated for SQL-clause operands), a more surgical change to the SQL validator
that wants its own verification. The shipped examples that hit this
(`ai-conversation-service` `requestUser.id`, `kanel` `m.orgId`) are currently
SAFE — their operand values do not superset-match a second entity (`orgId` is
unique; a `Consumer`/`User` auth value carries `role`, so it matches only its own
type) — so it is latent there, but the repro above is a genuine live trap.

## Related closure already landed (2026-07-06)

Field-read lowering was duplicated across 5 emit paths (main `EField`, nested
`emit_field_inner`, `emit_raw_value`, the `has_forall_return` return-tail, and
string interpolation). All now route through a single `emit_field_dot` helper
that threads the checker's type hint, so a bare un-hinted dot can no longer be
emitted from any expression position. This where-clause item is the remaining
non-expression position.

## Verification

Red→green: the repro's `selectOne o from Org where o.name == pr.name` must emit
`(tesl-dot/runtime pr 'name 'Proj)` and a `tesl test` seeding a Proj row must not
trap. `./ci.sh` 13/13. Consider a corpus sweep asserting NO bare 2-arg
`tesl-dot/runtime … 'field)` is emitted for a field that ≥2 entities/records
share — the by-construction guard for this whole class.
