# Compiled queue history projection

> Audience: contributors implementing and verifying compiled queue inventories.

The compiler emits `queue-history.json` for each build containing a versioned
PostgreSQL database, including builds whose queue inventory is explicitly empty.
The identical bytes are linked as a Go constant in
`internal/teslhistory/migration_history_generated.go`, a generated package
that registers the history with the runtime before any application package
initializes. Neither runtime registration nor
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

Generated runtime initialization checks the companion's integrity and identity
against every linked database, validates its serving window (see below), and
then publishes every family in one step. Conflicting registrations and
malformed, omitted, duplicated or reordered fields fail without partially
publishing the database set. Each document is decoded once per process; the
validated form is shared and immutable, and accessors return independent copies.

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

## What startup validates

The linked history grows by one release per release (about 90 KB in the
twenty-release example). A process that only serves requests must not pay for
every past release on each start, so validation is split by need. The rule is
implemented and documented in
`runtime/go/teslrt/migration_history_registration.go`.

**At registration** (Go package initialization, before a database opens), for
every companion (source history, queue, row transforms, retained physical rows,
Contracts):

| Check | Covers |
| --- | --- |
| Integrity | UTF-8 and the complete JSON string/bracket structure of all bytes; a SHA-256 digest names the document |
| Identity | Format, kind, compiler ABI, stored-value compatibility; each database's name, family, namespace, current version and version count |
| Serving window | Full validation of every part a request process reads |

For a database at version N the serving window is:

- **V1**, the fresh-install anchor. Startup compares the persisted baseline
  (tables, queue inventory, catalog hash) byte for byte with it.
- **V(N-1) and VN**: source schema and storage, physical row plan (VN bound to
  V(N-1); V1 bound as the origin), current-row codecs, the transforms targeting
  VN and their exact generation transitions, VN's queue contracts, the VN queue
  transition, and Contracts for V(N-1) and VN.

A history with at most three versions is entirely inside the window and is
validated completely at registration, exactly as before.

**At startup of a Worker-topology request process**, versions the database
has recorded are compared with the linked bytes of the same version: the
physical plan's contract and hash text and the queue inventory hash. Planned
stage cancellations, which mark recorded index jobs, are read from the linked
physical documents whose format can carry them (recognized from their leading
bytes). Their contents are not validated again; the schema command that
published them did.

**Everything else** is validated at most once per process, when first needed:
older schema snapshots, physical plans, transform descriptors and callback
types, queue inventories, Contracts, installation origins and every
cross-release rule. Every mutating schema command (`install`, `deploy`,
`worker`, `catch-up`, `contract`, `close-epoch`), `InstallPgCompiledRowBaseline`,
`ExecutePgCompiledRowBaseline` and every Embedded-topology process (which runs
schema steps itself) validates the complete history before it changes the
database. A fresh install from V1 therefore pays the full check once, in the
command that replays it.

An accessor asked for a part outside the window validates the complete history
first; it never returns an unchecked historical part. An older transform's
callback is bound at initialization but its descriptor and Go types are checked
before it runs or its storage is used. So an error in a part a serving process
needs fails at registration, before anything is published, and an error in any
other part fails the schema command (or the reader) that uses it.

Measured on `example/db-twenty-releases` (V12, ~1.1 MB linked history):
Worker-topology startup of the non-race binary fell from 0.28 s to 0.03 s, and a
race-instrumented test binary that runs no test from 4.8 s to 0.36 s, flat from
V2 to V12. The remaining per-release cost is the memory-speed integrity and
digest pass, about 1.5 ms per MB. `TestLazyHistoryServingStartIsBoundedByTheWindow`
asserts that registration and window reads perform the same validation work
for 10 and 200 versions; `BenchmarkLazyHistoryServingStart` reports the time.

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

## Complete row source envelopes

The queue source reader also accepts the internal complete source envelope v4.
It validates every base database, schema/storage snapshot and origin, including
origins explicitly refused for execution. Queue inventories must exactly cover
each snapshot's queue-schema declarations and payload members. Each payload's
single type root and every supplied closure definition must match that snapshot.
The compiler owns semantic reachability and proof checking; the reader checks
identity and definition containment, as the row source reader does.

The existing v3 source route retains its strict all-origin ExpansionPlan replay
and selected-origin refusals. Its format does not contain complete schema
contracts, so it does not acquire v4's stronger snapshot-containment claim.
Complete, unknown and unrecorded source-seal provenance remain distinct from
persisted installation authority, including for a genuinely empty source.

This source projection does not emit or activate queues through the row artifact
route, accept a queue control format in a row opener, or remove the row facility
absence requirement. Mixed row/queue catalog installation, verified legacy
adoption and queue finality before floor advancement remain separate gates.
`test_migration_queue` passes actual captured source envelopes (including a private
codec and frozen history) to pure Go metadata checks after deleting Tesl sources;
its hash-recomputed substitutions must fail before any runtime admission.
