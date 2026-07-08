# Tesl Examples

This is a complete catalog of all Tesl example files. Each example demonstrates different aspects of the language and runtime.

Use `tesl help manual examples` to access this from the CLI.

---

## Quick Start Examples

These are the simplest examples to get you started:

| File | Description | Key Concepts |
|------|-------------|--------------|
| [`sandbox.tesl`](../example/sandbox.tesl) | Minimal Tesl file for experimentation | Basic syntax, validation |
| [`sandbox2.tesl`](../example/sandbox2.tesl) | Slightly more complex sandbox | Records, checks |
| [`sandbox3.tesl`](../example/sandbox3.tesl) | Another experimental sandbox | Functions, types |

---

## Complete API Examples

These are full, runnable API examples:

| File | Port | Description | Key Features |
|------|------|-------------|--------------|
| [`todo-api.tesl`](../example/todo-api.tesl) | 8086 | A complete Todo API with CRUD operations | Validation, SQL, auth |
| [`admin-task-api.tesl`](../example/admin-task-api.tesl) | 8085 | Task management with admin features | Auth, capabilities |
| [`queue-api.tesl`](../example/queue-api.tesl) | 8087 | Background job queue processing | Queues, workers |

---

## Learning Path (Recommended Order)

The `learn/` directory ships **73 `.tesl` lessons** (`ls example/learn/lesson*.tesl | wc -l`).
The list below is a curated recommended order through the core concepts, not the full catalog —
run `ls example/learn/` (or `tesl help manual examples`) to see every lesson, including the later
ones on UUID/JWT/HTTP client, caching, email, step debugging, AI agents, and query
parameters.

### Basics
1. **[lesson00-hello-world.tesl](../example/learn/lesson00-hello-world.tesl)** - Your first Tesl program
2. **[lesson01-basic-types-and-functions.tesl](../example/learn/lesson01-basic-types-and-functions.tesl)** - Basic types and functions
3. **[lesson02-adts-and-pattern-matching.tesl](../example/learn/lesson02-adts-and-pattern-matching.tesl)** - ADTs and pattern matching
4. **[lesson03-records.tesl](../example/learn/lesson03-records.tesl)** - Record types
5. **[lesson04-newtypes.tesl](../example/learn/lesson04-newtypes.tesl)** - Newtypes

### Proof System
6. **[lesson05-intro-to-proofs.tesl](../example/learn/lesson05-intro-to-proofs.tesl)** - Introduction to GDP-style proofs
7. **[lesson06-proof-check-proof-auth.tesl](../example/learn/lesson06-proof-check-proof-auth.tesl)** - Proof, check, and auth functions
8. **[lesson08-proof-transport.tesl](../example/learn/lesson08-proof-transport.tesl)** - Proof transport with detachFact/attachFact
9. **[lesson09-proof-composition.tesl](../example/learn/lesson09-proof-composition.tesl)** - Composing proofs
10. **[lesson10-cross-parameter-proofs.tesl](../example/learn/lesson10-cross-parameter-proofs.tesl)** - Proofs across parameters

### Validation
11. **[lesson12-records-with-proofs.tesl](../example/learn/lesson12-records-with-proofs.tesl)** - Records with proofs
12. **[lesson13-partial-application-and-pipelines.tesl](../example/learn/lesson13-partial-application-and-pipelines.tesl)** - Partial application and pipelines
13. **[lesson14-test-blocks.tesl](../example/learn/lesson14-test-blocks.tesl)** - Test blocks

### Advanced Types
14. **[lesson11-capabilities.tesl](../example/learn/lesson11-capabilities.tesl)** - Capability system
15. **[lesson22-compound-named-pack.tesl](../example/learn/lesson22-compound-named-pack.tesl)** - Compound named packing
16. **[lesson27-either-dict-set.tesl](../example/learn/lesson27-either-dict-set.tesl)** - Either, Dict, Set types
17. **[lesson37-parameterized-adts.tesl](../example/learn/lesson37-parameterized-adts.tesl)** - Parameterized ADTs

### Capabilities & Effects
18. **[lesson07-consumer.tesl](../example/learn/lesson07-consumer.tesl)** - Consumer capability
19. **[lesson11-capabilities.tesl](../example/learn/lesson11-capabilities.tesl)** - Capability system introduction

### Database
20. **[lesson18-database-sql-and-proofs.tesl](../example/learn/lesson18-database-sql-and-proofs.tesl)** - Database operations with proofs
21. **[lesson20-named-db-results.tesl](../example/learn/lesson20-named-db-results.tesl)** - Named database results
22. **[lesson21-sql-reference.tesl](../example/learn/lesson21-sql-reference.tesl)** - SQL reference and examples (incl. grouped aggregates `selectCountBy`/`selectSumBy` and time bucketing)

### Forall Proofs
23. **[lesson29-forall-list-proofs.tesl](../example/learn/lesson29-forall-list-proofs.tesl)** - Forall proofs with lists
24. **[lesson30-forall-set-proofs.tesl](../example/learn/lesson30-forall-set-proofs.tesl)** - Forall proofs with sets

### Proof Advanced
25. **[lesson38-proof-decomposition.tesl](../example/learn/lesson38-proof-decomposition.tesl)** - Proof decomposition
26. **[lesson51-proof-combining.tesl](../example/learn/lesson51-proof-combining.tesl)** - Combining proofs
27. **[lesson52-maybe-proof.tesl](../example/learn/lesson52-maybe-proof.tesl)** - Maybe type proofs
28. **[lesson53-literal-parametrized-predicates.tesl](../example/learn/lesson53-literal-parametrized-predicates.tesl)** - Literal parametrized predicates

---

## Feature-Specific Examples

### Queues & Background Processing
| File | Description |
|------|-------------|
| [`lesson23-queues-and-workers.md`](../example/learn/lesson23-queues-and-workers.md) | Queue and worker basics |
| [`lesson28-dead-letter-queue.tesl`](../example/learn/lesson28-dead-letter-queue.tesl) | Dead letter queue handling |

### Pub/Sub & Real-time
| File | Description |
|------|-------------|
| [`lesson24-pubsub-sse.md`](../example/learn/lesson24-pubsub-sse.md) | Server-Sent Events pub/sub |
| [`chat/chat-backend.tesl`](../example/chat/chat-backend.tesl) | Complete chat application |

### AI Agents
| File | Description |
|------|-------------|
| [`lesson62-ai-agents.tesl`](../example/learn/lesson62-ai-agents.tesl) | Agents and typed-function tools (`asTool`) |
| [`lesson63-ai-structured-output.tesl`](../example/learn/lesson63-ai-structured-output.tesl) | Typed structured output (`askFor` / `decodeAs`) |
| [`lesson68-server-endpoints-as-tools.tesl`](../example/learn/lesson68-server-endpoints-as-tools.tesl) | `serverTools`: your HTTP endpoints as preauthenticated agent tools, combined with custom tools |
| [`lesson69-agent-human-handoff.tesl`](../example/learn/lesson69-agent-human-handoff.tesl) | `humanActions`: endpoints the agent may not run, handed to the human as a button, with resume-after |
| [`lesson70-agent-async-work.tesl`](../example/learn/lesson70-agent-async-work.tesl) | Long-running agent work over a queue: a tool enqueues, a worker does it and resumes the conversation |
| [`support-assistant.tesl`](../example/support-assistant.tesl) | Complete capability-bounded support assistant with deterministic tests |

### Money & Units
| File | Description |
|------|-------------|
| [`lesson71-money.tesl`](../example/learn/lesson71-money.tesl) | `Tesl.Money`: integer minor units + intrinsic currency, proof-gated add (`SameCurrency`), runtime exchange rates, a Money entity column with `selectSum` |
| [`lesson72-units.tesl`](../example/learn/lesson72-units.tesl) | `Tesl.Units`: compile-time SI dimensional analysis erased to Float — `m/s² × s : m/s`, pace = distance/time, areas, `Units.sqrt`, unit conversions in/out |

### Testing
| File | Description |
|------|-------------|
| [`sandbox2.test.tesl`](../example/sandbox2.test.tesl) | Test examples for sandbox2 |
| [`lesson32-api-tests.tesl`](../example/learn/lesson32-api-tests.tesl) | API testing patterns |

---

## How to Run Examples

1. **Validate** (check syntax and types without running):
   ```bash
   tesl validate example/todo-api.tesl
   ```

2. **Run** (start the API server):
   ```bash
   tesl run example/todo-api.tesl
   ```

3. **Test** (run test blocks in the file):
   ```bash
   tesl test example/sandbox2.test.tesl
   ```

4. **Compile** (generate Racket code):
   ```bash
   tesl example/todo-api.tesl > output.rkt
   ```

---

## Intro Tutorial Series

The `intro/` directory contains a step-by-step tutorial:

| File | Description |
|------|-------------|
| [`00-title.md`](../example/intro/00-title.md) | Tutorial introduction |
| [`01-the-problem.md`](../example/intro/01-the-problem.md) | The problem Tesl solves |
| [`02-validate-once.md`](../example/intro/02-validate-once.md) | Validate once principle |
| [`02b-cross-value-proofs.md`](../example/intro/02b-cross-value-proofs.md) | Cross-value proofs |
| [`03-auth.md`](../example/intro/03-auth.md) | Authentication |
| [`04-capabilities.md`](../example/intro/04-capabilities.md) | Capabilities |
| [`05-typed-sql.md`](../example/intro/05-typed-sql.md) | Typed SQL queries |
| [`05b-forall-proofs.md`](../example/intro/05b-forall-proofs.md) | Forall proofs |
| [`06-queues.md`](../example/intro/06-queues.md) | Queue system |
| [`07-realtime.md`](../example/intro/07-realtime.md) | Real-time features |
| [`08-testing.md`](../example/intro/08-testing.md) | Testing strategies |
| [`09-full-picture.md`](../example/intro/09-full-picture.md) | Complete overview |
| [`10-status.md`](../example/intro/10-status.md) | Project status |

---

## Frontend Integration Examples

### TypeScript
The `frontend-ts/` directory shows TypeScript client generation:
- [`todo-api-client.ts`](../example/frontend-ts/src/todo-api-client.ts) - Generated TypeScript client

### Elm
The `frontend-elm/` directory shows Elm client generation:
- [`Api/TodoApi.elm`](../example/frontend-elm/src/Api/TodoApi.elm) - Generated Elm client

---

## See Also

- [Manual Index](MANUAL.md) - Back to the main manual
- [TESL.md](../TESL.md) - High-level language introduction
- [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) - Formal specification
