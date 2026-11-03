# Lesson 94 — Strengthen a proof without replacing its column

`Revalidate` can add a field-local proof while retaining every historical proof.
It preserves the primitive value and its physical column. This is useful when a
schema already defines a stronger validation rule and a later release starts
requiring it on stored rows.

The live regression is the strengthening case in
[`test_migration_revalidate_postgres.ml`](../../compiler/test/test_migration_revalidate_postgres.ml).
It runs original old/current apps against PostgreSQL, including rejection,
repair, retained writes, Contract and restart. A second case combines the proof
change with removal of another field through `Legacy`.

## Preserve the old guarantee explicitly

The old field requires `Prior title`; the new field requires both proofs:

```tesl
title: String ::: Prior title && NonEmpty title
```

The existing `Prior` declaration and all producers of its evidence must remain
semantically identical. Retain the compiler-verified `Same` entries for the old
proof and its dependencies. The target-owned establish returns both proofs and
the exact input value:

```tesl
establish tryTitle(value: String) -> Maybe (v: String ::: Prior v && NonEmpty v) =
  if (value != "old-forbidden") && (value != "") then
    Something (value ::: Prior value && NonEmpty value)
  else
    Nothing
```

In the executable example this establish exists in both snapshots, alongside
the weaker `tryPrior`. Changing the field requirement does not change the
historical fact's producer closure. Adding or editing a producer can invalidate
`Same` even when the fact's name stays the same; the compiler checks the closure.

The migration uses the existing same-column rule:

```tesl
Note: Migrate convert [Revalidate title Schema.Notes.VCurrent.tryTitle]
```

Its forward function calls that establish on `old.title`. The `Something` arm
must put its proven binder into the new row's `title`; it cannot substitute a
different field, normalize the string, or discard the evidence. `Nothing`
returns `Reject`.

## What holds during the deployment window

- Old-valid rows that fail the additional proof reject and remain unfinished.
- Current writes carry both proofs, so their unchanged physical values still
  satisfy the old field's exact guarantee.
- An old write invalidates the row generation; a new reader validates it again.
- Lazy validation does not mark the row durably migrated.
- Rejected rows block Contract. Repair them through an admitted application,
  then rerun Contract to finish validation and retire the old version.
- No shadow column is introduced. Enforcement is explicitly `runtime-only`;
  this feature does not synthesize SQL CHECK constraints.

## Boundaries

The field must retain its non-key primitive type, codec and physical storage.
Every historical proof must appear in the target conjunction and have exact
verified `Same` evidence. Each predicate must refer only to this field.

Replacing a historical predicate, weakening/removing an old guarantee, changing
its producer closure, or changing a JSONB codec requires a different transition.
Use the retained-column path in [lesson 90](lesson90-changing-field-proofs.md)
for proof replacement and [lesson 88](lesson88-jsonb-adt-retype.md) for codec
changes. An appended fallback decoder alone does not authorize an in-place
rewrite or decoder pruning.
