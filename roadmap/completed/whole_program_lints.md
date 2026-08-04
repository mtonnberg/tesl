# Whole-Application Lints — Phase A

Consequence analysis first, then Phase A only. Phases B and C (a project-wide
summary index, and project-scoped W093) were **discarded 2026-08-04** by decision:
their value is unproven, and they carry every hard question this analysis turned
up. This document keeps the analysis, because if the question returns the
reasoning should not have to be redone.

## Status: Phase A IMPLEMENTED 2026-08-04

W092 (missing index) now resolves entities across the import edge; W093 (unused
index) stays file-scoped on purpose. `compiler/lib/index_lint.ml`, 29 cases in
`compiler/test/test_index_lint.ml`.

## The finding that shaped it: the two rules are not the same problem

**W092 needs only DOWNWARD edges.** A module cannot query `Issue` without
importing it, so the entity and its indexes are always reachable from the query.
Two properties follow, and they are why this half was cheap:

- every finding is positioned at the QUERY, which is in the file being linted —
  so nothing is reported against another file, and the batch entry points cannot
  double-report. The `skip_dep_body` discipline that cross-module *checks* need
  turned out to be unnecessary here.
- entity names cannot be ambiguous: a name exposed by two modules is already a
  hard error (`check_imported_exposed_name_conflicts`), and a local declaration
  shadows an imported one. The declaring-file keying the analysis called for is
  therefore already provided by scope resolution — only the local-decls-first
  ordering had to be made explicit.

**W093 needs UPWARD edges** — from the module declaring an index to consumers
nobody named. That is the part that was discarded.

## What Phase A actually covers

| layout | covered |
|---|---|
| entity + database + queries in one file | yes (since the first version) |
| entity + database in an imported schema module, queries elsewhere | **yes (new)** |
| entity in module A, database in module B, queries in module C where C imports A but not B | **no** |

The third row is a real gap and it is the repository's own flagship app:
`example/kanel/` declares entities in `KanelModels.tesl`, the queries in
`KanelDB.tesl`, and the Postgres `database` in `KanelBackend.tesl` — which
imports `KanelDB`, not the reverse. From `KanelDB.tesl` the entity is visible but
the database is not, so the entity is not judged Postgres-backed and the lint
stays silent. That is the fail-silent rule behaving correctly, not a bug, but it
means the corpus does not exercise the new capability — the tests do.

Closing that row requires either walking DOWN from the module that can see the
database into its imports' function bodies (which re-opens cross-file diagnostic
anchoring and double-reporting), or the discarded reverse scan. Neither was in
scope.

## Prerequisites that turned out to be real

**The editor's temp buffer needed the logical path.** The editor lints an unsaved
buffer by writing it to a system temp file and passing the document's real path
in `TESL_LOGICAL_PATH`. `check_json_diags` honoured that for
`Compile.check_source` but called `Linter.lint_file` with the **temp** path, so a
cross-module lint resolved imports from the temp directory, found no siblings and
went quiet — "works on the CLI, silent in the editor", with no error anywhere.
`Linter.lint_file` now takes `?logical_path`; `--check-json`, agent-context and
`--lint` all pass it, so no entry point can diverge. Pinned by a test that lints
a temp copy with and without the variable.

**No LSP change was needed.** Because every finding lands in the file being
linted, the existing diagnostic routing already handles it — the dep-partition
machinery in `editor/tesl-lsp/tesl-lsp.rkt` is not involved.

## Verified by mutation, not by a green run

- Reverting the entity table to local-only fails exactly the cross-module case
  and both editor-path cases.
- Both suppressions were already pinned this way in the previous phase
  (including `test` blocks fails only the test-block case; disabling the
  Postgres-backend filter fails only the three backend cases).

## The analysis, kept for if the question returns

### How would a project-wide lint know where to look

Local imports resolve **only** inside the importing file's own directory
(`Validation_common.resolve_local_import_path`): `dirname(source)/kebab.tesl`,
then `dirname(source)/Module.tesl`. No search path, no subdirectory mapping —
`import Routes.Todos` resolves to `routes-todos.tesl` *beside* the importer. So
the reverse-import frontier is exactly the sibling `.tesl` files in the same
directory. Not a heuristic: no file outside it can import the module.

No manifest reading would be needed — and note the OCaml compiler never reads
`tesl.toml` (only the bash CLI does, via `scripts/tesl-manifest.sh`), while a
manifest root would be the wrong unit anyway since subdirectories under it cannot
be imported. The scan root should be an INPUT (CLI argument, LSP workspace
folder, defaulting to the file's directory), never a discovery heuristic —
otherwise the answer depends on where the tool was invoked from.

**Coupling to record:** if module resolution ever gains a search path or
subdirectory mapping, that boundary silently stops being sound.

### Two apps in one directory — never refuse

`example/` holds 15 independent app entrypoints side by side; `tests/` is
similar. Refusing the layout the corpus itself uses is not shippable, and the
union over the directory is the correct semantics anyway: an index used only by
`admin.tesl` is used.

The real hazard would be **entity-name collisions across files**, which are
already live: `Note`, `Product`, `Order`, `TimeEntry` and `ConversationRecord`
are each declared in two or more corpus files. A directory-wide index keyed on
the bare entity name would cross-contaminate — and for W092 in the dangerous
direction, one app's index silencing another app's genuine finding. Any project
scan must key on (declaring file identity, entity name) and use
`canonical_import_path` (realpath) for identity, the same lesson as the 2026-07-08
cycle-detection bug.

### LSP staleness is unfixable from inside the compiler

Siblings are read from disk, i.e. whatever was last *saved*. A project-scoped
W093 could therefore say "no query uses this" while the query sits unsaved in
another tab. W092 is safe from this — a stale sibling can only make it miss a
finding, never invent one — which is why W092 belongs in the editor and any
future W093 belongs in CI. Latency agrees: single-file `--check` is ~20 ms, a
107-file sweep ~1.8 s.

### Performance, measured

| | files | lines | wall | max RSS |
|---|---|---|---|---|
| `--check-all example` (full type + proof check) | 107 | 25,019 | 1.80 s | 18 MB |
| single-file `--check` | 1 | ~700 | 0.02 s | — |

≈14k lines/s doing far more work than a lint needs. Extrapolated to 1M lines:
~72 s, and ~700 MB if AST residency scaled linearly. Wall time is fine for CI;
holding every AST is what does not scale. The shape that would scale is a
per-file **summary index** (entities declared; per query, the resolved declaring
file plus the constrained column set), content-hash keyed and cached under
`.tesl-stuff/` — a few hundred bytes per file, so 1M lines ≈ a few MB, and
re-summarising one edited file is ~1 ms. The summarize step is embarrassingly
parallel; `ci.sh` already runs a bounded `xargs -P` pool.

Two traps recorded for whoever revives this: a project lint must be **one pass
producing a map**, never "for each file, scan the directory" (that is O(files²) —
100M reads at 10k files); and it must **fail silent** on any incompleteness, since
an authoritative negative built on partial input is the most damaging kind of
wrong.
