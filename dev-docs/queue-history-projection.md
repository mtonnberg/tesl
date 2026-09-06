# Compiled queue history projection

> Audience: contributors implementing and verifying compiled queue inventories.

The compiler emits `queue-history.json` for each build containing a versioned
PostgreSQL database, including builds whose queue inventory is explicitly empty.
The identical bytes are linked as a Go constant in
`internal/teslrt/migration_history_generated.go`. Neither runtime registration nor
inspection reads the loose JSON file or a source checkout. The existing strict
`compiled-migration-history` v3 envelope remains unchanged for bridge readers.

The companion envelope is version 1, kind `compiled-queue-history`, with the
actual `compilerAbi`, `storedValueCompatibility`, and sorted `databases`. Every
database has its existing `database`, `family`, `namespace`, `currentVersion`, a
consecutive `versions` inventory from V1, and all `origins` from V1. An origin has
`initialVersion` and the exact consecutive inventory version references through
the current version. Inventories are stored once so different origins cannot
carry conflicting copies. Refused expansion origins still have source inventory;
reading it does not make that installation origin executable.

Each version has these fields:

| Field | Meaning |
| --- | --- |
| `version` | Numeric schema version, including initial V1. |
| `storageSnapshotHash` | Existing storage description digest: semantic inventory plus storage mapping. Must match every linked expansion origin. |
| `schemaSnapshotHash` | Canonical Snapshot digest of the full checked semantic inventory, in its separate domain. |
| `checkedInventory` | Literal `complete`; a compiler assertion about the source it checked. Includes empty inventories. |
| `sourceSealInventory` | `complete`, `unknown`, or `unrecorded`, preserving every recorded source seal's provenance. |
| `contracts` | Sorted contracts, each with family-relative `queue` and sorted `payloads`. |

Each payload contains its family-relative `job` declaration identity,
`contractFormat: "tesl-queue-payload-v1"`, the full lowercase hexadecimal
`contract`, and `contractHash`, SHA-256 of those exact decoded bytes. The bytes
are the existing length-delimited Migration canonical document in the Contract
domain, containing `["queue-payload-v1", checkedPayloadClosure]`. That closure
includes nested records/ADTs, proofs, producers/helpers and codecs. The reader
checks canonical framing and domain, exact bytes/hash agreement, sorted unique
ownership, and identical pre-existing payload contracts across revisions. Only
new identities can be added until jobs transformations exist.

## Three different judgments

A new compiler can completely inspect source whose earlier source seal did not
inventory queues. Such a version has `checkedInventory: "complete"` and
`sourceSealInventory: "unknown"`. An initial V1 with no migration edge has
`sourceSealInventory: "unrecorded"`. Newly checking or resealing that source is
not evidence about an already deployed V1 database.

Neither field means that the **persisted installation baseline** was inventoried.
The companion contains no persisted capability, adoption permission or queue
claim authority. A future fresh format-4 installation must record baseline
completeness under the protected installation protocol. A format-3-to-4 metadata
upgrade must preserve unknown baseline authority, even if present source is
complete and empty. Explicit adoption remains a separate operation.

An old binary has no companion. `QueueSourceInventory` returns an explicit
missing-metadata error, never an empty inventory. This accessor is for checked
source metadata only; boot, expansion, installation origin, persisted history,
admission and job claiming each retain their own independent checks.

## Registration and codec ownership

Generated runtime initialization validates the complete companion against every
linked database and every origin before publishing any family. Conflicting
registrations and malformed, omitted, duplicated or reordered fields fail
without partially publishing the database set. Accessors reparse immutable
linked bytes and return independent copies.

`RegisterQueueSchema` binds the actual queue pointer to its registered database
pointer, linked family, current version and frozen contract. A contract has one
queue owner. `RegisterQueueSchemaJobCodec` registers each payload's checked
identity, closure hash and actual encoder/decoder together. Missing members,
wrong database/contract/version, duplicate codecs, and attempts to overwrite a
checked codec through ordinary registration fail. `QueueSourceCodecs` returns
only a complete set. App names and handler bodies are outside payload identity.

A schema-owned record without a codec gets its derived decoder in its owning
module; the compiler follows checked payload dependencies into nested schema
records. A proof-bearing record requires an explicit checked codec so a derived
decoder cannot manufacture proof evidence. These codec bindings do not modify
legacy queue/job wire names or enable cross-version decoding or claims.

Worker facilities and runtime storage entry points keep their existing refusal.
Other durable facilities, protected queue storage, format-4 installation,
version-aware claiming and retirement remain separate work.

## Regression evidence

Compiler tests cover initial V1, explicit empty inventories, legacy unknown seals,
freeze/refresh stability, additive identities, renamed app/handler bindings,
source races, nested prefixed codec ownership and proof-bearing decoder refusal.
A generated Go binary test deletes both loose history JSON files, inspects linked
metadata and round-trips a payload through the actual registered codec.

Runtime tests cover every linked database and origin, failed atomic publication,
missing fields, unknown capabilities, malformed canonical bytes, rehashed old
payload changes, ordering and duplicates, codec ownership and overwrite refusal,
concurrent registration, immutable accessors, and ordinary Memory/unversioned
codec behavior. These tests provide no evidence of safe mixed-version claims;
the protected runtime protocol needs its own PostgreSQL tests.
