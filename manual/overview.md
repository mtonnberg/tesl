# Tesl Overview

Tesl is a high-velocity programming language for building unbreakable, production-ready web APIs without the infrastructure tax.

Use `tesl help manual overview` to access this from the CLI.

---

## The Problem Tesl Solves

In most web frameworks, you validate data at the boundary and then... hope. The validated data is still the same type as unvalidated data, so nothing prevents it from:
- Getting mixed up with unvalidated data
- Being passed through multiple layers without proof it was validated
- Being received by functions deep in the call stack that skip the check

This leads to:
- **Defensive boilerplate everywhere** - repeated validation checks
- **Logic bugs** - forgetting to validate or re-validate
- **Security vulnerabilities** - unvalidated data reaching sensitive operations
- **Maintenance nightmares** - changing validation requires changes throughout the codebase

---

## How Tesl is Different

Tesl solves these problems through a **GDP-inspired proof system**:

### 1. Validation Stamps the Value

```tesl
check isValidTitle(title: String) -> title: String ::: ValidTitle title =
  if 3 <= String.length(title) && String.length(title) <= 120 then
    ok title ::: ValidTitle title  -- ✅ Value is now "stamped" as valid
  else
    fail 400 "Title must be between 3 and 120 characters"
```

The `:::` annotation doesn't just validate — it **annotates** the value with a proof that it passed validation. That proof is carried in the type signature wherever the value travels.

### 2. Proofs Flow Through the Type System

```tesl
-- The proof flows automatically through function calls
fn createTodo(title: String ::: ValidTitle title) -> Todo ::: TodoValid =
  let todo = { id: generateId(), title: title, completed: false } in
  -- todo automatically carries the ValidTitle proof for its title field
  todo ::: TodoValid

-- The proof is visible in the type signature
handler createTodo(title: String ::: ValidTitle title) -> Todo ::: TodoValid
  requires [] =
  let todo = { id: generateId(), title: title, completed: false } in
  ok todo ::: TodoValid
```

### 3. Missing Proofs are Compile-Time Errors

```tesl
-- This won't compile because title has no proof
handler createTodo(title: String) -> Todo =
  let todo = { id: generateId(), title: title, completed: false } in
  -- ❌ ERROR: Cannot find proof for ValidTitle title
  insert Todo todo
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
-- Define a validated type
check isValidEmail(email: String) -> email: String ::: ValidEmail email =
  if String.contains email "@" then
    ok email ::: ValidEmail email
  else
    fail 400 "Invalid email format"

-- Use it in a handler
entity User table "users" primaryKey id {
  id: String
  email: String ::: ValidEmail email
  createdAt: PosixMillis
}

handler createUser(email: String ::: ValidEmail email) -> User ? FromDb (Id == user.id)
  requires [db, time] =
  -- email is guaranteed to be valid here
  -- The proof ValidEmail email is automatically available
  insert User { id: generateId(), email: email, createdAt: nowMillis() }
```

---

## What Makes Tesl Special

### For Developers

- **Less boilerplate** - No need to repeatedly validate data
- **Fewer bugs** - Type system catches many errors at compile time
- **Fearless refactoring** - Proofs flow through the type system, so refactoring preserves guarantees
- **Clear code** - What's validated and what's not is always visible

### For Teams

- **Consistent quality** - Everyone benefits from the type system
- **Faster onboarding** - New team members can't accidentally break things
- **Better code reviews** - Less time spent checking for missing validations
- **Confident deployments** - If it compiles and tests pass, it's likely correct

### For Businesses

- **Faster time to market** - Less boilerplate means faster development
- **Fewer production bugs** - Type system prevents many classes of errors
- **Lower maintenance costs** - Code is easier to understand and modify
- **Scalable architecture** - Explicit dependencies and effects make scaling easier

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
│  - Carries proof structs only in `--debug` builds (see below)    │
└─────────────────────────────────────────────────────────────┘
```

**Proof cost model:** Proofs are **zero-cost by default**. In a normal (release) build they are
erased after type-checking — there is no wrapper, no struct, and no allocation; the proof exists
only in the compiler's static checker. Even under `--debug` they are erased: the step debugger
shows the raw runtime value and overlays a binding's proof/type from compile-time type info, so it
needs no runtime struct. `TESL_ZERO_COST_PROOFS=0` restores the runtime net for regression
comparison. See [proof cost model](best-practices.md#proof-cost-model) and the
[FAQ](FAQ.md#is-there-runtime-overhead-for-proofs).

---

## Feature Set

### ✅ Currently Implemented

- [x] `.tesl` surface language with clean syntax
- [x] Working compiler (OCaml) with type checking
- [x] GDP-style proof system with compile-time verification
- [x] Zero-cost proofs — erased unconditionally (release and `--debug`); runtime net only via `TESL_ZERO_COST_PROOFS=0` for regression
- [x] CLI with validation, compilation, and execution
- [x] Built-in linter and formatter
- [x] Typed SQL database access
- [x] Background job queues with workers
- [x] Pub/Sub with Server-Sent Events (SSE)
- [x] Authentication and authorization system
- [x] Mutation testing for validation functions
- [x] Language server protocol (LSP) support
- [x] Editor integration (VS Code, VSCodium)
- [x] TypeScript and Elm client generation

### 🚧 In Development

- [ ] Step debugger (VS Code DAP) that overlays proof/type from compile-time at breakpoints
- [ ] More standard library functions
- [ ] Additional database backends
- [ ] Performance optimizations
- [ ] More frontend client generators

### 📋 Planned

- [ ] Package manager for Tesl libraries
- [ ] Web-based playground/repl
- [ ] More extensive standard library
- [ ] IDE integrations beyond VS Code

---

## Who Should Use Tesl?

Tesl is designed for:

### ✅ Product Engineers

You want to **ship features quickly** without sacrificing quality. Tesl's type system catches bugs early, so you can move fast with confidence.

### ✅ API Developers

You build web APIs and want a language that **understands APIs natively**. Tesl has built-in support for routing, validation, auth, databases, queues, and pub/sub.

### ✅ Teams That Value Quality

You want your team to **produce consistent, high-quality code**. Tesl's type system and conventions make it hard to write bad code.

### ✅ Developers Coming from TypeScript, C#, Java, or Kotlin

Tesl's syntax and concepts will feel **familiar** if you've used statically typed languages before.

### ⚠️ Maybe Not Yet

Tesl is **alpha-stage**, so it might not be suitable for:
- Production systems that require stability guarantees
- Teams that can't tolerate breaking changes
- Projects that need extensive third-party library support

---

## Getting Started

1. **Install Tesl**:
   ```bash
   nix profile install github:mtonnberg/tesl
   ```

2. **Try an example**:
   ```bash
   tesl validate example/todo-api.tesl
   tesl run example/todo-api.tesl
   ```

3. **Learn the language**:
   - Read [TESL.md](../TESL.md) for a high-level introduction
   - Explore [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) for the formal specification
   - Work through the [examples](examples.md)
   - Follow the [best practices](best-practices.md)

---

## See Also

- [Manual Index](MANUAL.md) - Back to the main manual
- [TESL.md](../TESL.md) - High-level language introduction
- [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) - Formal language specification
- [Examples](examples.md) - Complete list of example files
- [Best Practices](best-practices.md) - Recommended patterns and conventions
- [INSTALL.md](../INSTALL.md) - Installation instructions
- [README.md](../README.md) - Project overview
