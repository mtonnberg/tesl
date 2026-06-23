# Tesl Manual

This is the central entry point for all Tesl documentation. Use `tesl help manual` to access this content from the CLI.

## Quick Navigation

| Section | Command | Description |
|---------|---------|-------------|
| **Getting Started** | `tesl help manual getting-started` | Step-by-step guide to your first Tesl project |
| **Overview** | `tesl help manual overview` | Introduction to Tesl and its goals |
| **Language Specification** | `tesl help manual language-spec` | Formal language specification |
| **Examples** | `tesl help manual examples` | List of all example files with descriptions |
| **Best Practices** | `tesl help manual best-practices` | Recommended patterns and conventions |
| **Developer Docs** | `tesl help manual dev` | Documentation for Tesl contributors |
| **FAQ** | `tesl help manual faq` | Frequently asked questions and troubleshooting |

---

## Table of Contents

### 1. Getting Started

- **[Getting Started Guide](GETTING-STARTED.md)** - Step-by-step guide to your first Tesl project
- **[Overview](overview.md)** - What is Tesl and what problems does it solve?
- **[Installation](../INSTALL.md)** - How to install and set up Tesl

### 2. Core Concepts

- **[Language Specification](../LANGUAGE-SPEC.md)** - The formal specification of the Tesl language
- **[TESL.md](../TESL.md)** - High-level language introduction with examples

### 3. Building APIs

- **[Examples Index](examples.md)** - Complete list of all example files
- **Runable Examples:**
  - [Todo API](../example/todo-api.tesl) - A complete CRUD API with PostgreSQL
  - [Admin Task API](../example/admin-task-api.tesl) - Task management with auth
  - [Queue API](../example/queue-api.tesl) - Background job processing
  - [Chat Backend](../example/chat/chat-backend.tesl) - Real-time chat with SSE

### 4. Learning Resources

- **[Intro Tutorial Series](../example/intro/)** - Step-by-step tutorials:
  - [The Problem](../example/intro/01-the-problem.md) - What Tesl solves
  - [Validate Once](../example/intro/02-validate-once.md) - Core validation principle
  - [Cross-Value Proofs](../example/intro/02b-cross-value-proofs.md)
  - [Authentication](../example/intro/03-auth.md)
  - [Capabilities](../example/intro/04-capabilities.md)
  - [Typed SQL](../example/intro/05-typed-sql.md)
  - [Forall Proofs](../example/intro/05b-forall-proofs.md)
  - [Queues](../example/intro/06-queues.md)
  - [Real-time](../example/intro/07-realtime.md)
  - [Testing](../example/intro/08-testing.md)

- **[Learn Lessons](../example/learn/)** - Structured learning path with 50+ lessons

### 5. Best Practices

- **[Best Practices Guide](best-practices.md)** - Recommended patterns and conventions

### 6. Developer Documentation

- **[Developer Docs Index](../dev-docs/README.md)** - Overview of Tesl's architecture
- **[Parser](../dev-docs/02-parser.md)** - Implementation of the Tesl parser
- **[Module System](../dev-docs/03-module-system.md)** - How the module system works
- **[Body Compiler](../dev-docs/04-body-compiler.md)** - How function bodies are compiled
- **[Adding Stdlib Functions](../dev-docs/05-adding-stdlib-function.md)** - Extending the standard library
- **[GDP Runtime](../dev-docs/06-gdp-runtime.md)** - Ghosts of Departed Proofs runtime
- **[SQL Layer](../dev-docs/07-sql-layer.md)** - Database integration details
- **[Queues and Pub/Sub](../dev-docs/08-queue-pubsub.md)** - Background processing and real-time
- **[Adding Tests](../dev-docs/09-adding-tests.md)** - How to add new tests
- **[Common Patterns](../dev-docs/10-common-patterns.md)** - Frequently used implementation patterns
- **[Frontend IR](../dev-docs/11-frontend-ir.md)** - Frontend intermediate representation

### 7. Reference

- **[LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md)** - Complete language specification
- **[README.md](../README.md)** - Project overview and quick start

### 8. Troubleshooting

- **[FAQ](FAQ.md)** - Frequently asked questions
- **[README.md](../README.md#editor-and-language-server)** - Editor setup and LSP

---

## Command Reference

For CLI usage, see:
```
tesl help                    # Show all available commands
tesl help manual             # Show this manual
tesl help manual <section>   # Show specific manual section (getting-started, overview, language-spec, examples, best-practices, faq)
tesl help manual full        # Show ALL documentation concatenated (for LLMs with large context windows)
tesl help full               # Same as above
tesl help examples           # List all example files
tesl help search <query>     # Search all documentation
```

## Search Tips

- Use `tesl help search <term>` to search across all documentation
- Section names in error messages (e.g., "see 'tesl help manual validation'") refer to these manual sections
- All `.tesl` example files are documented in the Examples section

---

## See Also

- **[Main README](../README.md)** - Project overview and quick start
- **[TESL.md](../TESL.md)** - High-level language introduction
- **[LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md)** - Formal language specification
- **[Developer Docs](../dev-docs/)** - Contribution guides
- **[Examples](../example/)** - Runable example files
