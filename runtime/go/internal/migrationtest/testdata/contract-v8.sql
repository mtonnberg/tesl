-- [normative-template] `contract V8` as the harness runs it; :binds supplied by the executor.
-- Each labelled SQL block is one statement/transaction boundary. Hooks are executed
-- by the harness; a failed hook or nonzero assertion stops the recipe.

-- [sql begin-retirement]
begin;
-- [sql fence-v7]
select pg_advisory_xact_lock(:fence_ns, 7);
-- [hook final-pass]
-- Run frozen migrateNote to generation 4 in bounded transactions on OTHER connections.
-- V7 writers are fenced out; V8 writes generation 4. Reject aborts the coordinator,
-- then quarantine re-reads the current row. Accepted batches remain committed.
-- [zero rows-final]
select count(*) from notes_app.notes where "_tesl_v" < 4;
-- [hook jobs-retire]
-- Restamp pending/dead jobs and surviving processing claims in bounded batches;
-- wait only for retiring claimants' leases. Re-encode when jobs: changes the shape.
-- Progress belongs to tesl_schema_queue_restamps(:retirement_plan_hash).
-- [zero jobs-final]
select count(*) from notes_app.tesl_jobs where schema_version < 8 and status <> 'quarantined';
-- [sql entity-final]
update notes_app.tesl_schema_entities set generation = 4 where entity = 'Note' and target_generation = 4;
-- [sql advance-floor]
select notes_app.tesl_advance_floor(7, 8, :retirement_plan_hash, :protocol_level, :fence_domain, :holder);
-- [sql commit-retirement]
commit;

-- [hook terminal-jobs]
-- Take every listed temporary object's DDL-job key EXCLUSIVELY in stable-id order.
-- Record terminal with terminal_version = 8 while holding those session locks; retain them through contracted.
-- A resumed job must retain this removal version, even if its index was created before V8.
-- This drains active autocommit builds and prevents a stale worker from recreating
-- an object after contract removes it.
-- [sql begin-contract]
select notes_app.tesl_begin_contract(8, :contract_hash, :protocol_level, :fence_domain, :holder);
-- [hook wait-plan-switch]
-- Wait for compat_floor_seen >= 8 from each admitted instance, or two poll intervals.
-- This grace is observability; the plan-switch retry protocol remains the guard.

-- Short DDL statements below use lock_timeout = 2s, each in its own transaction.
-- [hook ensure-wordcount-check]
-- Read pg_constraint. Absent: ADD CHECK ("wordCount" IS NOT NULL) NOT VALID.
-- Present: compare both expressions deparsed by THIS server with empty search_path;
-- equal is an idempotent retry, different is named catalog drift and a refusal.
-- [hook validate-wordcount-check]
-- VALIDATE CONSTRAINT notes_wordcount_nn unless pg_constraint.convalidated is true.
-- [sql wordcount-not-null]
alter table notes_app.notes alter column "wordCount" set not null;
-- [sql drop-wordcount-check]
alter table notes_app.notes drop constraint if exists notes_wordcount_nn;
-- [hook ensure-owner-check]
-- The same catalog-checked NOT VALID / validation recipe for "ownerId" IS NOT NULL.
-- [hook validate-owner-check]
-- VALIDATE CONSTRAINT notes_owner_nn unless already validated.
-- [sql owner-not-null]
alter table notes_app.notes alter column "ownerId" set not null;
-- [sql drop-owner-check]
alter table notes_app.notes drop constraint if exists notes_owner_nn;
-- [hook ensure-wordcount-proof]
-- Keep the expressible proof CHECK ("wordCount" >= 0) using the same comparator.
-- [hook validate-wordcount-proof]
-- VALIDATE CONSTRAINT notes_wordcount_nonnegative unless already validated.
-- [sql drop-trigger]
drop trigger if exists tesl_mig_notes_g4 on notes_app.notes;
-- [sql drop-function]
drop function if exists notes_app.tesl_mig_notes_g4();
-- [sql drop-author]
alter table notes_app.notes drop column if exists "authorId";
-- [sql drop-rank]
alter table notes_app.notes drop column if exists "legacyRank";
-- [sql drop-author-index]
drop index concurrently if exists notes_app.notes_authorId_idx;
-- [sql drop-marker-index]
drop index concurrently if exists notes_app.notes_tesl_v_g4_idx;
-- [sql record-contracted]
select notes_app.tesl_record_contracted(8, :contract_hash, :protocol_level, :fence_domain, :holder);
-- [hook release-job-locks]
-- Release only after contracted is durable. Backend death releases session locks;
-- a successor reacquires them, rechecks terminal/catalog state, and resumes.

-- A subsequent V9 expansion waits for the contracted row above.
-- [sql add-archived]
alter table notes_app.notes add column if not exists "archivedAt" bigint;
-- [sql expand-v9]
select notes_app.tesl_record_expanded(9, :snapshot_hash, :migration_hash, :protocol_level, :fence_domain, :epoch_preserving, :holder);
