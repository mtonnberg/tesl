# Tesl
## *Joyfully unbreakable APIs.*

A language for building web APIs where the important guarantees are part of the language — not bolted on afterward.

---

**Who is it for?**  
TypeScript, C#, Java, or Kotlin developers who want to ship APIs faster, with fewer runtime surprises. No type-theory background required.

**What makes it different?**  
Validation, auth, and side effects are tracked by the compiler. Once data is checked, the compiler *remembers* — and the check never runs again downstream.

**Scope:** HTTP APIs + PostgreSQL. Intentionally narrow. Excellent at what it does.

**Status:** Alpha. Working. Opinionated. Not yet production-stable.

---

## Slides

| # | Topic |
|---|-------|
| [01](01-the-problem.md) | The problem: validate and hope |
| [02](02-validate-once.md) | Validate once, trust everywhere |
| [02b](02b-cross-value-proofs.md) | Proofs across two values and record-wide invariants |
| [03](03-auth.md) | Auth the compiler enforces |
| [04](04-capabilities.md) | Explicit side effects |
| [05](05-typed-sql.md) | Typed SQL |
| [05b](05b-forall-proofs.md) | ForAll proofs — lists that remember their origin |
| [06](06-queues.md) | Background jobs, no Redis |
| [07](07-realtime.md) | Real-time SSE, same port |
| [08](08-testing.md) | Testing built in |
| [09](09-full-picture.md) | A complete API |
| [10](10-status.md) | Status and what's next |
