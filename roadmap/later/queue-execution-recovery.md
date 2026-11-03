# Typed recovery from queue conversion execution failure — proposed next protocol

Status: **superseded proposal for a separate language construct**. After initial
deferral, the maintainer required both corrected conversion and audited discard
to close the lifecycle. They are implemented through explicit `QueueRepair.on`
policies, not a new `QueueRecovery` keyword. See
[`manual/queue-remediation.md`](../../manual/queue-remediation.md) for the active
surface. The historical proposal below remains design context, not independent
source authority. The application
runtime already records execution-failure evidence and continues healthy peers.
This document specifies the remaining typed remediation boundary; it does not
authorize a new syntax, callback, operator override or catalog adoption.

The scope limitation remains explicit: an unconvertible durable job that cannot
be processed by an admitted predecessor can block retirement. Queue ephemerality
does not authorize silent deletion or an admission-floor bypass. The database
migration feature may ship with this documented refusal/recovery boundary, without
claiming guaranteed completion for every accepted callback and historical value.

## Current evidence and why business repair is insufficient

`tesl_row_queue_conversion_failures` records job ID, checked source digest,
attempt sequence, original-payload hash and one sanitized code. Selection suppresses
that job/source/byte combination. Payload/version/disposition and successful or
business-rejected conversion receipts are preserved. An admitted predecessor may
still claim and complete a processable old job; otherwise retirement remains blocked.

Existing `QueueRepair` must consume its exact business-rejection predecessor.
Execution exhaustion, trapping and unusable encoding are not that result. Widening
`QueueRepair` implicitly would obscure the policy a human is approving and invalidate
the generated fixture oracle that reproduces the predecessor's rejection.

## Proposed source obligation

Introduce a distinct contextual recovery declaration (working name `QueueRecovery`)
with an explicitly named predecessor and an exact old-record-to-`Migrated Target`
callback. It must:

1. Resolve the original immutable conversion/repair lineage through the normal
   schema-family ownership rules. No digest string supplied by application code.
2. Preserve the exact original schema/storage snapshots, nominal payload types,
   codecs, queue/job membership and target physical edge.
3. Introduce a new callback identity, with a consecutive immutable revision, without
   editing deployed predecessor bytes or changing the active edge's executable ABI.
4. State which operational outcome class it handles. Cancellation, database errors,
   malformed old bytes and business rejection are not interchangeable outcomes.
5. Supply a fixture that reproduces the named predecessor execution failure under
   the compiler's bounded pure execution policy, then demonstrates the recovery's
   chosen success or business rejection. Merely calling a callback that happens to
   succeed on a benign fixture cannot establish recovery authority.

The precise source spelling and whether allowed failure codes are explicit fields
or separate constructors need a language-design decision. No new persisted authority
should be added before the fixture and canonical-format contract are fixed.

## Durable evidence needed before execution

The runtime must independently verify installed recovery source, exact predecessor,
installation UUID/fence, source/target contracts and code linkage. The chosen failure
must still correspond to the locked job's current source version, exact bytes and
latest applicable attempt history. A failure row alone never grants an arbitrary
callback permission to write.

The current diagnostic stores a payload hash rather than retained original bytes.
That suffices to suppress the same failed work while the job exists; recovery must
consume the still-locked job bytes and bind them into its own immutable result.
After ordinary predecessor completion deletes the job, the diagnostic remains an
audit only and cannot resurrect work. Audited job IDs remain non-reusable.

Publication keeps the real source/compatibility fences and transaction ownership
used by conversion today. A successful recovery updates bytes/version with its own
receipt. A business rejection creates a new explicit rejection result rooted in
the recovery declaration. Another execution failure gets separate diagnostic
evidence, not a fabricated rejection. Cancellation or failed SQL rolls back.

## Repair-chain and retirement obligations

- Branches, skipped revisions, source substitutions and partially installed lineages
  refuse. Staging may use bounded atomic groups but cannot publish an expansion.
- Define how an ordinary later `QueueRepair` names a recovery-produced rejection;
  do not assume the existing canonical parser can interpret that new predecessor.
- Define the ordering among root conversion, business repair and operational
  recovery so a job has exactly one eligible next source at each durable state.
- Old Workers without the installed recovery executable must refuse that descriptor
  rather than skip it and claim finality.
- Recovery evidence never advances floors. Contract still independently proves
  that old incompatible jobs, live retiring claims and attempts are absent and
  records the complete immutable source/recovery lineage.

## Required acceptance matrix

1. Root converter fails only on a hostile value; fixtures otherwise pass. Healthy
   same-type and peer-type work continues, and protected status explains failure.
2. Separately built recovery release handles that exact value; deploy via installer
   and Worker, then prove successful Contract and surviving Request processing.
3. Recovery rejects business policy; a later typed repair consumes exactly that
   rejection without changing the operational-failure audit.
4. Recovery itself exhausts/traps; original bytes, target floors and prior receipts
   remain unchanged. A further explicit revision resolves it.
5. Concurrent claim/completion, failed transaction, process death before/after commit,
   stale tokens, wrong UUID/fence and changed byte/hash tests.
6. Forged source/ABI/codec bindings, altered failure categories, Request-role attempts,
   missing/extra catalog objects and historical-source edits refuse.
7. Active-edge compiler substitution still refuses; compatible subsequent-edge
   rollout remains independently verified.
8. Installed help explains the recovery workflow and its limits. No hidden SQL
   deletion, force-retry, payload rewrite or old-catalog adoption is the supported path.

## Scope choice

The proposed first implementation should support decodable historical records on
an already published consecutive queue-only edge. General malformed-byte recovery,
audited discard and mixed row/queue history remain separate decisions. This preserves
the existing principle: the human reviews a typed business decision, while the
compiler/runtime establish identity, publication and finality obligations.
