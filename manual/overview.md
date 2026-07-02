# Tesl Overview

Tesl is a programming language for building robust web APIs without the infrastructure tax — where validation, auth, and effects are compile-time guarantees, and every typed function is available to AI agents as a tool.

Use `tesl help manual overview` to access this from the CLI.

---

> For the pitch — the problem Tesl solves, who it's for, and the non-goals — see the
> [README](../README.md). This overview owns the one-screen *concept* explanation; the precise
> semantics live in [`LANGUAGE-SPEC.md` §6-7](../LANGUAGE-SPEC.md), and the full feature-by-feature
> walkthrough is the [guided tour](tour.md).

## The core idea: validated values carry their proof

In most web frameworks you validate data at the boundary and then... hope. Validated data has the
same type as unvalidated data, so nothing stops it from being mixed up, passed through layers without
proof it was checked, or reaching a function deep in the call stack that skips the check. Tesl closes
that gap with a **GDP-inspired proof system**, in three moves.

### 1. Validation stamps the value

```tesl
check isValidTitle(title: String) -> title: String ::: ValidTitle title =
  if 3 <= String.length(title) && String.length(title) <= 120 then
    ok title ::: ValidTitle title  # ✅ value is now "stamped" as valid
  else
    fail 400 "Title must be between 3 and 120 characters"
```

The `:::` annotation doesn't just validate — it **annotates** the value with a proof that it passed
validation. That proof is carried in the type signature wherever the value travels.

### 2. Proofs flow through the type system

```tesl
# The proof flows automatically through function calls, visible in the signature
handler createTodo(title: String ::: ValidTitle title) -> Todo ? FromDb (Id == todo.id)
  requires [dbWrite, time] =
  # title is guaranteed valid here — nothing to re-check
  insert Todo { id: generateId(), title: title, completed: false, createdAt: nowMillis() }
```

### 3. Missing proofs are compile-time errors

```tesl
# This won't compile: title has no proof
handler createTodoBad(title: String) -> Todo ? FromDb (Id == todo.id)
  requires [dbWrite, time] =
  # ❌ ERROR: cannot find proof for ValidTitle title
  insert Todo { id: generateId(), title: title, completed: false, createdAt: nowMillis() }
```

The compiler ensures that proofs are always present where needed.

---

## Core Principles

### ✅ Validate Once at the Boundary

Check data **once** when it enters your system, then carry the proof throughout. No need to re-validate at every layer.

### ✅ Make Auth Requirements Explicit

Authentication and authorization requirements are **visible in type signatures**, not hidden in middleware.

### ✅ Make Effects Explicit

Database access, queue operations, and other effects are **capability-governed**. Functions declare what they can do.

### ✅ Make Invalid States Hard to Express

The type system prevents many common bugs at compile time. If it compiles, it's likely correct.

### ✅ Proofs Should Be Easy to Work With

While Tesl is inspired by formal methods (GDP - Ghosts of Departed Proofs), it's designed to feel natural and productive for working developers.

---

## Quick Example

```tesl
# Define a validated type
check isValidEmail(email: String) -> email: String ::: ValidEmail email =
  if String.contains email "@" then
    ok email ::: ValidEmail email
  else
    fail 400 "Invalid email format"

# Use it in a handler
entity User table "users" primaryKey id {
  id: String
  email: String ::: ValidEmail email
  createdAt: PosixMillis
}

handler createUser(email: String ::: ValidEmail email) -> User ? FromDb (Id == user.id)
  requires [dbWrite, time] =
  # email is guaranteed to be valid here
  # the proof ValidEmail email is automatically available
  insert User { id: generateId(), email: email, createdAt: nowMillis() }
```

---

## Architecture

Tesl's architecture is designed for simplicity and reliability:

```
┌─────────────────────────────────────────────────────────────┐
│                    .tesl Language (Surface)                    │
│  - Clean, readable syntax for API development                 │
│  - Proof annotations (:::) for validation                     │
│  - Explicit capabilities and effects                          │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                   Compiler (OCaml)                              │
│  - Parses .tesl files                                           │
│  - Type checks with proof verification                         │
│  - Lints for style and best practices                           │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                   Runtime (Racket)                               │
│  - Executes compiled code                                      │
│  - Provides database, queue, and pub/sub support                │
│  - Proofs are erased before it runs (see proof cost model)       │
└─────────────────────────────────────────────────────────────┘
```

**Proof cost model:** Proofs are **zero-cost by default** — erased after type-checking in release and
`--debug` alike, so by the time your code runs there is no wrapper, struct, or allocation. The full
per-feature breakdown is single-sourced in the canonical
[proof cost model](best-practices.md#proof-cost-model).

---

## Feature Set

See the README for status and the roadmap for what's planned.

---

## Who Should Use Tesl?

Tesl is for productive web developers (TypeScript, C#, Java, Kotlin) who want API-shaped guarantees
to be the path of least resistance — and, since it is **beta**, not yet for systems that need
stability guarantees or extensive third-party library support. See [Who is Tesl for?](../README.md)
and the [beta status](../README.md) notes in the README for the full framing.

---

## Getting Started

1. **Install Tesl** — one command via Nix; see [INSTALL.md](../INSTALL.md) for all options
   (home-manager, NixOS, editor setup):
   ```bash
   nix profile install github:mtonnberg/tesl
   ```

2. **Try an example**:
   ```bash
   tesl validate example/todo-api.tesl
   tesl run example/todo-api.tesl
   ```

3. **Learn the language**:
   - Follow the [Getting Started guide](GETTING-STARTED.md) to build your first API
   - Read the [guided feature tour](tour.md) to see every feature in one pass
   - Explore [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) for the formal specification
   - Work through the [examples](examples.md) and [best practices](best-practices.md)

---

## See Also

- [Manual Index](MANUAL.md) - Back to the main manual
- [Guided Feature Tour](tour.md) - The long-form language walkthrough
- [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) - Formal language specification
- [Examples](examples.md) - Complete list of example files
- [Best Practices](best-practices.md) - Recommended patterns and conventions
- [INSTALL.md](../INSTALL.md) - Installation instructions
- [README.md](../README.md) - Project overview
