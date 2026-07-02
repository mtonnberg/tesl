# Stable Anchor Scheme

This page defines how the Tesl manual is addressed by **machines** — compiler error messages,
editor "see also" links, and any external tooling that wants to deep-link into the docs.

Use `tesl help manual anchors` to read this from the CLI.

> **Why this exists.** Prose moves around. Section *headings* are far more stable. By promising a
> small set of canonical anchors and a fixed slug rule, we let an error message say
> *"see `best-practices#validation-patterns`"* today and trust that link still resolves after the
> surrounding paragraphs have been rewritten ten times.

---

## The address format

A manual location is addressed as:

```text
<section>[#<anchor>]
```

- **`<section>`** — a manual section name accepted by `tesl help manual <section>`. The canonical
  set is listed in the [manual index](MANUAL.md#manual-sections): `getting-started`, `overview`,
  `language-spec`, `examples`, `best-practices`, `faq`, `anchors`, `dev`.
- **`#<anchor>`** *(optional)* — a heading **slug** within that section (see slug rules below). When
  omitted, the address refers to the top of the section.

A fully written citation, as it appears in compiler diagnostics and editor links, is:

```text
tesl help manual best-practices#validation-patterns
```

**How the `#anchor` is consumed today:**

- **Rendered Markdown** (GitHub, editor preview): the `#anchor` jumps straight to the heading.
- **Compiler diagnostics / "see also" text**: the full `<section>#<anchor>` string is printed
  verbatim as a citation, so a reader knows both which section to open and exactly which heading to
  read. Diagnostics also print an `explain: tesl help <code>` pointer for the error's stable code.
- **`tesl help manual` CLI**: `tesl help manual <section>#<anchor>` **resolves the anchor** and
  prints just that sub-section (the anchored heading plus its body, up to the next same-or-shallower
  heading). If the anchor does not resolve, the CLI prints the whole section with a note, so a
  citation never dead-ends. Because the anchor is the heading slug, the same string works in the
  CLI, on GitHub, and in editor previews.

The `#anchor` is therefore the **stable key** that tooling keys on; it is never *required* to
locate the file.

---

## Slug rules (how a heading becomes an anchor)

Anchors use the conventional GitHub-flavoured-Markdown slug, so the same `#anchor` works in the CLI
output, in rendered Markdown on GitHub, and in editor previews. To derive a slug from a heading:

1. Take the heading text (without the leading `#` characters).
2. Lower-case it.
3. Drop everything that is not a letter, digit, space, or hyphen — **including emoji and
   punctuation** (e.g. `?`, `:`, `✅`).
4. Replace each run of spaces with a single hyphen.
5. Trim leading/trailing hyphens.

Examples:

| Heading | Slug |
|---|---|
| `## Validation Patterns` | `validation-patterns` |
| `## Proof Management` | `proof-management` |
| `## Proof Cost Model` | `proof-cost-model` |
| `## Database Access` | `database-access` |
| `### Is there runtime overhead for proofs?` | `is-there-runtime-overhead-for-proofs` |

---

## Canonical stable anchors

These anchors are a **stability contract**: the heading text may be reworded, but the slug below
will keep resolving to a heading covering the same topic. Tooling and error messages may hard-code
them.

> **Error codes ↔ anchors.** Every diagnostic now carries a **stable error code** (e.g. `V001`,
> `T001`). Each code maps to one of the anchors below; a rendered error prints
> `read more: tesl help manual <section>#<anchor>` and `explain: tesl help <code>`. The code →
> anchor mapping is the registry in `compiler/lib/error_codes.ml`, surfaced by `tesl help codes`
> and `tesl help <code>`. The build fails (via `compiler/test/test_error_codes.ml`) if any code's
> anchor stops resolving to a real heading, so the table below and the code mapping cannot drift
> apart.

### `overview`

| Anchor | Topic |
|---|---|
| `overview#core-principles` | The four core principles (validate once, explicit auth/effects, hard-to-express invalid states) |

### `best-practices`

| Anchor | Topic |
|---|---|
| `best-practices#validation-patterns` | How to write and compose `check` functions |
| `best-practices#proof-management` | Attaching, detaching, and reattaching proofs |
| `best-practices#proof-cost-model` | Runtime cost of proofs (zero — erased in release and `--debug`; net only via `=0`) |
| `best-practices#api-design` | Route design, versioning, pagination |
| `best-practices#database-access` | Typed queries, parameterization, transactions |
| `best-practices#error-handling` | Status codes and structured error messages |
| `best-practices#testing` | The testing pyramid and Tesl's test types |

### `faq`

| Anchor | Topic |
|---|---|
| `faq#is-there-runtime-overhead-for-proofs` | The proof cost model, in FAQ form |

### `language-spec`

The specification (`LANGUAGE-SPEC.md`) is addressed by **section number** (`§7.4`, `§14b.2`),
not by GFM slug. Section numbers are the spec's stable key, exactly as the slugs above are the
manual's — the *heading text* after a number may be reworded, but the number keeps pointing at a
heading covering the same topic. Compiler diagnostics, comments, and tests cite the spec this way
(e.g. `LANGUAGE-SPEC.md §7.12`); `LANGUAGE-SPEC.md` opens with a hand-maintained
[Table of Contents](../LANGUAGE-SPEC.md#table-of-contents) keyed on these numbers.

**Stability contract.** The following section numbers are cited by name from
`compiler/lib/*.ml` and `compiler/test/*.ml`. They are a stability contract in the same sense as
the manual anchors above: renumbering one is a breaking change; keep the old number resolving to a
heading (add a sub-heading or a note) for at least one release. `compiler/test/test_spec_anchors.ml`
fails the build if any `§`-number cited by the compiler stops resolving to a real heading in
`LANGUAGE-SPEC.md`, so this table and the code citations cannot drift apart.

| Spec § | Heading it must resolve to (topic) |
|---|---|
| `§6.1` | Raw values |
| `§6.3` | Named values |
| `§7.1` | Fresh hidden subjects for ordinary values |
| `§7.3` | Facts attach to subjects, not to surface spellings |
| `§7.4` | Name shadowing is illegal (host-wide no-shadowing) |
| `§7.7` | `attachFact` does not retarget a proof to a new subject |
| `§7.8` | Unbound GDP names in proof templates are rejected |
| `§7.9` | Existential witnesses may not escape |
| `§7.10` | Proof verification is compile-time; some runtime semantics remain |
| `§7.11` | Newtype nominal identity is enforced at runtime |
| `§7.12` | `:::` fabrication is restricted to trusted function kinds |
| `§8.5` | Literals |
| `§9.1` | GDP expressions |
| `§11.2` | Top-level immutable bindings |
| `§11.6` | Type declarations |
| `§11.7` | Records |
| `§12` | Function bodies and expressions |
| `§13.1` | Names, duplication, and imports |
| `§13.2` | No-shadowing rule (static) |
| `§13.9` | Proof predicate scope and explicit import |
| `§14b.1` | Type language (structural) |
| `§14b.2` | PosixMillis is not Int |
| `§20.5` | Transactional atomicity (email) |

> **Scope of the check.** The resolution test collects `§`-citations from compiler sources but
> deliberately **excludes internal-review shorthand** (`Fix-11 §…`, `Review20 §…`,
> `critical-review-17 §…`, `review 50 §…`) — those numbers refer to review documents, not to the
> spec — and excludes by-**line** references. Only genuine spec-section citations are validated.

---

## Contract for tooling authors

- **Treat this table as the API.** If an anchor is listed above, you may hard-code it. If it is not
  listed, do not rely on it — derive it at runtime with the slug rules instead, and expect it to
  move.
- **Always cite as `tesl help manual <section>#<anchor>`** in user-facing text so a reader can copy
  the command verbatim.
- **Adding a new stable anchor** is a deliberate act: add the heading to the relevant manual file,
  add a row to the table above, and add a case to `manual/tests/test_embedded_docs.ml`, which fails
  the build if any anchor listed here stops resolving to a real heading.
- **Renaming or removing a listed anchor is a breaking change.** Keep the old slug as a heading (or
  an alias) for at least one release.

---

## See also

- **[Manual Index](MANUAL.md)** — the full command map and section list
- **[Best Practices](best-practices.md)** — where most stable anchors live
- **[FAQ](FAQ.md)** — troubleshooting
