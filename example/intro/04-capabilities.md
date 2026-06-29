# No Hidden Side Effects

Every function in Tesl declares what it touches. Think of it as dependency injection you can't forget — enforced by the compiler, not by your team's code review discipline.

---

## Declare what you need

```tesl
handler createTodo(user: User ::: Authenticated user, newTodo: NewTodo)
  -> Todo
  requires [dbRead, dbWrite, time, random] =
  ...
```

The `requires [...]` list is the function's capability contract. If you call anything inside that needs a capability not listed here, the compiler tells you.

---

## Group capabilities into named bundles

Real APIs bundle fine-grained capabilities into service-level ones:

```tesl
capability todoRead    implies dbRead
capability todoWrite   implies dbWrite
capability todoService implies todoRead, todoWrite, time, random
```

A function with `[todoService]` automatically satisfies `[dbRead]`, `[dbWrite]`, `[time]`, and `[random]`. Declare the bundle once, use it everywhere.

---

## The compiler checks every call

Add a database write to a `dbRead`-only function:

```
$ tesl check api.tesl
api.tesl:55: missing capability: dbWrite
  `updateStatus` calls `update` which requires [dbWrite]
  but `updateStatus` only declares [dbRead]
  hint: add dbWrite to the requires list
```

No surprises in production. The mistake is caught at build time.

---

## Compile-time checking, no per-call cost

Capability **checking** is a compile-time concept. The compiler verifies, at build time, that every call's `requires` is satisfied — there is no per-call runtime overhead and no proof-style wrapper carried through your code.

Capabilities are **granted once at the App root**, derived from `main`'s `requires` list (see the queues and real-time pages for `main() -> App requires [...]`). The runtime keeps a single ambient grant check so that if a required capability was never granted at the root, the request fails fast with a "Missing capabilities" error rather than silently doing the wrong thing. This is the only place capabilities touch the runtime — there is no per-call resolution.

This is unlike dependency injection frameworks or ZIO environments: there is no container, no manual wiring step, no `resolve()` call threaded through your functions. The compiler checks the names, and the App root grants them in one place.

---

## What you gain day-to-day

- Any function's side effects are visible in its signature — no need to read the body
- "Does this read or write the database?" → check `requires`
- "Who touches the email service?" → grep for `emailCap`
- Add a new dependency → the compiler tells you every call site that needs updating
- New team members understand what each function does without reading its implementation

---

## Telemetry is the one free pass

```tesl
handler listTodos(user: User ::: Authenticated user) -> List Todo
  requires [dbRead] =
  telemetry "todos.list" { user.id = user.id }  # no capability needed
  select todo from Todo where todo.ownerId == user.id
```

`telemetry` calls are always permitted without a capability declaration. Observability is part of the platform — it shouldn't require bureaucracy.

---

*Next: [Typed SQL →](05-typed-sql.md)*
