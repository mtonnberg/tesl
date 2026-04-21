# The Problem: Validate and Hope

In most frameworks you validate at the boundary — and then hope the validated data actually makes it through.

---

## The same type, before and after

```typescript
// TypeScript / Express
app.post("/todos", async (req, res) => {
  if (!req.body.title || req.body.title.length < 3) {
    return res.status(400).json({ error: "title too short" })
  }

  // Validation ran. But the type hasn't changed:
  const title: string = req.body.title  // identical type to raw input
  await createTodo(title)               // was it validated? the type won't tell you.
})

// Service layer, called from anywhere:
async function createTodo(title: string) {
  // `string` — same type as unvalidated input.
  // Nothing prevents calling this without going through the controller.
  await db.todos.insert({ title })
}
```

---

## How it breaks in practice

- A new developer adds a shortcut path and calls `createTodo` directly
- A refactor splits the controller — some paths skip the validation middleware
- A test hits the service layer without going through HTTP
- A queue worker deserializes a job and calls the service — no validation layer in sight

**The type system has no memory of the check.** Validated and unvalidated strings look identical.

---

## The cost

Every function deep in the stack must either:

- **Re-validate** — redundant, tedious, and usually skipped
- **Trust callers** — a convention enforced by code review, not the compiler

This is how subtle bugs sneak in: data that *looks* validated but wasn't, or a validation path that works 99% of the time but has one unchecked edge.

---

*Next: [How Tesl solves this →](02-validate-once.md)*
