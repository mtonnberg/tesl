# Tesl playground: facts for people and coding agents

Tesl is a beta programming language for backend applications. The compiler checks
value types, declared capabilities, and required evidence for particular values.
It emits a Go project and can generate TypeScript/Zod and Elm clients from API
contracts. Proof declarations do not validate inputs by themselves: the bodies of
check/auth/establish functions are trusted and need correct implementation and tests.

The default example is the runnable Hello HTTP server. An optional guided
introduction sits beside the editor, with compiler-checked activities for an
endpoint edit, import repair, customer validation, capability propagation, money,
dimensions and five forms of testing. Steps automatically load matching examples and retain per-step drafts in memory.
Each exercise shows its suggested code beside an Apply edit button. It preserves the starting buffer and step for
Resume guide in the current session. Completion stars synchronize across open tabs and store only exercise IDs in localStorage
when available, with a Reset stars control. They recognize suggested edits and
do not certify arbitrary programs or local execution from a click or download.

## Try a concrete task

- [Customer invoice](examples/customer-invoice.tesl): require evidence that the
  invoice belongs to the supplied customer before producing its label. Includes
  success and rejection tests. In a service the customer must come from trusted
  authentication. This example is not a complete authorization system.
- [Missing customer check](examples/customer-invoice-unchecked.tesl): deliberately
  fails with V001 at the unchecked call.
- [Hello HTTP](examples/hello-server.tesl): an App on port 8086 with GET /hello,
  using an empty in-memory database. Save as HelloServer.tesl and run locally.
- [Start guide](start.html): installation links, run instructions and an agent prompt.

## What the browser does

The real compiler runs as JavaScript, locally, on one buffer. It checks source and
emits code; it does not execute tests, HTTP servers, databases or generated Go.
Tesl.* imports are embedded; other local imports need a local project. Builtin
search supports text and type shapes, including unfinished suffixes such as
Float -> F. It is not a project-wide type or proof search. The optional Monaco
editor provides compiler diagnostics, quick fixes and catalog-based completion;
it is not a full VS Code workspace or language server.

Source and queries are not submitted to a backend. Share links put source in the
URL fragment. Theme and the explicit introduction visibility preference are stored
locally, along with earned exercise-star IDs. Source snapshots remain in memory.
There is no adoption analytics collector. Install clicks are intent,
not evidence that installation succeeded.

## Continue locally

Use the [current installation documentation](https://github.com/mtonnberg/tesl/blob/main/INSTALL.md)
and [quick start](https://github.com/mtonnberg/tesl#quick-start). Do not infer
support for an operating system or installation method from this page. Standalone
installers are separate work. Check current docs before choosing a method.

For agent-assisted development, read the
[agent API](https://github.com/mtonnberg/tesl/blob/main/AGENTS.md).
Run `tesl agent-context FILE` after edits and follow the actual coded diagnostics.
Use targeted position queries when needed. A clean compiler result does not mean
tests were executed or a service was started. Report what you actually verified.

Official source: https://github.com/mtonnberg/tesl


## Testing chapter

[Compare test types](index.html?guide=tests): regular example assertions,
[executable documentation examples](index.html?guide=doctests), fuzz/property runs, API requests and load-test budgets. Tesl expresses fuzz-style
checks as `property` blocks inside `test ... with N runs`, not a `fuzz-test` keyword.
The browser only checks these declarations. Stars mean a suggested test addition
was accepted by the compiler; use the displayed `tesl test` command to execute it.
The examples and additions are verified with the real Go-backed CLI. Load tests
exercise a small local harness and are not production-capacity measurements.
