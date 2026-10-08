package teslrt

import (
	"bytes"
	"context"
	"encoding/hex"
	"fmt"

	"github.com/jackc/pgx/v5"
)

type pgRowQueueRetirement struct{ document, hash, abi string }

func pgRowQueueRetirementTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{{"tesl_row_queue_retirements", `
 version integer primary key check(version between 2 and 2147483646), retirement bytea not null,
 retirement_hash text not null check(retirement_hash ~ '^[0-9a-f]{64}$'),
 compiler_abi text not null check(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'),
  check(pg_catalog.encode(pg_catalog.sha256(retirement),'hex')=retirement_hash)`},
		{"tesl_row_queue_restamps", `
 job_id text not null, from_version integer not null check(from_version>=1),
 to_version integer not null check(to_version=from_version+1 and to_version<=2147483646),
 queue text not null, job_type text not null,
 contract_hash text not null check(contract_hash ~ '^[0-9a-f]{64}$'),
 payload_hash text not null check(payload_hash ~ '^[0-9a-f]{64}$'),
 retirement_hash text not null check(retirement_hash ~ '^[0-9a-f]{64}$'),
 claim_seq bigint not null check(claim_seq>=0),
 primary key(job_id,from_version)`}}
}

func pgRowQueueRetirementFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	activeFailure := `exists(select 1 from ` + ns + `tesl_row_queue_conversion_failures f
 join ` + ns + `tesl_row_queue_conversion_staging c on c.source_digest=f.source_digest
 where f.job_id=j.id and c.queue=j.queue and c.job_type=j.job_type and c.from_version=j.schema_version and c.to_version=s.current
 and f.attempt_seq<=j.claim_seq and f.payload_hash=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(j.payload::text,'UTF8')),'hex'))`
	return []pgMigrationControlFunction{{"tesl_row_queue_final", "v integer", "boolean", "stable", `
begin
  if v is null or v<2 or v>2147483646 then raise exception 'tesl: queue finality requires an adjacent target'; end if;
 return not exists(select 1 from ` + ns + `tesl_jobs where schema_version<v)
  and not exists(select 1 from ` + ns + `tesl_jobs where status in ('processing','dead_processing') and claimed_by_version<v)
   and not exists(select 1 from ` + ns + `tesl_row_queue_conversion_attempts a join ` + ns + `tesl_row_queue_conversion_staging c on c.source_digest=a.source_digest where c.from_version<v);
end`}, {"tesl_retire_row_queue", "uuid text, fence integer, doc bytea, digest text, abi text", "boolean", "volatile", `
declare s ` + ns + `tesl_schema_state%rowtype; p ` + ns + `tesl_row_physical%rowtype;
 r ` + ns + `tesl_row_queue_retirements%rowtype; family text; inventory text;
 c record; source_bytes bytea:=''::bytea; count_sources integer:=0; expected bytea; n integer;
begin
 if uuid is null or fence is null or doc is null or digest is null or abi is null
  or digest !~ '^[0-9a-f]{64}$' or pg_catalog.encode(pg_catalog.sha256(doc),'hex')<>digest then
  raise exception 'tesl: invalid application queue retirement'; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_meta where id=1 and database_uuid::text=uuid and fence_ns=fence and format_version=5 and initial_version=1) then
  raise exception 'tesl: queue retirement installation differs'; end if;
 select * into s from ` + ns + `tesl_schema_state where id=1 for update;
  if not found or s.current<2 or s.min_version not in (s.current-1,s.current) then raise exception 'tesl: queue retirement requires the current adjacent edge'; end if;
  select * into p from ` + ns + `tesl_row_physical where version=s.current;
 if not found or p.epoch_preserving or p.operation_count<>0 or p.compiler_abi<>abi
   or not exists(select 1 from ` + ns + `tesl_row_queue_target_staging t where t.version=s.current and t.contract=p.contract and t.contract_hash=p.contract_hash and t.database_uuid::text=uuid and t.fence_ns=fence)
   or not exists(select 1 from ` + ns + `tesl_schema_versions where version=s.current and step='expanded' and artefact_hash=p.contract_hash and source_abi=abi) then
  raise exception 'tesl: queue retirement lacks its exact completed physical target'; end if;
 -- Both domains must be drained by the calling runtime before this transaction.
 foreach n in array array[fence,-fence] loop
  if not exists(select 1 from pg_catalog.pg_locks where locktype='advisory' and pid=pg_catalog.pg_backend_pid() and granted
   and classid=(case when n<0 then 4294967296::bigint+n else n::bigint end)::oid
    and objid=(s.current-1)::oid and objsubid=2 and mode='ExclusiveLock') then
   raise exception 'tesl: queue retirement lacks its exclusive source fence'; end if;
 end loop;
  select baseline.family,q.inventory_hash into family,inventory from ` + ns + `tesl_row_versions baseline cross join ` + ns + `tesl_queue_versions q where baseline.version=1 and q.version=s.current;
 if not found then raise exception 'tesl: queue retirement source inventory is missing'; end if;
  for c in select queue,job_type,revision,source_digest from ` + ns + `tesl_row_queue_conversion_staging where from_version=s.current-1 and to_version=s.current order by queue collate "C",job_type collate "C",revision loop
  source_bytes:=source_bytes||pg_catalog.convert_to('l4:','UTF8')
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(c.queue,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(c.job_type,'UTF8'))
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(c.revision::text,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(c.source_digest,'UTF8'));
  count_sources:=count_sources+1;
 end loop;
 if count_sources=0 then raise exception 'tesl: queue retirement has no checked source lineage'; end if;
 expected:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s9:migrationl11:','UTF8')
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to('tesl-row-queue-retirement-v1','UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(uuid,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(fence::text,'UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(family,'UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.decode('` + hex.EncodeToString([]byte(namespace)) + `','hex'))
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to((s.current-1)::text,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(s.current::text,'UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(p.contract_hash,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(inventory,'UTF8'))
  ||pg_catalog.convert_to('l'||count_sources::text||':','UTF8')||source_bytes||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(abi,'UTF8'));
 if doc<>expected then raise exception 'tesl: queue retirement differs from exact source/target lineage'; end if;
  -- Fence domains are held, then lock the complete old job set. Preflight every
  -- blocker BEFORE restamping: a false result must publish no partial progress.
  perform j.id from ` + ns + `tesl_jobs j where j.schema_version<s.current order by j.seq for update;
  if exists(select 1 from ` + ns + `tesl_jobs j where j.schema_version<s.current and
   (j.schema_version<>s.current-1 or j.status='quarantined'
    or (j.status in ('processing','dead_processing') and j.claimed_by_version<s.current and j.lease_until>pg_catalog.clock_timestamp())
    or not exists(select 1 from ` + ns + `tesl_queue_payloads old join ` + ns + `tesl_queue_payloads target
     on target.version=s.current and target.queue=old.queue and target.job_type=old.job_type
      and target.contract=old.contract and target.contract_hash=old.contract_hash
     where old.version=j.schema_version and old.queue=j.queue and old.job_type=j.job_type)))
   or exists(select 1 from ` + ns + `tesl_row_queue_conversion_attempts a join ` + ns + `tesl_row_queue_conversion_staging staged_source on staged_source.source_digest=a.source_digest where staged_source.from_version<s.current)
   then return false; end if;
  insert into ` + ns + `tesl_row_queue_restamps(job_id,from_version,to_version,queue,job_type,contract_hash,payload_hash,retirement_hash,claim_seq)
  select j.id,j.schema_version,s.current,j.queue,j.job_type,old_payload.contract_hash,
   pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(j.payload::text,'UTF8')),'hex'),digest,j.claim_seq
  from ` + ns + `tesl_jobs j join ` + ns + `tesl_queue_payloads old_payload on old_payload.version=j.schema_version and old_payload.queue=j.queue and old_payload.job_type=j.job_type
  where j.schema_version<s.current;
  update ` + ns + `tesl_jobs j set schema_version=s.current,
   status=case when j.status='processing' and j.claimed_by_version<s.current then 'pending'
               when j.status='dead_processing' and j.claimed_by_version<s.current then 'dead' else j.status end,
   locked_at=case when j.claimed_by_version<s.current then null else j.locked_at end,
   locked_by=case when j.claimed_by_version<s.current then null else j.locked_by end,
   claim_token=case when j.claimed_by_version<s.current then null else j.claim_token end,
   claimed_by_version=case when j.claimed_by_version<s.current then null else j.claimed_by_version end,
   claim_xid=case when j.claimed_by_version<s.current then null else j.claim_xid end,
   lease_until=case when j.claimed_by_version<s.current then null else j.lease_until end
  where j.schema_version<s.current;
  if not ` + ns + `tesl_row_queue_final(s.current) then raise exception 'tesl: queue restamping lost finality'; end if;
  select * into r from ` + ns + `tesl_row_queue_retirements where version=s.current;
 if found then
   if r.retirement<>doc or r.retirement_hash<>digest or r.compiler_abi<>abi or s.min_version<>s.current or s.compat_floor<>s.current then raise exception 'tesl: immutable queue retirement differs'; end if;
  return true;
 end if;
  if s.min_version<>s.current-1 then raise exception 'tesl: queue retirement floor precedes its receipt'; end if;
  insert into ` + ns + `tesl_row_queue_retirements values(s.current,doc,digest,abi);
 insert into ` + ns + `tesl_schema_versions(version,step,artefact_hash,source_abi,stored_value_compatibility,protocol_level,fence_domain,executed_by)
  select s.current,step,digest,abi,p.stored_value_compatibility,1,'tesl-1',pg_catalog.current_setting('application_name')
 from unnest(array['retired','contracting','contracted']) step;
  update ` + ns + `tesl_schema_state set min_version=s.current,compat_floor=s.current where id=1;
 return true;
end`}, {"tesl_row_queue_restamps_valid", "", "boolean", "stable", `
begin
 return not exists(select 1 from ` + ns + `tesl_row_queue_restamps a
  where not exists(select 1 from ` + ns + `tesl_row_queue_retirements r where r.version=a.to_version and r.retirement_hash=a.retirement_hash)
   or not exists(select 1 from ` + ns + `tesl_queue_payloads old join ` + ns + `tesl_queue_payloads target
    on target.version=a.to_version and target.queue=old.queue and target.job_type=old.job_type and target.contract=old.contract and target.contract_hash=old.contract_hash
    where old.version=a.from_version and old.queue=a.queue and old.job_type=a.job_type and old.contract_hash=a.contract_hash));
end`}, {"tesl_row_queue_status", "", "jsonb", "stable", `
declare s ` + ns + `tesl_schema_state%rowtype; jobs jsonb; total_types bigint;
  old_count bigint; rejected_count bigint; invalid_count bigint; live_count bigint; attempt_count bigint; recent_count bigint; restamp_count bigint;
  old_rejected_count bigint; old_invalid_count bigint;
 failed_count bigint; ready_count bigint;
 blockers jsonb:='[]'::jsonb;
begin
 select * into s from ` + ns + `tesl_schema_state where id=1;
 if not found then raise exception 'tesl: queue status requires installed state'; end if;
 select count(*),count(*) filter(where dead_reason='migration-rejected'),count(*) filter(where dead_reason='payload-invalid'),
  count(*) filter(where status in ('processing','dead_processing') and claimed_by_version<s.current and lease_until>pg_catalog.clock_timestamp())
  into old_count,old_rejected_count,old_invalid_count,live_count from ` + ns + `tesl_jobs where schema_version<s.current;
 select count(*) filter(where dead_reason='migration-rejected'),count(*) filter(where dead_reason='payload-invalid')
  into rejected_count,invalid_count from ` + ns + `tesl_jobs;
 select count(*) into failed_count from ` + ns + `tesl_jobs j where j.schema_version<s.current and ` + activeFailure + `;
 select count(*) into ready_count from ` + ns + `tesl_jobs j where j.schema_version<s.current
  and coalesce(j.dead_reason,'') not in ('migration-rejected','payload-invalid')
  and not (j.status in ('processing','dead_processing') and j.claimed_by_version<s.current and j.lease_until>pg_catalog.clock_timestamp())
  and not ` + activeFailure + `;
 select count(*) into attempt_count from ` + ns + `tesl_row_queue_conversion_attempts;
 select count(*) into recent_count from ` + ns + `tesl_schema_instances where version>=s.min_version and version<s.current and last_seen>pg_catalog.clock_timestamp()-interval '30 seconds';
 select count(*) into restamp_count from ` + ns + `tesl_row_queue_restamps;
 select count(*) into total_types from ` + ns + `tesl_queue_payloads where version=s.current;
 select coalesce(pg_catalog.jsonb_agg(x.item order by x.queue collate "C",x.job_type collate "C"),'[]'::jsonb) into jobs from (
  select p.queue,p.job_type,pg_catalog.jsonb_build_object('queue',p.queue,'jobType',p.job_type,
   'oldPayloads',(select count(*) from ` + ns + `tesl_jobs j where j.queue=p.queue and j.job_type=p.job_type and j.schema_version<s.current),
   'rejected',(select count(*) from ` + ns + `tesl_jobs j where j.queue=p.queue and j.job_type=p.job_type and j.dead_reason='migration-rejected'),
   'invalid',(select count(*) from ` + ns + `tesl_jobs j where j.queue=p.queue and j.job_type=p.job_type and j.dead_reason='payload-invalid'),
   'executionFailed',(select count(*) from ` + ns + `tesl_jobs j where j.queue=p.queue and j.job_type=p.job_type and j.schema_version<s.current and ` + activeFailure + `),
   'repairRevision',coalesce((select max(c.revision) from ` + ns + `tesl_row_queue_conversion_staging c where c.to_version=s.current and c.queue=p.queue and c.job_type=p.job_type),0),
   'unchanged',exists(select 1 from ` + ns + `tesl_queue_payloads old where old.version=s.current-1 and old.queue=p.queue and old.job_type=p.job_type and old.contract=p.contract and old.contract_hash=p.contract_hash)) as item
  from ` + ns + `tesl_queue_payloads p where p.version=s.current order by p.queue collate "C",p.job_type collate "C" limit 100
 ) x;
  if old_rejected_count>0 then blockers:=blockers||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('code','QUEUE_MIGRATION_REJECTED','count',old_rejected_count,'action','Deploy a new checked QueueRepair revision; preserve the original payload')); end if;
  if old_invalid_count>0 then blockers:=blockers||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('code','QUEUE_PAYLOAD_INVALID','count',old_invalid_count,'action','Historical decoder rejected the bytes; typed repair cannot fabricate the old record')); end if;
 if live_count>0 then blockers:=blockers||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('code','QUEUE_RETIRING_CLAIMS','count',live_count,'action','Stop old claimants and wait for leases to expire')); end if;
 if attempt_count>0 then blockers:=blockers||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('code','QUEUE_CONVERSION_ATTEMPTS','count',attempt_count,'action','Wait for or restart the schema Worker')); end if;
 if recent_count>0 then blockers:=blockers||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('code','RECENT_RETIRING_INSTANCES','count',recent_count,'action','Stop old processes and wait for the 30-second heartbeat window')); end if;
 if failed_count>0 then blockers:=blockers||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('code','QUEUE_MIGRATION_EXECUTION_FAILED','count',failed_count,'action','Checked execution failed; automatic retries of the same source and bytes are suspended. Preserve the source history. An admitted predecessor may process the original job; typed callback-failure recovery is not yet supported')); end if;
 if ready_count>0 then blockers:=blockers||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('code','QUEUE_OLD_PAYLOADS','count',ready_count,'action','Run the current schema Worker; Contract restamps identical unchanged payloads')); end if;
 return pg_catalog.jsonb_build_object('currentVersion',s.current,'oldPayloads',old_count,'rejected',rejected_count,'invalid',invalid_count,
   'liveRetiringClaims',live_count,'conversionAttempts',attempt_count,'executionFailed',failed_count,'recentRetiringInstances',recent_count,'restamped',restamp_count,
  'totalJobTypes',total_types,'complete',total_types<=100,'jobs',jobs,'blockers',blockers);
end`}}
}

func pgRowQueueRetirementDocument(ctx context.Context, tx pgx.Tx, namespace string, state PgMigrationControlState, target ...int) (pgRowQueueRetirement, error) {
	var result pgRowQueueRetirement
	version := 2
	if len(target) > 0 {
		version = target[0]
	}
	ns := quoteIdentifier(namespace) + "."
	var raw []byte
	var physical, inventory, family string
	err := tx.QueryRow(ctx, "select p.contract,p.contract_hash,p.compiler_abi,q.inventory_hash,r.family from "+ns+"tesl_row_physical p cross join "+ns+"tesl_queue_versions q cross join "+ns+"tesl_row_versions r where p.version=$1 and q.version=$1 and r.version=1", version).Scan(&raw, &physical, &result.abi, &inventory, &family)
	if err != nil {
		return result, err
	}
	plan, err := pgParseRowPhysicalPlan(hex.EncodeToString(raw), physical)
	if err != nil {
		return result, err
	}
	if plan.namespace != namespace || plan.family != family || len(plan.queueConversions) == 0 || len(plan.windows) != 0 || pgRowEpochPreserving(plan) {
		return result, fmt.Errorf("queue retirement requires its exact queue-only target")
	}
	rows, err := tx.Query(ctx, "select queue,job_type,revision,source_digest from "+ns+"tesl_row_queue_conversion_staging where from_version=$1 and to_version=$2 order by queue collate \"C\",job_type collate \"C\",revision", version-1, version)
	if err != nil {
		return result, err
	}
	sources, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (pgRowCanonical, error) {
		var queue, job, digest string
		var revision int
		err := row.Scan(&queue, &job, &revision, &digest)
		return pgRowList(pgRowAtom(queue), pgRowAtom(job), pgRowAtom(fmt.Sprint(revision)), pgRowAtom(digest)), err
	})
	if err != nil {
		return result, err
	}
	if len(sources) == 0 {
		return result, fmt.Errorf("queue retirement has no source lineage")
	}
	document, hash := pgRowBaselineDocument(pgRowList(pgRowAtom("tesl-row-queue-retirement-v1"), pgRowAtom(state.DatabaseUUID), pgRowAtom(fmt.Sprint(state.FenceNamespace)), pgRowAtom(family), pgRowAtom(namespace), pgRowAtom(fmt.Sprint(version-1)), pgRowAtom(fmt.Sprint(version)), pgRowAtom(physical), pgRowAtom(inventory), pgRowList(sources...), pgRowAtom(result.abi)))
	result.document = hex.EncodeToString([]byte(document))
	result.hash = hash
	return result, nil
}

func pgRetireRowQueue(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles) (bool, error) {
	return pgRetireRowQueueChecked(ctx, conn, namespace, roles, nil)
}

func pgRetireRowQueueChecked(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles, check func(pgx.Tx, PgMigrationControlState) error) (bool, error) {
	var initial PgMigrationControlState
	err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles, false); err != nil {
			return err
		}
		var worker bool
		if err := tx.QueryRow(ctx, "select current_user=$1 and session_user=$1", roles.Worker).Scan(&worker); err != nil {
			return err
		}
		if !worker {
			return fmt.Errorf("queue retirement requires exact Worker login")
		}
		var err error
		initial, err = pgInspectRowControl(ctx, tx, namespace, roles)
		if err == nil && check != nil {
			err = check(tx, initial)
		}
		return err
	})
	if err != nil {
		return false, err
	}
	if initial.Current < 2 || (initial.MinVersion != initial.Current-1 && initial.MinVersion != initial.Current) {
		return false, fmt.Errorf("queue retirement requires the published adjacent target")
	}
	var done bool
	err = pgRowEpochDrain(ctx, conn, initial.FenceNamespace, initial.Current-1, initial.Current, func() error {
		return pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
			state, err := pgInspectRowControl(ctx, tx, namespace, roles)
			if err != nil {
				return err
			}
			if state.DatabaseUUID != initial.DatabaseUUID || state.FenceNamespace != initial.FenceNamespace || state.Current != initial.Current || state.MinVersion != initial.MinVersion {
				return fmt.Errorf("queue retirement admission changed while draining")
			}
			if check != nil {
				if err := check(tx, state); err != nil {
					return err
				}
			}
			retirement, err := pgRowQueueRetirementDocument(ctx, tx, namespace, state, initial.Current)
			if err != nil {
				return err
			}
			raw, err := hex.DecodeString(retirement.document)
			if err != nil {
				return err
			}
			return tx.QueryRow(ctx, "select "+quoteIdentifier(namespace)+".tesl_retire_row_queue($1,$2,$3,$4,$5)", state.DatabaseUUID, state.FenceNamespace, raw, retirement.hash, retirement.abi).Scan(&done)
		})
	})
	return done, err
}

func pgExecuteRowQueueContract(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, version int) (PgMigrationControlState, error) {
	var result PgMigrationControlState
	if version < 2 || b.history.CurrentVersion != version || b.target == nil || b.target.version != version || len(b.target.queueConversions) == 0 || len(b.target.windows) != 0 {
		return result, fmt.Errorf("queue Contract requires the current compiled queue-only edge")
	}
	check := func(tx pgx.Tx, state PgMigrationControlState) error {
		if state.Current != version || state.InstallingVersion != 0 {
			return fmt.Errorf("queue Contract requires its expanded current target")
		}
		if _, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false); err != nil {
			return err
		}
		if state.MinVersion >= version {
			return nil
		}
		var recent bool
		if err := tx.QueryRow(ctx, "select exists(select 1 from "+quoteIdentifier(b.history.Namespace)+".tesl_schema_instances where version>=$1 and version<$2 and last_seen>pg_catalog.clock_timestamp()-interval '30 seconds')", state.MinVersion, version).Scan(&recent); err != nil {
			return err
		}
		if recent {
			return fmt.Errorf("queue Contract has recent retiring instances; stop them and wait 30 seconds")
		}
		return nil
	}
	done, err := pgRetireRowQueueChecked(ctx, conn, b.history.Namespace, roles, check)
	if err != nil {
		return result, err
	}
	if !done {
		return result, fmt.Errorf("queue Contract is blocked by old payloads, claims or conversion attempts; complete the checked repairs first")
	}
	err = pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		var err error
		result, _, err = pgReadRowBaselineState(ctx, tx, b, roles, false)
		return err
	})
	return result, err
}

func pgReadRowQueueRetirements(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, state PgMigrationControlState) (map[int]*pgRowQueueRetirement, error) {
	result := map[int]*pgRowQueueRetirement{}
	var valid bool
	if err := tx.QueryRow(ctx, "select "+quoteIdentifier(b.history.Namespace)+".tesl_row_queue_restamps_valid()").Scan(&valid); err != nil {
		return nil, err
	}
	if !valid {
		return nil, fmt.Errorf("queue restamp audit differs from its completed retirement and exact contracts")
	}
	rows, err := tx.Query(ctx, "select version,retirement,retirement_hash,compiler_abi from "+quoteIdentifier(b.history.Namespace)+".tesl_row_queue_retirements order by version")
	if err != nil {
		return nil, err
	}
	type stored struct {
		version   int
		doc       []byte
		hash, abi string
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (stored, error) {
		var r stored
		err := row.Scan(&r.version, &r.doc, &r.hash, &r.abi)
		return r, err
	})
	if err != nil {
		return nil, err
	}
	for _, item := range items {
		expected, err := pgRowQueueRetirementDocument(ctx, tx, b.history.Namespace, state, item.version)
		if err != nil {
			return nil, err
		}
		if item.version < 2 || item.hash != expected.hash || item.abi != expected.abi || !bytes.Equal(item.doc, mustQueueContractBytes(expected.document)) {
			return nil, fmt.Errorf("queue retirement differs from its complete physical/source lineage")
		}
		var final bool
		if err := tx.QueryRow(ctx, "select "+quoteIdentifier(b.history.Namespace)+".tesl_row_queue_final($1)", item.version).Scan(&final); err != nil {
			return nil, err
		}
		if !final {
			return nil, fmt.Errorf("queue retirement still contains old-version jobs")
		}
		result[item.version] = &expected
	}
	return result, nil
}
