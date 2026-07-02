# A10 — client-generation soundness

> Relocated 2026-07-02 from `close_all_open_issues.md` (Wave 2, item A10).
> Review §8.2, §10 item 7.

## DECISIONS

- only improve the elm-generator, the zod generator might be changed to another javascript library (if the zod emitter is improved that is good but that is not the focus/requirement)

## The problem

The client generators (`--generate-ts` / `--generate-elm`) are the one place where Tesl
drifts from sound. Two confirmed defects:

1. **Nested-`if` constraint under-approximation (high→medium).** A `check` with a nested
   `if` emits `z.string().min(3)` — silently *dropping* other conjuncts such as
   `startsWith "AB"`. Worse, the Elm generator emits `Just (axiom ValidCode input)` — a
   **manufactured false proof** for a value the server will actually reject. The server
   stays sound; the *client* proof is a lie. Root cause: `extract_simple_constraints`
   (`ir.ml:676`) partially captures the predicate and returns `Some` anyway.
2. **Client generators bypass the checker entirely (medium).** `--generate-ts` /
   `--generate-elm` call `Parser.parse_module` and then emit, **skipping `Compile`**
   (`main.ml`). A type-invalid program exits 1 under `--check` but exits 0 and emits a
   plausible client under `--generate-ts`.

## Why it matters

A generated client that asserts `axiom ValidCode input` on a value the server rejects
hands downstream code a proof that is false — the exact fabrication class the whole thesis
exists to prevent, leaking out through a side door. And a generator that emits from
un-type-checked source can emit a client for a program that does not compile.

## Fix approach

- Make `extract_simple_constraints` **total**: return `Some` only when it *provably*
  captured the entire predicate; otherwise fall back to **server-only** validation and
  **never manufacture a client `axiom`**. Better still, derive client constraints from the
  same normalized predicate IR the server compiles, so client and server share one source
  of constraint truth.
- **Gate `--generate-ts` / `--generate-elm` behind `Compile`** (not just
  `Parser.parse_module`), so a type-invalid program cannot emit a client.

## Effort

**M** — the totality rewrite of `extract_simple_constraints` plus the `Compile`-gating in
`main.ml`; the "derive from the normalized predicate IR" variant is larger but is the
principled endpoint.

## Refs

- Review: §8.2 (nested-`if` under-approximation; client generators bypass the checker),
  §10 item 7.
- Source: `ir.ml:676` (`extract_simple_constraints`), `emit_elm.ml`, `emit_ts.ml`,
  `main.ml` (the `--generate-*` entry points).
