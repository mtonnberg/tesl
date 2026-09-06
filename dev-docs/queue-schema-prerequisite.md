# Frozen queue schema prerequisite

This is the compiler prerequisite for `roadmap/next/queue-payload-migrations.md`.
It does not enable versioned PostgreSQL queues. Guarded queue startup still refuses
until protected runtime storage, version-aware claims, claim-attempt fencing,
visible decode failures, and retirement are implemented.

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
claim or transform durable jobs. Compiled runtime history does not yet carry the
new claim-ready inventory protocol.

In particular, an initial deployed V1 may have no source seal. Its first freeze
checks the source visible now; it cannot prove that the deployed application
never had an older queue declaration that has since been removed. Runtime
activation must require persisted baseline inventory evidence or explicit legacy
adoption. A metadata-only control-format upgrade cannot manufacture that evidence.

## Regression gates

`test_migration_queue` checks the contextual parser and recovery boundary,
purity, payload types and visibility, sorted membership and revision-relative
`Same`, duplicate ownership, record/ADT/proof/codec changes, whole application
bindings, deleted bindings, late additions, genuine freeze/refresh history, and
legacy empty-versus-unknown propagation. Existing migration inventory, source
seal, header, generation, refresh, application, and program suites remain gates.
Native mixed-version queue claims and retirement tests are still required with
the runtime implementation; these compiler tests cannot substitute for them.
