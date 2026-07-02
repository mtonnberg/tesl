# Remove the `library` language feature (shrink the surface)

## Why
The `library` keyword was a stricter variant of `module` with a compile-time
boundary (logic-only: no api/server/main/queue/database/entity; exported
signatures must export everything they reference as a HARD error; re-export
authority rules). It also drove the LB-01 review finding (bare `import Mod` not
enforcing `exposing` for facts). Code sharing is moving to **stable artifacts**
(no GitHub / package-manager dependency), which makes the `library` concept
redundant — so the feature is removed to shrink the language and the surface that
can break. `module` + `import` (ordinary reuse) remain; **fact ownership** (only
the declaring module may mint a fact — the actual soundness) is module-general and
untouched; the **W080** module-signature-completeness lint stays.

## What was removed (2026-07-02)
- **Lexer/token:** the `library` keyword / `LIBRARY` token (`library` is now an
  ordinary identifier again). `lexer.mll`, `token.ml`.
- **AST:** the `module_form.is_library` field. `ast.ml`.
- **Parser:** the module header now accepts only `module` (`parse_module_header_body`).
- **Validation:** deleted `check_library_self_boundary` + `check_imported_module_is_library`
  (validation_structural.ml) and the library-only `check_exported_signature_completeness`
  (validation_names.ml); unwired from `validation.ml`.
- **Tests:** deleted `test_library_boundary/negative/suite/syntax.ml` and
  `test_review74_sig.ml` (all were library-feature tests); ME07 in
  `test_review74_misc.ml` flipped to a positive (importing a module that contains
  app infra is now allowed — its infra is simply ignored).
- **Examples:** deleted `lesson62-building-a-library`, `lesson63-library-proof-ownership`,
  `lesson64-re-exporting-from-libraries`, and `example/library-examples/`.
- **Docs:** LANGUAGE-SPEC.md §10.7 + `library`-keyword mentions removed (ToC gap
  left at 10.7 — §-numbers are a stability contract); manual/tour/overview/FAQ/
  best-practices purged; `embedded_docs.ml` regenerated.

## Re-export removed too (2026-07, follow-on)
With libraries gone, **re-export** (a module exporting a name it merely imported)
is redundant, so it was removed as well: `all_known_names` in
`check_module_with_metadata` (checker.ml) no longer includes imported-exposed
names, so a module may export ONLY names it declares locally — exporting an
imported name now fails with "module exposes unknown or non-local name `X` (only
locally-defined names can be exported)". Verified: a module re-exporting an
imported fn/type is rejected; the corpus (90+38) still compiles (no legit
re-export existed). Two proof-identity tests that had asserted re-export *works*
(`ME10 re-export type`, `pos_chain_legit_use`) were flipped to assert it is now
*rejected*; the negative re-export-bridge fact-forgery tests still pass (forging a
foreign fact through a bridge is impossible a fortiori now that the bridge can't
be built). The dead fact-ownership re-export branch (checker.ml single-owner
logic) is left in place (now always empty — harmless).

## Result
LB-01 is now **moot** (no library boundary to leak). Corpus green: **90 examples +
38 tests** pass; `--check-all example` = 90/90. `embedded_docs.ml` auto-regenerates
via a `(mode promote)` dune rule on build. Removing §10.7 broke **no** spec-anchor
citation (verified: the 9 `test_spec_anchors` offenders are all §3.1/§3.2, none
§10.7). The `library_exposing_facts.md` roadmap item was deleted.

### Pre-existing gate note (NOT caused by this change)
`test_spec_anchors` fails on **9 unresolved §3.1/§3.2 citations** from the baseline
SQL-provenance tests (`test_a2_sql_provenance.ml`, `test_a2b_update_provenance.ml`,
commit adb5af1) — those cite spec §3.1/§3.2 which have no headings (§3 has no
subsections). This predates all review work and is unrelated to the library
removal; flagged here for accuracy. The other pre-existing gate failure is
`elm-proof-surface` 3/5/8 (also baseline).
