# Checked Contract source and compiled receipt identity

> Audience: compiler and runtime contributors implementing and reviewing database migrations.

`Migration_contract` checks explicit source authority for the difference between
one checked transforming window and its exact settled physical description.
The opaque checked value is neither a final-generation proof nor permission to
raise a database floor. Those facts belong to the protected runtime protocol.

The source command is entry-first:

```sh
tesl migrate contract app.tesl --version 2
tesl migrate contract app.tesl --version 2 --manifest-json
```

The first command applies the normal guarded source-write manifest. The second
returns the same reviewable proposal without writing. The output is the canonical
`migrations/<family>/v2-contract.tesl` companion module. An existing file is never
overwritten. The proposed source receives ordinary standalone and implicit
application diagnostics; stale selectors produce `MIG022` with the exact expected
selection. Generate and review the Contract before building the rollout binary.
It is embedded in that binary; later contraction does not require re-reading the
source tree.

The source permits only `contract = Contract { of, drops, tighten, promote }`,
imports of `Tesl.Migration` and its exact migration root, and literal object lists.
`Column Entity field` names an old logical field which is absent from the target.
`Storage Entity "physical_column"` names retired physical storage whose logical
field survives a Retype. `Index Entity name`, `Trigger Entity`, and
`NotNull Entity field` select the other supported differences. Selection order is
irrelevant, but duplicate, missing, foreign, or surplus selectors refuse.
Promotion and other constraint kinds still refuse until their checked execution
protocol exists. A purely additive revision needs no empty Contract.

The compiler derives a required `relax-retired-nullability` prefix for obsolete
NOT NULL columns, with exact before/after descriptions. After retirement and
finality, the runtime completes this prefix while requests still use the window
projection. Only then may a protected receipt select settled inserts. Later
drop-column operations name the prepared nullable description. The reviewed
Column/Storage drop authorizes this prerequisite; there is no separate source
selector for arbitrary nullability relaxation.

The remaining deterministic operation sequence covers old indexes,
invalidation pairs, old columns, nullability tightening, and insert-generation
defaults. Marker defaults follow from the selected contraction and are always
included without an additional source selector. Trigger identity is logical
entity plus exact generation; arbitrary SQL trigger/function identifiers cannot
be authorized by the source. The settled plan retains only current columns,
current indexes, logical nullability, and current marker defaults. It has no
active windows, rename aliases, or reverse-write obligations.

Each `NotNull Entity field` derives four contiguous internal operations:
`add-not-null-check`, `validate-not-null-check`, `set-not-null`, and
`drop-not-null-check`. The first operation creates the exact physical-column
`IS NOT NULL` check as `NOT VALID`; validation changes only its validated flag.
The check remains present during SET, allowing PostgreSQL to prove null absence
without a second heap scan. Its removal is a separate operation and receipt.
Validation permits concurrent ordinary writes; the other stages need short
exclusive catalog locks. This is the common PostgreSQL 14–18 path.

The proof descriptor is `[not-null-check, name, physical-column, validated]`;
absence is `[absent]`. Add, validate and drop carry exact before/after proof
descriptors, while SET retains the existing full before/after column descriptors.
The deterministic name is `tesl_nn_` plus the first 48 hex digits of the Contract
domain hash of `[tesl-row-not-null-name-v1, family, namespace, version,
window-hash, entity, physical-column]`. The already checked window hash avoids
recursive dependence on the Contract hash. Runtime derives this same inventory
and rejects consistently renamed or reordered proof stages even if their public
hash is recomputed. Only SET carries the existing source selector; generated
source, old-column preparation ordering and preparation count are unchanged.

The canonical `Contract` domain contains the `tesl-row-contract-v1` tag, family,
namespace, target revision, target snapshot hash, checked behavior hash, exact
window and settled hashes, sorted final-generation requirements, and the complete
ordered operations. The settled document uses the existing Migration domain with
its distinct `tesl-settled-physical-version-v1` tag. Compiler ABI is execution
provenance in the envelope, separate from checked behavior compatibility.

`Migration_program` discovers and captures Contracts through the same complete
source graph and publication guards as the application history. The private Go
initializer registers the source history, then physical plans, then the complete
`compiled-row-contract-history` envelope. Every database appears, including those
with no Contract. The runtime must bind exact existing source/physical owner
pointers and independently compare the whole derived operation inventory before
publishing any settled pointer. Canonical hashes detect substitutions; they do
not attest arbitrary Go code or turn an unbound description into authority.

Starting the next source revision freezes the current Contract's presence and
raw dependency closure inside the existing frozen-migration source seal. Editing,
deleting, or adding that companion after the next revision starts is `MIG013`.
Prepare the Contract first; restore completed files and make a forward revision
instead of rewriting reviewed history. Transform type checking still excludes
Contract declarations from executable helper graphs.

Regression coverage is in `test_migration_contract.ml` and the native CLI
`migrate_contract_linux_test.go`. It includes checked compute/Rename/Retype
inventories, freshly rehashed missing operations, compilation with all sources
removed, source/directory/pin drift, frozen presence, malformed final record
fields, and preview/write/overwrite behavior. Runtime lifecycle receipts,
backfill, floor fencing, and contraction DDL are tested by their own protocol
suites; successful source generation proves none of those runtime facts.
