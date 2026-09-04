# Decide `JobResult`'s shape, and whether it can be matched

## What

`JobResult` is described three times in the codebase and two of the descriptions disagree about
its arity. Decide which is correct, make the others follow, and decide separately whether a
`case` over one is allowed at all.

## The three descriptions

| Where | Says |
|---|---|
| `tesl/api-test.rkt:60` | `(define-adt (JobResult job error) [JobOk job] [JobFailed job error])` — **two** type parameters, the error polymorphic |
| `compiler/lib/emit_go.ml:10621` | `adt_params = ["job", "Payload"]`, and `JobFailed`'s fields are `["job", TParam "Payload"; "error", TString]` — **one** type parameter, the error concretely a `String` |
| `compiler/lib/type_system.ml:1605,1864` | only the NAMES (`"Tesl.ApiTest", "JobResult", ["JobOk"; "JobFailed"]`) — no signatures at all |

Nothing in the corpus writes the type. `: JobResult` and `-> JobResult` appear nowhere, so
there is no source evidence to break the tie.

Two data points lean toward the Go emitter's reading: `expectJobFailed` returns
`(JobFailed-error result)` (`tesl/api-test.rkt:341`) and every corpus use treats that as a
String, and the Go runtime stores it as one. But that is the shape of the ACCESSOR, not proof
about the type.

## Why it matters now

`validation_common.ml`'s `builtin_ctor_info` — the single constructor table the nested-pattern
exhaustiveness check reads, and the one `DeleteResult` was just added to — has no rows for
`JobResult`, deliberately. A row needs field types AND a result type, so writing one means
picking an arity.

Picking wrong does not error. `ctor_field_types_for_scrutinee` falls back silently:

```ocaml
| Some subst -> Some (List.map (apply_type_subst subst) field_types)
| None       -> Some field_types          (* unification failed; uninstantiated types used *)
```

So a speculative row would quietly check exhaustiveness against the wrong field types — the
same failure class the `DeleteResult` fix just closed, with the sign flipped: there the missing
table REJECTED a total match, here a guessed table would silently accept or reject on wrong
information.

## Why it is not urgent

A `case` over a `JobResult` cannot be written today. With `JobResult(..)`, `JobOk` and
`JobFailed` all imported:

```
error[T001]: unknown constructor: JobOk — `JobOk` is already imported from `Tesl.ApiTest`,
             but the import does not make it usable here
```

The only consumers are `expectJobOk` / `expectJobFailed`, which the emitters special-case as
verbs rather than resolving as constructors, and that is all the corpus uses. So the missing
row has no program shape to check. It acquires one the day matching is allowed.

## Questions to settle

1. **Is the error polymorphic or always a String?** Racket says polymorphic; the Go emitter and
   every use say String. If it is always a String, `(define-adt (JobResult job) …)` is the
   simpler truth and Racket is the one that should change.
2. **Should `case` over a `JobResult` be allowed?** The two accessors may be the intended whole
   surface — `expectJobOk` traps with a message naming the job, which a `case` arm cannot do as
   well. If they are, say so in the spec and the T001 above becomes intended behaviour rather
   than an accident.
3. **If matching is allowed, how is the type written?** `JobResult Payload` or
   `JobResult Payload Error`. This is what the table row records.

## Scope once decided

`tesl/api-test.rkt` (if the arity changes), `validation_common.ml` (the rows),
`emit_go.ml:10621` (must match), `type_system.ml` (signatures, not just names), and
`LANGUAGE-SPEC.md`. If matching is allowed, the emitters' `expectJobOk`/`expectJobFailed`
special cases stay as they are — they are a convenience over the same value, not a substitute.

## Related

The same "one description in several places" shape as the `DeleteResult` exhaustiveness bug
fixed 2026-08-17, and the reason that fix collapsed two constructor tables into one. This is
the third place the same information lives.
