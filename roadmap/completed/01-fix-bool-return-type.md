# Fix Bool: Canonical Spelling and Import Requirement

## Context

This item should be read as a surface-language coherence change for the current compiler and tooling stack.

The current state is:

- the OCaml compiler is already the active frontend
- the editor/tooling stack now sits on top of that compiler
- Tesl is trying to present one explicit, unsurprising public surface

That means this item is no longer about waiting for a future rewrite to make the rule worth implementing. It is about removing a visible language inconsistency early enough that later diagnostics, examples, tutorials, and tooling all teach the canonical rule instead of preserving aliases by accident.

---

## Goal

Make `Bool`, `True`, and `False` consistent with the rest of Tesl.

The intended rule is:

- the type has one canonical spelling: `Bool`
- the constructors have one canonical spelling: `True` and `False`
- `Bool` comes from `Tesl.Prelude`, like other named types, rather than existing as a silent special case

This should be one of the earliest visible coherence wins for the language.

---

## Current problems

### 1. Wrong-case aliases are silently accepted

`bool`, `Boolean`, `true`, and `false` all compile today. This teaches the wrong rule.

Tesl's convention is otherwise uniform:

- type names are `UpperCamelCase`
- constructors are `UpperCamelCase`

A newcomer who writes:

```tesl
type Direction = North | South | East | West
```

learns the capitalisation rule immediately. If they then write:

```tesl
fn isAllowed(flag: bool) -> bool =
  if flag == true then ...
```

and it works, Tesl is teaching an exception it does not want to keep.

### 2. `Bool` is still a special case in the language model

Every other named type in Tesl must either be declared locally or imported explicitly. `Bool` should follow the same rule instead of remaining an invisible builtin exception.

Making it an explicit `Tesl.Prelude` import makes the module graph more honest and the language easier to learn.

---

## What changes

| Currently accepted | Canonical form after |
|--------------------|----------------------|
| `bool` | `Bool` |
| `Boolean` | `Bool` |
| `true` | `True` |
| `false` | `False` |
| implicit builtin | `import Tesl.Prelude exposing [Bool(..)]` |

---

## Import decision

`Bool` becomes a first-class ADT exported from `Tesl.Prelude` and imported explicitly:

```tesl
import Tesl.Prelude exposing [Bool(..)]
```

The `(..)` import brings in both constructors (`True` and `False`) in the same style used for other ADTs.

`Int`, `String`, and `Float` remain zero-import primitives. `Bool` should not be treated as the same kind of implicit primitive; it behaves like an ordinary two-constructor ADT and should read that way in user code.

---

## Error messages

When `bool` is used as a type:

```
error: unknown type `bool`
  hint: the boolean type is `Bool` — all Tesl type names are UpperCamelCase
  hint: add `import Tesl.Prelude exposing [Bool(..)]` to use it
```

When `true` or `false` is used as a value:

```
error: unknown name `true`
  hint: boolean values are `True` and `False` — all Tesl constructors are UpperCamelCase
```

The point is not only rejection. The point is to teach the real rule clearly.

---

## Why this belongs early in `next/`

This is a breaking change for code using `true` / `false` / `bool`, so examples and lessons need a sweep before it lands.

But it should still happen early in the `next/` sequence because it affects the public language surface directly. If Item 01 lands early:

- examples teach the canonical forms
- diagnostics and future fix suggestions teach the canonical forms
- later tooling work does not need to preserve or explain legacy aliases

In other words: this is small in implementation size, but high leverage for language coherence.

---

## Relationship to other roadmap items

### `roadmap/next/04-add-bidirectional-type-checking.md`

Better diagnostics from Item 04 should report the canonical language forms, not legacy aliases. Item 01 therefore improves the vocabulary that later checker improvements will teach.

### `roadmap/next/03-ir-1-semantic-layer.md`

IR-1 should model the canonical language surface rather than a mixture of canonical and legacy spellings. Landing Item 01 early keeps retained semantic data and later semantic queries aligned with the intended public language.

### `roadmap/next/05-improved-tooling.md`

Tooling should guide users toward the final surface language. That includes diagnostics, hover text, code actions, and any future compiler-generated fixes. Item 01 reduces the chance of tooling perpetuating legacy forms.

---

## Scope

- compiler: reject `bool`, `Boolean`, `true`, and `false` with helpful errors
- `Tesl.Prelude`: export `Bool`, `True`, and `False`
- examples and lessons: add `import Tesl.Prelude exposing [Bool(..)]` and update old spellings
- `LANGUAGE-SPEC.md`: document only `Bool`, `True`, `False`, and the `Tesl.Prelude` import rule
- tests: update any cases that intentionally used the old aliases

---

## Success criteria

- `bool` and `Boolean` as type names produce a compile error with a helpful hint
- `true` and `false` as expressions produce a compile error with a helpful hint
- `Bool` without the `Tesl.Prelude` import produces an unknown-type style error
- shipped examples and lessons use `Bool`, `True`, and `False`
- `LANGUAGE-SPEC.md` documents only the canonical forms
- tests that relied on the old aliases are updated
