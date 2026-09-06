# Queue control format 4 candidate (unpublished)

> Audience: contributors implementing and verifying protected queue storage.

This is the storage prerequisite for protected versioned queues. Production
installation still creates format 3; the public upgrade API/CLI still supports
only the explicit 2 → 3 bridge. Production readers/openers reject candidate 4,
Worker queues remain refused. The private candidate installs closed inventory
registration functions; production commands cannot install or open it. Format 4
must not be published until its
complete function catalog, admission, runtime registration, claim/dead-letter and
retirement protocol are reviewed and tested together. Adding protected functions
later to an already published format number would change that format's contract.

The private `pgInstallQueueCandidate` and `pgUpgradeQueueCandidate` helpers exist
for native tests and subsequent implementation. They are not application APIs.
The installation helper shares the existing installer transaction and lock path:
new base control objects, queue objects, original inventory, baseline capability,
UUID/fence/origin and format selector commit together. A table-creation or final
verification failure rolls everything back. An existing format 3 database can
never enter the complete-baseline branch, even if its current source is empty.

## Authority and provenance

There are three separate facts:

- Checked linked source describes a complete inventory, including an explicit
  empty inventory, for every linked version/origin.
- Source seals can be complete, unknown, or unrecorded. This records source
  provenance, not a fact about what was deployed.
- The database's protected baseline is either **complete** from a genuinely fresh
  installation or **unknown** from an explicit metadata upgrade.

A candidate fresh installation persists one complete origin inventory and its
semantic digest. Candidate 3 → 4 upgrade persists unknown and zero inventory rows.
No current seal, fresh compilation, catalog absence or retry promotes unknown.
The upgraded database preserves its prior lifecycle/ABI/entity rows, UUID, fence
and origin. Existing object names, including a legacy `tesl_jobs`, cause refusal;
there is no automatic adoption, truncation, renaming or old-wire-ID conversion.

The semantic inventory digest is SHA-256 of the existing canonical length-framed
migration encoding (`s<UTF-8 byte length>:bytes`, `l<element count>:elements`):

```
Seq [ Bytes "tesl-queue-inventory-v1";
      Bytes family;
      Bytes decimal-version;
      Bytes storage-snapshot-hash;
      Bytes schema-snapshot-hash;
      Bytes stored-value-compatibility;
      Seq [ Seq [Bytes queue; Seq payloads] ... ] ]

payload = Seq [ Bytes family-relative-job;
                Bytes "tesl-queue-payload-v1";
                Bytes full-canonical-contract-bytes;
                Bytes contract-hash ]
```

Queue and job identities are strictly sorted; duplicate membership or reordered
input is refused. Empty inventory is `Seq []`, not omitted metadata.
`storageSnapshotHash` and `schemaSnapshotHash` retain their distinct compiler
hash domains. Family-relative queue/job identities and full checked closures are
semantic. App/database binding names, namespace, creator compiler ABI and source
seal provenance do **not** participate in this digest. The database namespace and
UUID are separately checked as installation identity. Renaming an application
binding does not require moving or migrating its queue data.

Original creator compiler ABI and source seal provenance are persisted and never
relabelled by an observer. Pending initial expansion stays pinned to its creator
ABI. Completed compatible compiler B may read/retry compiler A's installation;
A's recorded inventory creator must still match the actual initial expansion
intent. A later freeze can change linked V1 provenance from unrecorded to complete
without changing its payload contract or overwriting the original stored marker.

The companion and digest are compiler-authored metadata. Runtime checks framing,
self-hashes, graph consistency and persisted bindings; it does not attest a binary
or independently prove arbitrary Go encoder semantics. The existing shared-login
`tesl_admit(v)` threat model remains unchanged. Ordinary request/worker roles have
no direct queue table writes. Request roles cannot register source inventory;
worker roles can call only the closed checked registration protocol described below.

## Candidate storage and inspection

`migration_queue_control_spec.go` defines five control-owned tables:

| Table | Purpose |
| --- | --- |
| `tesl_queue_baseline` | Explicit complete/unknown origin capability |
| `tesl_queue_versions` | Complete per-version counts, both snapshot hashes, semantic digest and creator provenance |
| `tesl_queue_contracts` | Queue identities and exact membership counts |
| `tesl_queue_payloads` | Job identities, canonical closure bytes and digest |
| `tesl_jobs` | Protected payload version, attempt/claimant/transaction/lease fields and typed dead reason |

The jobs table has protected SQL operations and a private runtime dispatcher.
It keeps `claim_seq`, opaque `claim_token`,
`claimed_by_version`, DB-derived `claim_xid`, `lease_until`, source version, and
visible dead/quarantine reason fields. SQL constraints require claim fields to
be present only while processing and explicitly reject NULL dead reasons for dead
or quarantined rows. The transaction lease exception compares the stored
transaction ID in PostgreSQL and accepts no caller-supplied ownership flag.

`migration_queue_control_expected.go` independently describes the expected
catalog. It does not parse or execute the creation descriptors or live defaults.
It verifies full columns/checks/indexes, exact permitted grants, identity sequence
owner/shape/namespace/name/ACL, and complete foreign-key targets/actions plus all
four corresponding PostgreSQL RI enforcement triggers. Disabling triggers,
retargeting a same-shaped FK, granting column reads, grant options, or exposing the
payload table to a request role is drift. Read-only inspection needs neither TEMP
nor CREATE and does not select payload rows.

## Immutable per-version registration

The private `pgQueueCandidateControlFunctions` catalog retains the format 3
functions, strengthens only candidate `tesl_record_expanded`, and adds closed
worker-only inventory validators and `tesl_register_queue_inventory`. Production
format 3 definitions remain unchanged. Candidate installation and explicit upgrade
create the entire function catalog in the same transaction as the five tables and
format selector; read-only inspection checks exact bodies, signatures, volatility,
ownership, search path and grants.

`pgRegisterQueueCandidateInventory` selects a version from the linked checked
origin and calls the SQL protocol with family, both snapshot hashes, original
compiler ABI, storage compatibility, source-seal provenance, semantic hash and the
complete inventory. Its JSONB shape contains only:

```
[{"queue":"Notifications","payloads":[
  {"job":"Notify","contract":"<lowercase canonical hex>",
   "contractHash":"<SHA-256>"}]}]
```

No source SQL, role, connection, handler or application binding name enters the
SQL API. Objects must have exactly those fields; arrays must be sorted and unique,
queues nonempty, and a payload identity may belong to only one queue. JSONB object
keys are normalized by PostgreSQL; the compiler companion separately rejects
ambiguous raw JSON. PostgreSQL independently validates canonical byte framing,
payload hashes and the complete inventory digest using the same length framing as
Go. It does not interpret or certify arbitrary user-supplied codec semantics.

Registration requires READ COMMITTED and locks the control-state row before
reading the persisted prefix. The supplied family must reproduce the protected
fresh-origin digest: there is no unanchored family registration. Every persisted
version needs complete counts, a valid digest, the original compatible creator
intent, contiguous order, and unchanged earlier payload identities/closures.

A new inventory must be exactly `current + 1`, follow a completed origin, and
match the pending expansion intent's storage snapshot, creator ABI and storage
compatibility. The whole inventory is one statement and transaction; no partial
append/finalize state exists. Removing, renaming or moving a payload, or changing
its shape, proof or codec closure, requires a future jobs migration protocol and
is refused. New queues and new job identities may be additive.

Exact semantic replay preserves stored creator ABI, source-seal provenance and
registration timestamps. Before the first intent exists, only an exact replay of
the fresh installation origin is allowed, pinned to its original compiler. A
pending inventory remains pinned; after completion, a compatible compiler may
replay the same semantic inventory without relabelling provenance. Candidate
`record_expanded` refuses publication unless its complete inventory matches the
immutable expansion intent.

Go's read-only observer independently reconstructs and validates all stored
inventories without executing worker-only helpers or reading job payloads. It
compares checked source only for the prefix known by that binary, while validating
future counts, canonical contracts, digests, intent bindings and preservation of
existing payloads. Thus an admitted V1 node can restart after additive V3; metadata
inspection itself grants no claims or access to V3-only jobs.

**An upgraded UNKNOWN baseline cannot register even an empty old inventory or
publish subsequent expansion in candidate format 4.** This deliberate unpublished
boundary requires a future adoption or prospective-inventory protocol before
format 4 can be released. Empty tables, a fresh source seal and a valid hash are
not evidence about old deployed binaries. Production format 3 entity-only
migrations remain available unchanged.

These prerequisites do not enable claims, add jobs migration syntax, authorize
legacy adoption, or make cache/email/SSE safe on the protected topology.

## Regression evidence

The native suite covers fresh empty/nonempty complete baselines, unknown upgrade,
all-or-nothing install/retry, source omission, old format and unsupported public
upgrade refusals, creator ABI and first-freeze provenance, renamed app/database
bindings, quoted namespaces, direct grant denial, malformed catalog/ACL/FK/trigger
and inventory state, and a fixed canonical digest vector.

Tagged tests terminate the real PostgreSQL installer backend after each created
table and around inventory/commit boundaries for both fresh installation and
upgrade. Retrying must preserve the committed identity or create one complete
fresh state; an upgraded baseline remains unknown. Existing format 2/3 control,
read-only catalog and bridge tests run alongside these candidate checks.


Registration regressions exercise three actual source versions with additive
payloads, multiple queues, a fresh empty origin, old-binary restart, A/B creator
separation, first freeze, missing or wrong intents, cross-origin/family bindings,
removal/move/closure refusals, malformed/duplicate/unsorted JSON, independent Go/SQL
canonical depth/framing vectors, and function catalog/grant tampering. Even
re-signed future metadata cannot remove an earlier payload. Concurrent workers
produce one immutable winner; real backend termination during payload insertion
and before/after commit leaves either no new inventory or one complete inventory,
and retry preserves the original registration.
