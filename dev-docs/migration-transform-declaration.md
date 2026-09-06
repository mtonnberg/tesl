# Checked transforming declarations

> Audience: contributors implementing and verifying the migration source checker.

The source checker now accepts a bounded `Migrate rowFunction rules` and
`Derived rules` vocabulary in a family's adjacent migration declaration. This
is an internal compiler prerequisite. A PostgreSQL application containing any
retained transforming edge still cannot be built: physical expansion rejects
`Transform` and `Reset` before deriving any installation origin. Selecting a
fresh installation at a later version cannot bypass that refusal.

`Migrated a = Row a | Reject String` remains an ordinary result type. Pure
migration functions and their Tesl tests can compile and run independently of a
Database. The tests in `compiler/test/test_migration_transform.ml` exercise actual
emitted Go under the race detector after removing every Tesl source file.

## Source judgment

`Migration_checked_graph` supplies the shared checked source graph for inventories
and the forthcoming transform linker. It preserves the original AST objects and
their inferred types, checks the complete captured import closure, and lowers
those objects afresh under explicit Snapshot, From or To roles. Private codecs
and fact producers remain part of semantic closure. Unlowered declarations,
including ordinary constants, are refused explicitly. This extraction preserves
the pre-existing inventory digest; it does not produce an executable callback.

`Migration_declaration` binds the sparse entity inventory and passes its exact
checked pair to `Migration_transform_rules`. `Rename oldField newField` requires
an old-only source, a new-only destination, and an unchanged stored contract.
Table and primary-key changes are refused. Unchanged fields retain their stored
contracts; changing a proof or JSONB codec is not an identity operation even if
the SQL column type remains the same. Rule conflicts, undeclared old-field
removal, and missing `Same` dependency evidence remain errors.

`Migration_transform` checks each requested row function in its declaration's
own import scope. A function must be an ordinary, monomorphic, capability-free
`fn` with exactly one unproven `From.E` argument and a `Migrated To.E` result.
The entity owners must match the exact adjacent inventory. Local functions and
functions exported by a direct import in the same migration family are accepted;
qualified and explicitly exposed spellings bind the same identity. Lambdas,
function aliases, application functions, and another family's helpers are refused.

Every successful return must contain a complete target entity literal. The
checker follows every conditional/case branch and the tail of local bindings.
A renamed field must be exactly `old.oldField`; an unchanged field must be exactly
`old.field`. Aliasing a projection, changing it and changing it back, shadowing
the original row argument, or hiding the complete result behind a helper cannot
establish that identity. A declared `Default` must also appear as that exact
primitive literal, including arbitrary-size signed integers. Newly computed
fields use ordinary type and proof checking. `Reject reason` supplies no row.

The full ordinary frontend checks every captured module, including helpers and
tests. A separate traversal follows named executable dependencies with lexical
and declaration-owner scopes. Direct HTTP failure, user `check` helpers, and
stdlib check-shaped functions are refused, including through functions and
constants. An optional `establish` can return a newly proved field or lead to an
explicit `Reject`; proof authority stays with the schema's fact owner.

Every `Migrate` entry requires at least one parameterless fixture function
returning its exact previous entity. Duplicates, unrelated entities, and functions
with arguments are refused. These are representative source fixtures, not yet
the full generated compatibility, dual-write, decoder, or PostgreSQL harness.
`Derived` has no user row callback: its descriptor retains the compiler-owned
identity/default/empty-optional mapping.

The descriptor retains the original parsed function/owner AST, exact checked rule
mapping, fixture bindings, and complete raw source preconditions. Dependent
frontend checks run in one captured source view, so a helper importing the root
sees the supplied root buffer instead of an older saved signature. Changed input
bytes refuse publication. Present history seals continue to use their existing
source integrity checks.

## Explicit remaining boundaries

A source descriptor is not a linked callback, a physical generation assignment,
or persisted execution authority. It has **no semantic callback hash**. Raw source
hashes cannot substitute for a typed semantic closure.

The next compiler judgment must elaborate the bound original AST with
`Checker.check_module_with_typed_nodes` and `Migration_ir.define`, using exact
`From`/`To` scopes and the recorded compiler ABI decision. Its transitive closure
must include referenced functions, types, codecs, and fact producers. The callback
registry must bind the resulting semantic descriptor hash to the generated
old/new structs and function. This work must precede emitting executable callback
metadata. The ABI of a partially processed persisted migration cannot change
merely because the source can be checked by another build.

Verified `Same` currently establishes stored-contract equality for the rule
mapper. It does not inject cross-version nominal type or proof transport into the
ordinary frontend. For example, copying `old.title` from `From.ValidTitle` to an
otherwise identical `To.ValidTitle` remains refused even with a valid `Same`
claim. The regression preserves this boundary. A narrowly scoped checked evidence
context is needed; renaming proof owners or introducing a general cast would be
incorrect. The positive optional-proof scenario adds a **new** proved field while
copying existing fields unchanged; it does not claim existing proof strengthening
is implemented.

`Retype`, `Revalidate`, `Legacy`, `LegacyWith`, `WriteBack`, reset execution,
callback linking, persisted row generations, lazy reads, backfill, concurrent old
writes, dual writes, and contract cleanup remain separate required judgments.
The source checker neither installs storage nor changes database admission.
