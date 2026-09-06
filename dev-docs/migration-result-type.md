# Migration row result prerequisite

> Audience: contributors implementing and verifying typed migration results.

`Tesl.Migration` exports the ordinary ADT `Migrated a = Row a | Reject String`.
`Row` preserves the exact payload type and its existing proof obligations;
`Reject` carries only a reason. Both constructors participate in ordinary import
gating and exhaustive matching. They are not contextual declaration markers.

The Go representation lives once in `teslrt`, so functions and nested results
cross generated module boundaries without distinct nominal Go types. Its zero
value is rejection, never a fabricated successful row. Generated source embeds
this runtime with the rest of the compiled program.

This prerequisite enables ordinary pure helper calls and tests. It does not
register a backfill callback, increment an entity generation, or admit a database
migration. The separate [source checker](migration-transform-declaration.md)
validates bounded `Migrate` and `Derived` declarations. Physical execution still
refuses every retained transformation. No partially executable plan is emitted.

The source checker establishes the exact adjacent `From.E -> Migrated To.E`
function pair, pure closure, compiler-owned rename projections and unchanged
field copies; typed callback linking remains pending. The execution model records the producing compiler ABI; this
result type introduces no frozen stdlib or retained lowering requirement.

`test_migration_result` executes generated row functions across historical and
current schema modules, including an `establish` returning `Maybe (Fact P)`
and an explicit proof attachment,
rejection, nested generic results and both import forms. Source files are removed
before the Go tests run. Negative checks cover wrong result payloads, invalid
rejection reasons, missing cases/imports, raw proof fields, wrong entity owners
and contextual declaration values.

The direct optional attached-value form `Maybe (v: T ::: P v)` now transports
the successful payload's proof consistently through case branches, record
construction, proof decomposition and forwarded results. The result may differ
from the input, even when both binders have the same spelling. Its proof never
establishes a fact about that input. `test_optional_attached_transport` executes
the imported schema converter using `Row` and `Reject`, with source files removed
before execution. Its 23 groups pass, including two actual Go race tests.

Ordinary attached returns have a different identity contract: a return binder
that names an input must preserve that input on every returning branch. A
transformation uses a fresh result binder, whose witness proves only its actual
result. Fully applied identity calls and value aliases preserve subjects; partial
calls carry neither a result identity nor its returned proof. Nullary `()` calls
retain their actual returned evidence. The 19-group
`test_attached_input_identity` suite covers these boundaries, including the
previously accepted detached-witness forgery and an emitted Go race execution.

The existing callback metadata limitation for an aliased producer function still
refuses some valid calls. Optional value aliases and forwarding are covered;
this fix does not introduce generic callback metadata support.

Imported polymorphic helper calls also have a separate Go emission limitation.
The native witness uses an exact monomorphic row function across modules and
local generic wrappers for nested results; it does not widen that existing
compiler boundary.
