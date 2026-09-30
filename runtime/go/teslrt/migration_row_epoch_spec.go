package teslrt

func pgRowEpochFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{{"tesl_close_row_epoch", "old_min integer, through_version integer, uuid text, fence integer, physical_hashes text[], doc bytea, digest text, abi text, forced boolean", "void", "volatile", `
declare epoch_state ` + ns + `tesl_schema_state%rowtype; old integer; ` + pgRowQueueVerificationDeclarations(namespace) + `
begin
 if old_min is null or old_min<1 or through_version is null or through_version<=old_min or through_version>2147483646 or
 physical_hashes is null or pg_catalog.array_lower(physical_hashes,1) is distinct from 1 or pg_catalog.cardinality(physical_hashes)<>through_version or
 doc is null or digest is null or digest !~ '^[0-9a-f]{64}$' or pg_catalog.encode(pg_catalog.sha256(doc),'hex') is distinct from digest or
 abi is null or abi !~ '^tesl-source-abi-v1:[0-9a-f]{64}$' or forced is null then
 raise exception 'tesl: invalid additive epoch retirement'; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_meta where id=1 and database_uuid::text=uuid and fence_ns=fence and format_version=5 and initial_version=1 and max_observed_protocol=1 and retirement_protocol_floor=1 and fence_domain='tesl-1') then
 raise exception 'tesl: additive epoch owner or protocol differs'; end if;
 select * into epoch_state from ` + ns + `tesl_schema_state where id=1 for update;
 if not found or epoch_state.current<>through_version or epoch_state.min_version<>old_min or epoch_state.compat_floor<>old_min or epoch_state.installing_version is not null then
 raise exception 'tesl: additive epoch admission state changed'; end if;
 if (select count(*) from ` + ns + `tesl_row_physical)<>through_version or
 exists(select 1 from pg_catalog.generate_series(1,through_version) physical_version(value) where not exists(
 select 1 from ` + ns + `tesl_row_physical p join ` + ns + `tesl_schema_versions receipt on receipt.version=p.version and receipt.step='expanded'
 where p.version=physical_version.value and p.epoch_preserving and p.contract_hash=physical_hashes[physical_version.value])) or
 exists(select 1 from ` + ns + `tesl_row_processing) or exists(select 1 from ` + ns + `tesl_row_contracts) or
 exists(select 1 from ` + ns + `tesl_schema_backfill_shards) then
 raise exception 'tesl: close epoch requires complete purely additive published history'; end if;
 for old in old_min..through_version-1 loop
 if not exists(select 1 from pg_catalog.pg_locks where locktype='advisory' and pid=pg_catalog.pg_backend_pid() and granted and
 classid=fence::oid and objid=old::oid and objsubid=2 and mode='ExclusiveLock') or
 not exists(select 1 from pg_catalog.pg_locks where locktype='advisory' and pid=pg_catalog.pg_backend_pid() and granted and
 classid=(4294967296::bigint-fence)::oid and objid=old::oid and objsubid=2 and mode='ExclusiveLock') then
 raise exception 'tesl: close epoch requires drained retiring transactions'; end if;
 end loop;
 if not forced and exists(select 1 from ` + ns + `tesl_schema_instances where version>=old_min and version<through_version and last_seen>pg_catalog.clock_timestamp()-interval '30 seconds') then
  raise exception 'tesl: close epoch has recent retiring instances; stop them and wait or use --force'; end if;
 ` + pgRowQueueEpochRestampSQL(namespace) + `
  select stored_value_compatibility into compatibility from ` + ns + `tesl_row_physical where version=through_version;
 insert into ` + ns + `tesl_row_epochs values(through_version,old_min,doc,digest,abi,forced);
 insert into ` + ns + `tesl_schema_versions(version,step,artefact_hash,source_abi,stored_value_compatibility,protocol_level,fence_domain,executed_by)
 select retired_target.value,phase.value,digest,abi,compatibility,1,'tesl-1',pg_catalog.current_setting('application_name')
 from pg_catalog.generate_series(old_min+1,through_version) retired_target(value)
 cross join (values('retired'),('contracting'),('contracted')) phase(value);
 update ` + ns + `tesl_schema_state set min_version=through_version,compat_floor=through_version where id=1 and min_version=old_min and compat_floor=old_min and current=through_version;
 if not found then raise exception 'tesl: epoch admission compare-and-swap failed'; end if;
end`}}
}

// Only identical frozen payload contracts can cross this boundary. All queue
// changes and the admission/receipt publication share one transaction: timeout,
// rejection or process death rolls back the complete operation. Retiring
// executions are already fenced; surviving claims keep their attempt identity.
func pgRowQueueEpochRestampSQL(namespace string) string {
	ns := quoteIdentifier(namespace) + "."
	return pgRowQueueVerificationSQL(namespace, "through_version") + `
 if exists(select 1 from ` + ns + `tesl_row_versions r where r.version<=through_version and
   r.queue_count<>(select count(*) from ` + ns + `tesl_queue_contracts q where q.version=r.version)) then
   raise exception 'tesl: queue epoch inventory differs from row source'; end if;
 if exists(select 1 from ` + ns + `tesl_queue_payloads p where p.version<through_version and not exists(
   select 1 from ` + ns + `tesl_queue_payloads target where target.version=through_version and
   target.queue=p.queue and target.job_type=p.job_type and target.contract=p.contract and target.contract_hash=p.contract_hash)) then
   raise exception 'tesl: queue epoch requires identical retained payload contracts'; end if;
 -- Do not skip locked rows: the final floor may publish only after every old
 -- job is accounted for. The caller's operation deadline bounds lock waits.
 perform j.id from ` + ns + `tesl_jobs j where j.schema_version<through_version order by j.seq for update;
 if exists(select 1 from ` + ns + `tesl_jobs j where j.schema_version<old_min) then
   raise exception 'tesl: queue job is already below the admission floor'; end if;
 if exists(select 1 from ` + ns + `tesl_jobs j where j.schema_version<through_version and j.status='quarantined') then
   raise exception 'tesl: quarantined queue payload requires typed repair before retirement'; end if;
 if exists(select 1 from ` + ns + `tesl_jobs j where j.schema_version<through_version and j.status in ('processing','dead_processing') and
   (j.claimed_by_version<old_min or j.claimed_by_version>through_version)) then
   raise exception 'tesl: queue attempt is outside the admitted window'; end if;
 if exists(select 1 from ` + ns + `tesl_jobs j where j.schema_version<through_version and j.status in ('processing','dead_processing') and
   j.claimed_by_version<through_version and j.lease_until>pg_catalog.clock_timestamp()) then
   raise exception 'tesl: retiring queue attempts are still leased; stop old workers and retry after their leases expire'; end if;
 update ` + ns + `tesl_jobs j set schema_version=through_version,
   status=case when j.status='processing' and j.claimed_by_version<through_version then 'pending'
               when j.status='dead_processing' and j.claimed_by_version<through_version then 'dead' else j.status end,
   locked_at=case when j.claimed_by_version<through_version then null else j.locked_at end,
   locked_by=case when j.claimed_by_version<through_version then null else j.locked_by end,
   claim_token=case when j.claimed_by_version<through_version then null else j.claim_token end,
   claimed_by_version=case when j.claimed_by_version<through_version then null else j.claimed_by_version end,
   claim_xid=case when j.claimed_by_version<through_version then null else j.claim_xid end,
   lease_until=case when j.claimed_by_version<through_version then null else j.lease_until end
 where j.schema_version<through_version;
 if exists(select 1 from ` + ns + `tesl_jobs where schema_version<through_version) then
   raise exception 'tesl: queue epoch left an old payload stamp'; end if;
 `
}
