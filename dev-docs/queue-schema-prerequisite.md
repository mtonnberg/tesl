# Frozen queue schema prerequisite

> Audience: contributors implementing and verifying frozen queue schemas.

This records the compiler prerequisite for `roadmap/next/queue-payload-migrations.md`.
Fresh format-5 Worker applications now support unchanged versioned payloads,
fenced attempts and atomic additive-epoch retirement; see
[lesson 95](../example/learn/lesson95-retiring-unchanged-queue-payloads.md).
Changed payloads still refuse public compilation until the transformation and
typed-repair execution protocol is complete.

## Source ownership

A pure schema revision can declare:

```tesl
module Schema.Todo.VCurrent exposing [Notifications, NotifyJob]
import Tesl.Prelude exposing [String]

record NotifyJob { message: String }
queueSchema Notifications { jobs: [NotifyJob] }
```

`queueSchema` is a contextual declaration, represented as `DQueueSchema` rather
than an effectful `DQueue`. Its only field is a nonempty, static list of visible,
schema-owned record declarations. Connections, retry configuration, workers,
handlers, and activation remain in application modules. Existing ordinary
prefixed imports work; a queue contract grants no additional visibility.

The application binds the contract in its ordinary queue:

```tesl
queue Notifications requires [queueRead] = Queue {
  database: TodoDatabase
  schema: Schema.Todo.VCurrent.Notifications
  jobs: [Job Schema.Todo.VCurrent.NotifyJob notify Nothing]
}
```

The existing worker stays in the application, and `main` activates this queue in
`App.queues`. Exactly one application queue may bind each contract in a schema
family, and every payload must occur exactly once in the corresponding `Job`
list. An unused contract, a removed binding, a missing activation, or an extra
binding is MIG028. The initial form requires App activation; imperative worker
startup alone does not establish this compiler judgment. A payload may belong to
one queue contract. Cross-module duplicate membership is rejected even when the
contracts are private.

The initial binding forms are deliberately static: `main` must end in a literal
`App` record, its `queues` field must be a literal list of local queue names, and
`Queue.jobs` must be a literal list containing only complete
`Job <Payload> <worker> <dead-slot>` entries. Imported queue activation is not
supported by the existing App configuration rules. Computed lists, bare payload
members and malformed entries produce diagnostics; they never count as an empty
inventory or disappear from the binding check.

## Canonical identity and comparison

The schema inventory includes queue declarations and sorted resolved membership.
Each payload's closure is the existing Migration IR closure: nested records,
ADTs, newtypes, proofs, fact producers and their helpers, and attached codecs.
`Same` can compare unchanged queue contracts through this complete closure.
The prerequisite also compares every existing payload automatically on every
adjacent edge. Existing identities cannot be removed, renamed, moved between
queues, or changed in shape/proof/codec meaning: those operations fail with
MIG028 until `jobs:` transformations and deliberate dropping are implemented.
New payload identities can be added while predecessors remain intact.

The checked projection exposes family-relative queue and payload declaration
identities. Application variable names, worker function names, handler bodies,
and retry settings do not enter these identities. Generated Go registration now binds actual queue and job codec implementations
with these checked identities. It retains the legacy queue/job wire spellings;
the protected storage/claim protocol must opt into versioned wire identities.
Ordinary unversioned and Memory queues retain their existing behavior. See
[the compiled queue companion](queue-history-projection.md) for the linked metadata
contract and its separation from persisted baseline authority.

## Empty is different from unknown

New v3 source seals record `queue-inventory-v1`, including when there are no queue
contracts. Legacy v1/v2 seals decode with unknown queue inventory. Loading their
source with a newer compiler does not upgrade that fact. Freezing a recorded
target preserves its original completeness marker.

An application with any queue contract requires complete queue inventory across
its entire recorded history. Checking only the newest adjacent pair is
insufficient: a newer empty snapshot could follow a legacy unknown snapshot.
A queue-free legacy chain remains readable, but cannot later use that absence as
permission to introduce versioned queue claiming. An explicit legacy adoption
workflow remains future work. Do not regenerate old seals to manufacture the
missing evidence.

These are source integrity records, with the existing persisted history backstop
still required. They are neither an authentication mechanism nor permission to
claim or transform durable jobs. The compiled runtime companion and protected
installed baseline provide the separate inventory/admission checks.

In particular, an initial deployed V1 may have no source seal. Its first freeze
checks the source visible now; it cannot prove that the deployed application
never had an older queue declaration that has since been removed. Runtime
activation must require persisted baseline inventory evidence or explicit legacy
adoption. A metadata-only control-format upgrade cannot manufacture that evidence.

## Checked payload-conversion source

`Migration_queue_transform` is an internal compiler component for the next
transforming boundary. Its opaque result binds one exact retained queue/payload
identity across adjacent schema revisions. The callback must be an ordinary
pure function of precisely `Old.Payload -> Migrated New.Payload`. Its fixtures
return the exact old record, directly or in the builtin `Maybe`; user-defined
lookalike `Maybe` and `Migrated` types do not qualify.

The complete captured source graph passes the normal frontend, including private
helpers and test bodies. The result's canonical identity binds both explicit
codec closures, both payload contracts, the callback's transitive closure, every
fixture, the compiler ABI and stored-value contract. Schema roles are normalized
so freezing `VCurrent` to its named revision preserves the semantic identity.
New payload proofs must be established through ordinary proof checking.

Source, import-resolution and adjacent migration-directory guards are checked
before and after lowering/publication callbacks. `with_checked` encloses the
side-effect-free artifact construction; callers publish files afterward. A stale
source view never replays the callback. There is no implicit `Same` proof grant
and no permission to restamp a changed job.

Public `Migration.jobs` source checking now consumes this evidence, initially
through directly imported pure helper-module callbacks and exact old-payload
fixtures. It requires explicit coverage of changed retained payloads, rejects
duplicate/unknown/unchanged entries, and keeps source buffers authoritative.
The runtime still needs to bind these exact decoders, encoder and callback to installed source,
claim/finality and typed-repair receipts. A successfully checked pure conversion
does not bypass MIG028, including when ordinary migration diagnostics run inside
its guarded source scope without an explicit decision. Even an explicit checked
decision is refused by physical planning and application builds. The component currently handles a changed payload with
the same queue and job identities; rename, removal and IgnoreOld are separate.

## Generated pure adapters

`Compile.compile_queue_conversion_artifacts` is an internal artifact seam with
no database activation. Ordinary standalone migration compilation now collects
the same checked evidence from `Migration.jobs` and emits the adapters and
fixture tests directly. Both routes guard the complete source during Go emission,
then uses the actual lowering graph and emitted environments to bind types,
codecs and callback symbols, including helper cycles and alpha-renamed symbols.
The runtime source registration validates the closed canonical descriptor and
its source/codec/signature relationships before publishing the entire batch.
Bindings require the exact generated nominal types and named wrapper functions.

The adapter returns immutable converted, rejected or invalid-source outcomes,
retaining original bytes and source identity. Target bytes must decode under
the target codec. Traps, bad result tags and encoder failures yield no usable
output. Generated fixture tests cover direct and optional old records; Nothing
is a named failure, while both Row and Reject are valid smoke results.

This registry is not the application's installed queue binding. Production queue
claims, payload writes, repair records and retirement transitions do not use it
yet; the isolated PostgreSQL candidate below does. Public changed-payload
application compilation still refuses. The standalone
internal adapter artifact includes the PostgreSQL runtime's canonical source
reader, but opens no database connection.

## Typed repair source and execution boundary

The internal `Migration_queue_transform.check_repair` judgment extends a checked
conversion with a numbered repair revision. Revision 1 names the original
conversion; each later revision names the immediately preceding repair. Its
canonical descriptor binds that predecessor digest, revision number, and the
replacement callback/fixture closure. The source and target schema versions,
queue/job identities, payload contracts and codecs must remain exact. A repair
must introduce a callback declaration not used anywhere earlier in its lineage.
Source publication guards include every predecessor; editing the deployed
conversion cannot silently authorize a repair.

`Compile.compile_queue_conversion_artifacts` emits the complete lineage. The
runtime validates all predecessors before publishing the registry batch, even
if descriptors arrive in reverse order. `CompiledQueueConversion.Repair` accepts
only an opaque `migration-rejected` outcome from its exact predecessor, decodes
its original historical bytes, invokes the new checked callback, and encodes and
checks the target value. Another rejection preserves the original bytes and
source version while identifying the new repair revision. A trap, invalid tag
or failed encoding returns no usable result. Ordinary `Convert` cannot bypass
the repair's predecessor requirement. Repair fixture tests execute the full
lineage, so a fixture must actually reach rejection at each predecessor.

Public `QueueRepair` declarations now feed this judgment through ordinary source
diagnostics and standalone compilation. Each helper module owns one `repair`
declaration with `predecessor`, `job`, `revision`, `migrate` and `fixtures` fields.
The predecessor must be a directly imported, exported `migration` or `repair`
declaration in the same family. `job` is the exact revision-relative payload
identity string. The checker resolves the complete chain (at most 128 repair
revisions), checks the original `Migration.jobs` decision, captures predecessor
declarations and respects unsaved buffers. Only those checked contextual nodes
are omitted from callback IR; unrelated contextual declarations still refuse.
Ordinary emission deduplicates the complete lineage before runtime registration.
See lesson 96 for a complete `tesl test` example.

There is no durable quarantine command. Pure calls can be repeated; they provide no
exactly-once database guarantee. Application-bound repair registration, durable
progress, attempt-fenced updates, crash/restart recovery and retirement finality
remain required before deployment can be enabled; the candidate below exercises
those database mechanics in isolation.

## Regression gates

### PostgreSQL conversion and repair execution candidate

`runtime/go/teslrt/migration_queue_conversion_postgres.go` now executes compiled
conversions and repair revisions against real PostgreSQL jobs. Its private
installer owns a fresh, isolated namespace containing one checked transition;
it is **not** an application format-5 installer or upgrade. It reuses the actual
`tesl_jobs` table definition and installs payload contracts and source descriptors
from the linked compiler registry, rather than constructing substitute callbacks
or patching application history metadata.

The candidate provides:

- An installation UUID plus database OID/name binding, exact queue/job and version
  checks, and byte-exact source/target contract and descriptor checks.
- Installer-only append of repair revisions after an existing durable rejection.
  Registration verifies the entire existing prefix and rolls back an incomplete
  batch. It cannot rewrite an installed callback or revive a retired source.
- Restricted request/worker roles and security-definer operations. Default grants
  on tables, sequences and functions are explicitly revoked before the intended
  grants are applied; installed function definitions and execution grants are checked.
- Per-job READ COMMITTED transactions with row locks, transaction-ID/sequence
  attempt fencing, and immutable outcome receipts. The compiled frozen decoder,
  callback and target encoder/decoder execute inside that transaction. The payload,
  version, quarantine state and receipt commit together. A replay returns the
  receipt before calling the converter again.
- Original stored JSONB text and source-version retention on rejection. Successful
  repair restores the original pending/dead status and preserves retry attempts and
  schedule. Malformed payloads cannot acquire typed-repair authority.
- A candidate admission floor that advances only when no old-stamped jobs remain.
  Rejected and malformed jobs block it; waiting old enqueues reread the committed
  floor after the exclusive retirement lock.
- Shared production queue claim/renew/fail/complete/quarantine/inspection SQL,
  with candidate-specific admission. A transaction-local identity and compiled
  contract binding prevent stale or foreign connection contexts from claiming
  jobs. Old workers cannot claim converted payloads; new workers cannot claim
  incompatible old payloads before conversion.
- Recovery of expired processing/dead-processing claims under the job lock.
  Live claims and the original claiming transaction remain protected. An expired
  claim's release and conversion roll back together, and stale claimant tokens
  cannot renew or complete the converted job.
- Receipt replay after normal queue completion deletes the job. Abandoned
  conversion attempts cascade on deletion, so they cannot block a handler's
  legitimate completion; conversion receipts remain immutable and independent.
- Bounded dispatch turns that discover work through indexed `FOR UPDATE SKIP
  LOCKED` selection. A turn processes at most 1–256 jobs for one checked source,
  with a transaction per job and separate converted/rejected/invalid/replayed
  counts. Durable receipts exclude already processed jobs and identify the exact
  rejection eligible for a repair. Delayed and retry-scheduled jobs are included.
  The within-turn cursor is not persisted: a new turn can discover earlier locked
  jobs or new arrivals. `NoEligible` is never permission to advance the floor.

The source-deleted generated-project fixture in
`compiler/test/fixtures/queue-repair-postgres/` exercises real roles and database
connections. Fourteen Go test groups cover persisted conversion/repair, delayed and
dead jobs, pre-commit backend termination, post-commit replay after reconnect,
competing workers, abandoned/stale attempts, progressive repair registration and
rollback, foreign database/contract bindings, malformed payloads, active and
expired claims, typed consumption and completion, post-deletion replay and
retirement fencing, bounded work discovery, concurrent batches and restart after
a partial batch failure. The full `scripts/run-migration-tests.sh` gate supplies its private
PostgreSQL cluster and requires these witnesses; they cannot silently skip there.

This candidate handles unclaimed or expired pending/dead jobs and their typed
quarantines, one transaction per job. Integration with format-5 source/expansion
receipts, closed application catalogs, production scheduling of these worker
turns and application retirement remains necessary. Its global scope lock
is not the application's per-version admission fence. The ordinary
changed-payload application guards therefore still refuse deployment. The
candidate's floor is not the application control schema's admission floor.

`test_migration_queue_transform` covers source certificates, exact ownership and
signatures, builtin result/fixture identities, codec directions, proof checking,
source/overlay/publication guards and freezing invariance. Its generated-code
tests run the actual frozen decoder, conversion and target encoder/decoder with
the source files absent. It also checks that this source evidence cannot activate
changed-payload migration. See
[lesson 96](../example/learn/lesson96-typed-queue-conversion.md).

`test_migration_queue` checks the contextual parser and recovery boundary,
purity, payload types and visibility, sorted membership and revision-relative
`Same`, duplicate ownership, record/ADT/proof/codec changes, whole application
bindings, deleted bindings, late additions, genuine freeze/refresh history, and
legacy empty-versus-unknown propagation. Existing migration inventory, source
seal, header, generation, refresh, application, and program suites remain gates.
Native mixed-version queue claims and retirement tests are required with
the runtime implementation; these compiler tests cannot substitute for them.
