# Durable seam test: every stdlib name resolves to a real runtime binding

**IMPLEMENTED 2026-07-07** — `compiler/test/test_stdlib_runtime_binding.ml`,
wired into `dune runtest` (its own stanza in `compiler/test/dune`).

Preventive guard carved out of [[stdlib_surface_binding_drift]] (all concrete
instances of that bug were fixed and the doc is in roadmap/completed). This item
is the *durable* fix — the guard that stops the whole class recurring.

## Why

The `env-builtins-import-soundness` / stdlib-surface-drift class keeps recurring
(email cap, `randomFloat`, `generateId`, `Dict.delete`, `newId`, `mapCheck`,
`randomInt` arity — all 2026-07-06) because a stdlib name lives in several
hand-maintained tables that drift: the `Type_system` import allowlist
(`tesl_module_exports`), the `stdlib_env` type table, and the runtime `.rkt`
`provide` lists. A name present in the first two but missing from the third
**type-checks then crashes at Racket load with "unbound identifier"** — invisible
to the gate because no example happens to use it.

`test_capability_registry.ml` already pins the *capability-charge* table against
an oracle, and `test_fail_closed_hardening.ml` pins builtin-caps ≡ stdlib
providers. The missing guard was **binding existence**: name → real runtime
provide.

## What was built

Key simplification found during implementation: the runtime modules `provide`
the dotted Tesl names **verbatim** (`Dict.delete`, `String.trim`), and
`emit_requires` binds every `exposing`-imported name with
`(only-in <module_path_table[M]> name …)` after filtering the compile-time-only
list. So no name mangling is involved — the seam is exactly:

1. **Expected set (OCaml, derived — nothing hand-listed):**
   `expand_import_names(tesl_module_exports[M])` ∪ the
   `stdlib_bare_home_module` rows, minus
   `Emit_racket.config_only_import_names` (the list was lifted from a local in
   `emit_requires` to an exposed top-level so the test filters through the SAME
   value the emitter uses — no copy drift). `Tesl.Json` is excluded: the
   emitter lowers its codec names inline and skips the require wholesale.
2. **Actual set (Racket, ground truth):** a generated script calls
   `(module->exports (file <path>))` per module (declared via
   `dynamic-require … (void)`, never instantiated) and dumps every **phase-0**
   export, variables and syntax — correctly counting re-exports
   (`all-from-out`, `struct-out`, the list.rkt→list-prim/list-derived shim
   chain) a grep of `provide` forms would miss.
3. **Assertions:** every exported/known module has a `module_path_table` row;
   every row's `.rkt` file exists on disk; expected ⊆ actual, failure listing
   every `module / path / name` offender.

Racket missing from PATH → the provide-existence case self-skips with an
explicit `SKIP` line (same convention as ci.sh's optional-dependency phases;
the pure-OCaml table/file checks always run, and the authoritative gate runs
with racket present).

## What it caught immediately (all fixed 2026-07-07)

Writing the test surfaced **13 live instances** of the class in the current
tree, each verified end-to-end (typechecks, emitted Racket fails to load):

- **5 dead modules** — `Tesl.Bool`, `Tesl.Crypto`, `Tesl.Map`, `Tesl.Channel`,
  `Tesl.Sql` were in `tesl_known_module_names` + `module_path_table` but their
  `.rkt` files **do not exist**; `import Tesl.Crypto` typechecked then crashed
  the generated module with "cannot open module file". Fixed fail-closed:
  removed from both tables, so the import is now a compile-time
  "unknown stdlib module" error. (The dead `Tesl.Json → tesl/json.rkt` path
  row was also dropped; json.rkt doesn't exist and the emitter never requires
  it.) The FIX-004 late-import test that mentions `Tesl.Bool` still passes —
  its error fires at parse, before module resolution.
- **8 phantom bindings** — `cache`, `Cache.get/set/delete/invalidate`,
  `EmailBody`, `Email.send`, `startEmailWorker` are importable
  (`tesl_module_exports`) but are parser-rewritten surface forms with no
  runtime binding (`ECache*`, `ESendEmail`, `EStartEmailWorker`; `EmailBody`
  is type-only — its `TextBody`/`HtmlBody`/`RichBody` constructors ARE runtime
  values and stay required). Importing any of them crashed the generated
  module at load ("identifier not included in nested require spec"). Fixed by
  classifying them into `config_only_import_names`, the single filter both the
  emitter and the test share.

## Deferred (tracked, not lost)

The optional **cap-coverage** direction (every runtime `require-capabilities!`
site has a matching `stdlib_capabilities` charge and vice versa) is NOT folded
in: the Tesl.ApiTest queue helpers (`drainQueue` etc.) are intentionally
uncharged and the charge-vs-restrict question from
[[stdlib_surface_binding_drift]] (Class B) should be decided first.
`test_capability_registry.ml` + the emit-side guard-parse in
`test_sql_crossseam.ml` cover the highest-risk part of that surface today.

## Verification

- Test passes on the tree after the 13 fixes above.
- Proven to BITE both ways:
  - name direction: temporarily commenting out the `Dict.delete` provide in
    `tesl/dict.rkt` turns the test red naming exactly
    `Tesl.Dict tesl/dict.rkt Dict.delete`; restored.
  - file direction: the 5 dead-module rows were caught by the
    file-existence case on the test's very first run.
- `./ci.sh` green.
