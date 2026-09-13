------------------------- MODULE MigrationAdmission -------------------------
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS MaxVersion, MaxAttempt, JobEnabled, Mutation
Versions == 1..MaxVersion

\* One transaction per version. Attempts are separate identities, so an expired
\* worker can resume after another worker of the SAME version has reclaimed.
VARIABLES floor, compat, expanded, epoch, retiring, life, pc, dropThrough,
          dirty, jobVersion, jobStatus, jobClaimant, jobSeq, jobLive,
          heldAttempts, badOutcome

vars == <<floor, compat, expanded, epoch, retiring, life, pc, dropThrough,
          dirty, jobVersion, jobStatus, jobClaimant, jobSeq, jobLive,
          heldAttempts, badOutcome>>
control == <<floor, compat, expanded, epoch, retiring, life, dropThrough, dirty>>
queue == <<jobVersion, jobStatus, jobClaimant, jobSeq, jobLive, heldAttempts, badOutcome>>
Admitted(v) == v >= floor /\ v <= expanded
MayWrite(v) == Admitted(v) /\ (retiring = 0 \/ v >= retiring)

Init ==
  /\ floor = 1 /\ compat = 1 /\ expanded = 1 /\ epoch = TRUE
  /\ retiring = 0 /\ dropThrough = 0 /\ dirty = FALSE
  /\ life = [v \in Versions |-> IF v = 1 THEN "contracted" ELSE "absent"]
  /\ pc = [v \in Versions |-> "idle"]
  /\ jobVersion = 1 /\ jobStatus = IF JobEnabled THEN "pending" ELSE "done"
  /\ jobClaimant = 0 /\ jobSeq = 0 /\ jobLive = FALSE
  /\ heldAttempts = {} /\ badOutcome = FALSE

Expand(additive) ==
  /\ expanded < MaxVersion /\ retiring = 0
  /\ additive \/ floor = expanded
  /\ epoch \/ (floor = expanded /\ life[expanded] = "contracted")
  /\ expanded' = expanded + 1
  /\ life' = [life EXCEPT ![expanded + 1] = "expanded"]
  /\ epoch' = (epoch /\ additive)
  /\ dirty' = (dirty \/ ~additive)
  /\ UNCHANGED <<floor, compat, retiring, pc, dropThrough, queue>>

WriteBegin(v) ==
  /\ pc[v] = "idle" /\ MayWrite(v)
  /\ pc' = [pc EXCEPT ![v] = "write"]
  /\ UNCHANGED <<control, queue>>

WriteCommit(v) ==
  /\ pc[v] = "write"
  /\ pc' = [pc EXCEPT ![v] = "idle"]
  /\ dirty' = (dirty \/ (~epoch /\ v < expanded))
  /\ UNCHANGED <<floor, compat, expanded, epoch, retiring, life, dropThrough, queue>>

\* Query-first READ COMMITTED: query holds ACCESS SHARE until commit/rollback.
\* Versions already missing physical columns cannot execute this query. They
\* report a schema error rather than returning rows; no admission can rescue it.
ReadQuery(v) ==
  /\ pc[v] = "idle" /\ v <= expanded /\ v > dropThrough
  /\ pc' = [pc EXCEPT ![v] = "buffered"]
  /\ UNCHANGED <<control, queue>>

ReadAdmit(v) ==
  /\ pc[v] = "buffered"
  /\ pc' = [pc EXCEPT ![v] = IF Admitted(v) \/ Mutation = "read-admission" THEN "admitted" ELSE "idle"]
  /\ UNCHANGED <<control, queue>>

\* Admission is the read's linearization point. A floor may move after admission;
\* physical contract must still wait for this transaction before removing columns.
ReadCommit(v) ==
  /\ pc[v] = "admitted"
  /\ pc' = [pc EXCEPT ![v] = "idle"]
  /\ UNCHANGED <<control, queue>>

ActorCrash(v) ==
  /\ pc[v] # "idle"
  /\ pc' = [pc EXCEPT ![v] = "idle"]
  /\ UNCHANGED <<control, queue>>

RetireBegin(target) ==
  /\ retiring = 0 /\ target > floor /\ target <= expanded
  /\ Mutation = "writer-fence" \/ \A v \in Versions : v < target => pc[v] # "write"
  /\ retiring' = target
  /\ UNCHANGED <<floor, compat, expanded, epoch, life, pc, dropThrough, dirty, queue>>

\* A provisional pass may be undone by an admitted old writer. The same pass
\* becomes final under the retirement fence, after all retiring writers finish.
Backfill ==
  /\ dirty
  /\ dirty' = FALSE
  /\ UNCHANGED <<floor, compat, expanded, epoch, retiring, life, pc, dropThrough, queue>>

RetireCommit ==
  /\ retiring # 0
  /\ ~dirty \/ Mutation = "final-pass"
  /\ jobStatus = "done" \/ jobVersion >= retiring \/ Mutation = "queue-floor"
  /\ floor' = retiring /\ retiring' = 0
  /\ UNCHANGED <<compat, expanded, epoch, life, pc, dropThrough, dirty, queue>>

ContractBegin(v) ==
  /\ v <= floor /\ life[v] = "expanded"
  /\ life' = [life EXCEPT ![v] = "contracting"]
  /\ compat' = IF compat < v THEN v ELSE compat
  /\ UNCHANGED <<floor, expanded, epoch, retiring, pc, dropThrough, dirty, queue>>

ContractDDL(v) ==
  /\ life[v] = "contracting" /\ dropThrough < v - 1
  /\ Mutation = "read-lock" \/
       \A r \in Versions : r < v => pc[r] \notin {"buffered", "admitted"}
  /\ dropThrough' = v - 1
  /\ UNCHANGED <<floor, compat, expanded, epoch, retiring, life, pc, dirty, queue>>

ContractFinish(v) ==
  /\ life[v] = "contracting" /\ dropThrough >= v - 1
  /\ life' = [life EXCEPT ![v] = "contracted"]
  /\ UNCHANGED <<floor, compat, expanded, epoch, retiring, pc, dropThrough, dirty, queue>>

\* Session loss releases the coordinator fence. Committed restamps, floors,
\* contract intent and DDL survive; the next coordinator resumes from those facts.
CoordinatorCrash ==
  /\ retiring # 0
  /\ retiring' = 0
  /\ UNCHANGED <<floor, compat, expanded, epoch, life, pc, dropThrough, dirty, queue>>

Claim(v) ==
  /\ JobEnabled /\ MayWrite(v) /\ jobVersion >= floor /\ jobVersion <= v
  /\ jobStatus = "pending" \/ (jobStatus = "processing" /\ ~jobLive)
  /\ jobSeq < MaxAttempt
  /\ jobSeq' = jobSeq + 1 /\ jobClaimant' = v
  /\ jobStatus' = "processing" /\ jobLive' = TRUE
  /\ heldAttempts' = heldAttempts \cup {<<v, jobSeq + 1>>}
  /\ UNCHANGED <<control, pc, jobVersion, badOutcome>>

Expire ==
  /\ jobStatus = "processing" /\ jobLive
  /\ jobLive' = FALSE
  /\ UNCHANGED <<control, pc, jobVersion, jobStatus, jobClaimant, jobSeq, heldAttempts, badOutcome>>

\* Renewal's clock increment is abstracted as stuttering while live. Expiry is
\* explicit; an expired or fenced-out attempt cannot turn itself live again.
Renew(v, sequence) ==
  /\ <<v, sequence>> \in heldAttempts
  /\ MayWrite(v) /\ jobStatus = "processing" /\ jobLive
  /\ jobClaimant = v /\ jobSeq = sequence
  /\ UNCHANGED vars

Outcome(v, sequence, status) ==
  /\ <<v, sequence>> \in heldAttempts
  /\ MayWrite(v) /\ jobStatus = "processing" /\ jobLive
  /\ Mutation = "claim-token" \/ (jobClaimant = v /\ jobSeq = sequence)
  /\ badOutcome' = (badOutcome \/ jobClaimant # v \/ jobSeq # sequence)
  /\ jobStatus' = status /\ jobLive' = FALSE
  /\ UNCHANGED <<control, pc, jobVersion, jobClaimant, jobSeq, heldAttempts>>

Restamp ==
  /\ retiring # 0 /\ jobVersion < retiring /\ jobStatus # "done"
  /\ jobStatus # "processing" \/ jobClaimant >= retiring \/ ~jobLive
  /\ jobVersion' = retiring
  /\ jobStatus' = IF jobStatus = "processing" /\ (jobClaimant < retiring \/ Mutation = "survivor-restamp")
                   THEN "pending" ELSE jobStatus
  /\ UNCHANGED <<control, pc, jobClaimant, jobSeq, jobLive, heldAttempts, badOutcome>>

Next ==
  \/ \E additive \in BOOLEAN : Expand(additive)
  \/ \E v \in Versions : WriteBegin(v) \/ WriteCommit(v) \/ ReadQuery(v)
       \/ ReadAdmit(v) \/ ReadCommit(v) \/ ActorCrash(v) \/ RetireBegin(v)
       \/ ContractBegin(v) \/ ContractDDL(v) \/ ContractFinish(v) \/ Claim(v)
  \/ Backfill \/ RetireCommit \/ CoordinatorCrash \/ Restamp \/ Expire
  \/ \E v \in Versions, sequence \in 1..MaxAttempt :
       Renew(v, sequence) \/ (\E status \in {"pending", "dead", "done"} : Outcome(v, sequence, status))

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ floor \in Versions /\ compat \in Versions /\ expanded \in Versions
  /\ retiring \in 0..MaxVersion /\ dropThrough \in 0..(MaxVersion - 1)
  /\ epoch \in BOOLEAN /\ dirty \in BOOLEAN
  /\ life \in [Versions -> {"absent", "expanded", "contracting", "contracted"}]
  /\ pc \in [Versions -> {"idle", "write", "buffered", "admitted"}]
  /\ jobVersion \in Versions /\ jobClaimant \in 0..MaxVersion
  /\ jobSeq \in 0..MaxAttempt /\ jobLive \in BOOLEAN /\ badOutcome \in BOOLEAN
  /\ jobStatus \in {"pending", "processing", "dead", "done"}
  /\ heldAttempts \subseteq (Versions \X (1..MaxAttempt))

INVFloors == compat <= floor /\ floor <= expanded /\ dropThrough < compat
INVWriter == \A v \in Versions : pc[v] = "write" => v >= floor
INVReadLock == \A v \in Versions : pc[v] \in {"buffered", "admitted"} => v > dropThrough
INVFinal == floor = expanded => ~dirty
INVQueueFloor == jobStatus = "done" \/ jobVersion >= floor
INVAttempt == ~badOutcome
INVContract == \A v \in Versions : life[v] \in {"contracting", "contracted"} => v <= compat
Monotone == [][floor' >= floor /\ compat' >= compat /\ expanded' >= expanded /\ jobSeq' >= jobSeq]_vars
ReadAdmissionSafe == [][\A v \in Versions :
  (pc[v] = "buffered" /\ pc'[v] = "admitted") => Admitted(v)]_vars
SurvivorAttemptPreserved == [][
  (jobVersion' > jobVersion /\ jobStatus = "processing" /\ jobClaimant >= retiring)
    => UNCHANGED <<jobStatus, jobClaimant, jobSeq, jobLive>>]_vars
=============================================================================
