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

`language-spec` has no promised sub-anchors yet. Cite the section as a whole
(`tesl help manual language-spec`) until anchors are published here.

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
