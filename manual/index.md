# Tesl Manual

The entry point for all Tesl documentation. For the full index and command map, see
**[MANUAL.md](MANUAL.md)** (or run `tesl help manual`).

## Quick links

- **[MANUAL.md](MANUAL.md)** — complete index and CLI command map
- **[GETTING-STARTED.md](GETTING-STARTED.md)** — install and first project
- **[overview.md](overview.md)** — what Tesl is and why
- **[examples.md](examples.md)** — bundled examples, grouped by topic
- **[best-practices.md](best-practices.md)** — recommended patterns + the proof cost model
- **[FAQ.md](FAQ.md)** — common questions
- **[anchors.md](anchors.md)** — the stable anchor scheme for deep-linking

## CLI usage

```bash
tesl help                         # command-line usage
tesl help manual                  # this manual (index + command map)
tesl help manual <section>        # one section (overview, examples, best-practices, faq, …)
tesl help examples                # the examples index
tesl help search <query>          # full-text search across the manual
tesl help manual full             # everything concatenated (for large-context LLMs)
```

Diagnostics cite sub-sections as `<section>#<anchor>` (e.g. `best-practices#proof-cost-model`);
see [anchors.md](anchors.md) for the scheme.

```bash
# example citation as it appears in an error message:
#   see 'tesl help manual best-practices#validation-patterns'
```

## See also

- [README.md](../README.md) — project overview
- [TESL.md](../TESL.md) — high-level introduction
- [LANGUAGE-SPEC.md](../LANGUAGE-SPEC.md) — formal specification
- [INSTALL.md](../INSTALL.md) — installation instructions
