package teslrt

// Candidate SQL only. These functions are not registered by production format 3
// and are installed only by the unpublished format 4 preparation. Publishing
// backend dispatch and the complete upgrade protocol is a separate gate.
func pgQueueOperationFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	// Lock the exact attempt before reading the clock. A WHERE lease predicate
	// alone may be evaluated before waiting on an unchanged row lock.
	lockClaim := func(processingOnly, allowTransaction bool) string {
		states := "('processing','dead_processing')"
		if processingOnly {
			states = "('processing')"
		}
		expired := "claim_until<=pg_catalog.clock_timestamp()"
		if allowTransaction {
			expired += " and claim_transaction<>pg_catalog.pg_current_xact_id()"
		}
		return `
 select j.lease_until,j.claim_xid into claim_until,claim_transaction from ` + ns + `tesl_jobs j
 where j.id=job_id and j.queue=q and j.status in ` + states + `
   and j.claimed_by_version=v and j.claim_token=token and j.claim_seq=attempt_seq
 for update;
 if not found then return false; end if;
 if ` + expired + ` then return false; end if;
`
	}
	return []pgMigrationControlFunction{
		{"tesl_queue_admit", "v integer, q text", "integer", "volatile", `
declare fence integer; floor integer; origin integer;
begin
 if pg_catalog.current_setting('transaction_isolation') <> 'read committed' then
   raise exception 'tesl: queue operations require read committed isolation';
 end if;
 if v is null or v < 1 or v > 2147483646 or q is null or q='' then
   raise exception 'tesl: invalid queue operation identity';
 end if;
 select fence_ns,initial_version into fence,origin from ` + ns + `tesl_schema_meta
   where id=1 and format_version=4;
 if not found then raise exception 'tesl: protected queue format is not installed'; end if;
 -- Separate volatile SPI statements: admission observes the state AFTER the
 -- fence wait. A snapshot taken before waiting cannot authorize this write.
 perform pg_catalog.pg_advisory_xact_lock_shared(fence,v);
 perform ` + ns + `tesl_admit(v);
 select min_version into floor from ` + ns + `tesl_schema_state where id=1;
 if not found or floor < 1 or floor > v then raise exception 'tesl: invalid queue admission state'; end if;
 if not exists(select 1 from ` + ns + `tesl_queue_baseline b
   join ` + ns + `tesl_queue_versions i on i.version=b.initial_version and i.inventory_hash=b.inventory_hash
   where b.id=1 and b.initial_version=origin and b.inventory_authority='complete'
     and b.established_by='fresh-install') then
   raise exception 'tesl: queue installation baseline is unknown or incomplete';
 end if;
 if not exists(select 1 from ` + ns + `tesl_queue_contracts c
   join ` + ns + `tesl_queue_versions i on i.version=c.version
   join ` + ns + `tesl_schema_versions s on s.version=i.version and s.step='expanded'
     and s.snapshot_hash=i.storage_snapshot_hash
     and s.stored_value_compatibility=i.stored_value_compatibility
   where c.version=v and c.queue=q) then
   raise exception 'tesl: queue contract has no installed inventory';
 end if;
 return floor;
end`},
		{"tesl_queue_enqueue", "v integer, q text, job text, job_id text, body jsonb", "text", "volatile", `
begin
 perform ` + ns + `tesl_queue_admit(v,q);
 if job_id is null or job_id='' or body is null or not exists
   (select 1 from ` + ns + `tesl_queue_payloads p where p.version=v and p.queue=q and p.job_type=job) then
   raise exception 'tesl: queue payload has no registered identity';
 end if;
 insert into ` + ns + `tesl_jobs(id,queue,job_type,payload,schema_version,status)
   values(job_id,q,job,body,v,'pending');
 perform pg_catalog.pg_notify('tesl_queue',q);
 return job_id;
end`},
		{"tesl_queue_claim", "v integer, q text, wanted text, claimant text, lease_ms bigint",
			"TABLE(job_id text, job_type text, payload jsonb, source_version integer, attempts integer, token text, attempt_seq bigint)", "volatile", `
declare floor integer; picked text;
begin
 floor := ` + ns + `tesl_queue_admit(v,q);
 if wanted is null or wanted not in ('pending','dead') or claimant is null or claimant=''
   or lease_ms is null or lease_ms < 1 or lease_ms > 9223372036854 then
   raise exception 'tesl: invalid queue claim policy';
 end if;
 -- Reclaim only compatible admitted payloads. An old worker must never alter a
 -- newer row, including an expired lease, just because the queue name matches.
 with expired as (select j.id from ` + ns + `tesl_jobs j
 where j.queue=q and j.schema_version between floor and v
   and j.status in ('processing','dead_processing') and j.lease_until<=pg_catalog.clock_timestamp()
   and exists(select 1 from ` + ns + `tesl_queue_payloads old
     join ` + ns + `tesl_queue_payloads own on own.version=v and own.queue=old.queue
       and own.job_type=old.job_type and own.contract=old.contract and own.contract_hash=old.contract_hash
     where old.version=j.schema_version and old.queue=j.queue and old.job_type=j.job_type)
 order by j.seq for update of j skip locked limit 64)
 update ` + ns + `tesl_jobs j set
   status=case when j.status='dead_processing' then 'dead' else 'pending' end,
   locked_at=null,locked_by=null,claim_token=null,claimed_by_version=null,claim_xid=null,lease_until=null
 from expired where j.id=expired.id;
 select j.id into picked from ` + ns + `tesl_jobs j
 where j.queue=q and j.status=wanted and j.schema_version between floor and v
   and j.next_attempt_at<=pg_catalog.clock_timestamp()
   and exists(select 1 from ` + ns + `tesl_queue_payloads old
     join ` + ns + `tesl_queue_payloads own on own.version=v and own.queue=old.queue
       and own.job_type=old.job_type and own.contract=old.contract and own.contract_hash=old.contract_hash
     where old.version=j.schema_version and old.queue=j.queue and old.job_type=j.job_type)
 order by j.seq for update of j skip locked limit 1;
 if not found then return; end if;
 return query update ` + ns + `tesl_jobs j set
   status=case when wanted='dead' then 'dead_processing' else 'processing' end,
   locked_at=pg_catalog.clock_timestamp(),locked_by=claimant,
   claim_token=pg_catalog.gen_random_uuid()::text || ':' || (j.claim_seq+1)::text,
   claim_seq=j.claim_seq+1,claimed_by_version=v,claim_xid=pg_catalog.pg_current_xact_id(),
   lease_until=pg_catalog.clock_timestamp() + (lease_ms * interval '1 millisecond')
 where j.id=picked
 returning j.id,j.job_type,j.payload,j.schema_version,j.attempts,j.claim_token,j.claim_seq;
end`},
		{"tesl_queue_complete", "v integer, q text, job_id text, token text, attempt_seq bigint", "boolean", "volatile", `
declare changed bigint; claim_until timestamptz; claim_transaction xid8;
begin
 perform ` + ns + `tesl_queue_admit(v,q);` + lockClaim(false, true) + `
 delete from ` + ns + `tesl_jobs j where j.id=job_id and j.queue=q
   and j.status in ('processing','dead_processing') and j.claimed_by_version=v
   and j.claim_token=token and j.claim_seq=attempt_seq;
 get diagnostics changed=row_count;
 return changed=1;
end`},
		{"tesl_queue_renew", "v integer, q text, job_id text, token text, attempt_seq bigint, lease_ms bigint", "boolean", "volatile", `
declare changed bigint; claim_until timestamptz; claim_transaction xid8;
begin
 perform ` + ns + `tesl_queue_admit(v,q);
 if lease_ms is null or lease_ms < 1 or lease_ms > 9223372036854 then
   raise exception 'tesl: invalid queue renewal policy';
 end if;` + lockClaim(false, false) + `
 update ` + ns + `tesl_jobs j set locked_at=pg_catalog.clock_timestamp(),
   lease_until=pg_catalog.clock_timestamp() + (lease_ms * interval '1 millisecond')
 where j.id=job_id and j.queue=q and j.status in ('processing','dead_processing')
   and j.claimed_by_version=v and j.claim_token=token and j.claim_seq=attempt_seq;
 get diagnostics changed=row_count;
 return changed=1;
end`},
		{"tesl_queue_fail", "v integer, q text, job_id text, token text, attempt_seq bigint, max_attempts integer, delay_ms bigint", "boolean", "volatile", `
declare changed bigint; claim_until timestamptz; claim_transaction xid8;
begin
 perform ` + ns + `tesl_queue_admit(v,q);
 if max_attempts is null or max_attempts<1 or delay_ms is null or delay_ms<0 or delay_ms>9223372036854 then
   raise exception 'tesl: invalid queue retry policy';
 end if;` + lockClaim(true, true) + `
 update ` + ns + `tesl_jobs j set attempts=j.attempts+1,schema_version=v,
   status=case when j.attempts+1>=max_attempts then 'dead' else 'pending' end,
   dead_reason=case when j.attempts+1>=max_attempts then 'attempts-exhausted' else null end,
   dead_detail=null,
   next_attempt_at=pg_catalog.clock_timestamp() +
     (case when j.attempts+1>=max_attempts then 0 else delay_ms end * interval '1 millisecond'),
   locked_at=null,locked_by=null,claim_token=null,claimed_by_version=null,claim_xid=null,lease_until=null
 where j.id=job_id and j.queue=q and j.status='processing' and j.claimed_by_version=v
   and j.claim_token=token and j.claim_seq=attempt_seq;
 get diagnostics changed=row_count;
 return changed=1;
end`},
		{"tesl_queue_quarantine", "v integer, q text, job_id text, token text, attempt_seq bigint", "boolean", "volatile", `
declare changed bigint; claim_until timestamptz; claim_transaction xid8;
begin
 perform ` + ns + `tesl_queue_admit(v,q);` + lockClaim(false, true) + `
 update ` + ns + `tesl_jobs j set status='quarantined',dead_reason='payload-invalid',
   dead_detail=null,locked_at=null,locked_by=null,claim_token=null,claimed_by_version=null,claim_xid=null,lease_until=null
 where j.id=job_id and j.queue=q and j.status in ('processing','dead_processing')
   and j.claimed_by_version=v and j.claim_token=token and j.claim_seq=attempt_seq;
 get diagnostics changed=row_count;
 return changed=1;
end`},
		{"tesl_queue_count", "v integer, q text, wanted text", "bigint", "volatile", `
declare amount bigint;
begin
 perform ` + ns + `tesl_queue_admit(v,q);
 if wanted is null or wanted not in ('pending','dead') then
   raise exception 'tesl: invalid queue count status';
 end if;
 select pg_catalog.count(*) into amount from ` + ns + `tesl_jobs j
 where j.queue=q and j.schema_version<=v
   and ((wanted='pending' and j.status='pending')
     or (wanted='dead' and j.status in ('dead','quarantined')));
 return amount;
end`},
		{"tesl_queue_dead_jobs", "v integer, q text",
			"TABLE(job_id text, job_type text, source_version integer, attempts integer, reason text)", "volatile", `
begin
 perform ` + ns + `tesl_queue_admit(v,q);
 -- Inspection returns source metadata, never a payload decoded as a current job.
 -- Quarantines remain visible even when their source version is below the floor.
 return query select j.id,j.job_type,j.schema_version,j.attempts,j.dead_reason
 from ` + ns + `tesl_jobs j where j.queue=q and j.schema_version<=v
   and j.status in ('dead','quarantined') order by j.seq;
end`},
		{"tesl_queue_requeue", "v integer, q text, job_id text", "boolean", "volatile", `
declare floor integer; changed bigint;
begin
 floor := ` + ns + `tesl_queue_admit(v,q);
 update ` + ns + `tesl_jobs j set status='pending',schema_version=v,attempts=0,
   next_attempt_at=pg_catalog.clock_timestamp(),dead_reason=null,dead_detail=null
 where j.id=job_id and j.queue=q and j.status='dead'
   and j.schema_version between floor and v
   and exists(select 1 from ` + ns + `tesl_queue_payloads old
     join ` + ns + `tesl_queue_payloads own on own.version=v and own.queue=old.queue
       and own.job_type=old.job_type and own.contract=old.contract and own.contract_hash=old.contract_hash
     where old.version=j.schema_version and old.queue=j.queue and old.job_type=j.job_type);
 get diagnostics changed=row_count;
 if changed=1 then perform pg_catalog.pg_notify('tesl_queue',q); end if;
 return changed=1;
end`},
	}
}
