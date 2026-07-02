# Tesl — proof-carrying web APIs, for humans and AI agents

> **Status: alpha.** The guarantees described below are real and compiler-enforced for code written in Tesl, but they are *compile-time* guarantees with no runtime re-check (see [Runtime cost](#runtime-cost)), and the trust boundary is drawn precisely in [`LANGUAGE-SPEC.md` §7](LANGUAGE-SPEC.md). Tesl is not yet production-stable; breaking changes are expected. Read this document as the design intent and what is enforced today — not as a promise of an unbreakable system.

**Tesl** is a programming language for building robust web APIs without the infrastructure tax. A
`check` function makes a validated value *carry its proof*, so once data is checked at the boundary
the compiler structurally prevents whole classes of forgotten-validation and defensive-boilerplate
bugs downstream. Auth, effects, typed SQL, queues, real-time pub/sub, and AI-agent tools are all part
of the language, not bolted on.

This root file is intentionally short. The full material lives in three places:

- **[README](README.md)** — the pitch, quick start, alpha status, and non-goals.
- **[Guided feature tour](manual/tour.md)** — the long-form, feature-by-feature walkthrough
  (how it works, auth, capabilities, typed SQL, ADTs, queues, SSE, agents, `ForAll` proofs, tests,
  and the theory behind it). Also available as `tesl help manual tour`.
- **[LANGUAGE-SPEC.md](LANGUAGE-SPEC.md)** — the precise grammar and semantics (the source of truth).

## Runtime cost

Most of Tesl's safety guarantees are *compile-time only* and disappear before your program runs: a
proof costs nothing at runtime (proof tracking is erased), while actual work (validating a value,
reading a cookie, running a query) happens exactly once, at the right moment. "Zero-cost" refers to
proof erasure specifically, not to all runtime overhead — each `fn`/`handler` call still pays a
small always-on capability-grant + return-shape-validation cost. The full per-feature breakdown is
single-sourced in the canonical
[proof cost model](manual/best-practices.md#proof-cost-model).
