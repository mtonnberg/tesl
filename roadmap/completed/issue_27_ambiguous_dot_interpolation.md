# GitHub #27 — #26 fix incomplete: ambiguous dot in string interpolation

**FIXED 2026-07-06.** #26 (ambiguous-dot on a shared field read) was fixed for
the `++`/binop and direct paths, but reading a shared field name inside a
**string interpolation** (`"${p.name}"`) still trapped at runtime:
`dot: ambiguous dot access for field name; candidate record/entity types:
(Org Proj)`.

## What the repro actually exercised

The reporter's minimized repro read the field via `acc ++ p.name ++ "\n"` (a
binop), which #26 already covers — that path emits the hinted
`(tesl-dot/runtime p 'name 'Proj)` and resolves correctly (verified: with the
seed's `time`/`dbWrite` caps supplied, the handler returns `"Solo\n"`). The
repro's api-test as written also fails earlier on a seed capability gap
(`nowMillis()` needs `time`, `insert` needs `dbWrite`, but it declares only
`[rSvc]`) — unrelated to the dot bug.

The **real** trigger is string interpolation. `"${p.name}"` on a typed entity
param, with `Org`/`Proj` sharing `name`, reproduces the exact ambiguous-dot trap.

## Root cause

`emit_racket.ml`'s interpolation emitter (`emit_interp`) had a special case for
`${name.field}` in a function context that emitted bare dot-notation
`(raw-value name.field)` — bypassing the unified `EField` emitter and its #26
type hint. Bare dot-notation resolves structurally at runtime → ambiguous across
entities sharing the field.

## Fix

Deleted that interpolation special case so an interpolated field read falls
through to `emit_expr` — the same `EField` path #26 hardened, which threads the
checker's record/entity type into `(tesl-dot/runtime obj 'field 'Type)`. Special
request fields (`req.status`/…) still lower to dot-notation via `emit_expr`'s own
special-field branch, so their behavior is unchanged.

## Verification

- Regression: `test_emit.ml` "interpolated shared field read emits typed dot
  hint (#27)" — asserts `${p.name}`/`${p.id}` emit `(tesl-dot/runtime p 'field
  'Proj)` and no bare `(raw-value p.field)`.
- End-to-end: the repro with `addLine` rewritten to `"${acc}${p.name}\n"` traps
  before the fix, passes after (handler 200).
- Blast radius: 1 committed snapshot changed (`lesson12-records-with-proofs.rkt`),
  mechanical (interpolated record-field reads now hinted); regenerated.
- `./ci.sh` 13/13.

## Note

Interpolation was the last un-hinted field-read position; `++`/binop, direct
`let`, case-arm binders (#26) and interpolation (#27) now all route through the
one hinted `EField` emitter. If another un-hinted position surfaces, the fix is
the same: route it through `emit_expr`'s `EField` rather than emitting
dot-notation directly.
