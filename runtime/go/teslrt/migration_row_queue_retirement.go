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
 version integer primary key check(version=2), retirement bytea not null,
 retirement_hash text not null check(retirement_hash ~ '^[0-9a-f]{64}$'),
 compiler_abi text not null check(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'),
 check(pg_catalog.encode(pg_catalog.sha256(retirement),'hex')=retirement_hash)`}}
}

func pgRowQueueRetirementFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{{"tesl_row_queue_final", "v integer", "boolean", "stable", `
begin
 if v is distinct from 2 then raise exception 'tesl: queue finality requires the V2 target'; end if;
 return not exists(select 1 from ` + ns + `tesl_jobs where schema_version<v)
  and not exists(select 1 from ` + ns + `tesl_jobs where status in ('processing','dead_processing') and claimed_by_version<v)
  and not exists(select 1 from ` + ns + `tesl_row_queue_conversion_attempts);
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
 if not found or s.current<>2 or s.min_version not in (1,2) then raise exception 'tesl: queue retirement requires the current V2 edge'; end if;
 select * into p from ` + ns + `tesl_row_physical where version=2;
 if not found or p.epoch_preserving or p.operation_count<>0 or p.compiler_abi<>abi
  or not exists(select 1 from ` + ns + `tesl_row_queue_target_staging t where t.version=2 and t.contract=p.contract and t.contract_hash=p.contract_hash and t.database_uuid::text=uuid and t.fence_ns=fence)
  or not exists(select 1 from ` + ns + `tesl_schema_versions where version=2 and step='expanded' and artefact_hash=p.contract_hash and source_abi=abi) then
  raise exception 'tesl: queue retirement lacks its exact completed physical target'; end if;
 -- Both domains must be drained by the calling runtime before this transaction.
 foreach n in array array[fence,-fence] loop
  if not exists(select 1 from pg_catalog.pg_locks where locktype='advisory' and pid=pg_catalog.pg_backend_pid() and granted
   and classid=(case when n<0 then 4294967296::bigint+n else n::bigint end)::oid
   and objid=1::oid and objsubid=2 and mode='ExclusiveLock') then
   raise exception 'tesl: queue retirement lacks its exclusive source fence'; end if;
 end loop;
 select baseline.family,q.inventory_hash into family,inventory from ` + ns + `tesl_row_versions baseline cross join ` + ns + `tesl_queue_versions q where baseline.version=1 and q.version=2;
 if not found then raise exception 'tesl: queue retirement source inventory is missing'; end if;
 for c in select queue,job_type,revision,source_digest from ` + ns + `tesl_row_queue_conversion_staging where from_version=1 and to_version=2 order by queue collate "C",job_type collate "C",revision loop
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
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to('1','UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to('2','UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(p.contract_hash,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(inventory,'UTF8'))
  ||pg_catalog.convert_to('l'||count_sources::text||':','UTF8')||source_bytes||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(abi,'UTF8'));
 if doc<>expected then raise exception 'tesl: queue retirement differs from exact source/target lineage'; end if;
 if not ` + ns + `tesl_row_queue_final(2) then return false; end if;
 select * into r from ` + ns + `tesl_row_queue_retirements where version=2;
 if found then
  if r.retirement<>doc or r.retirement_hash<>digest or r.compiler_abi<>abi or s.min_version<>2 or s.compat_floor<>2 then raise exception 'tesl: immutable queue retirement differs'; end if;
  return true;
 end if;
 if s.min_version<>1 then raise exception 'tesl: queue retirement floor precedes its receipt'; end if;
 insert into ` + ns + `tesl_row_queue_retirements values(2,doc,digest,abi);
 insert into ` + ns + `tesl_schema_versions(version,step,artefact_hash,source_abi,stored_value_compatibility,protocol_level,fence_domain,executed_by)
 select 2,step,digest,abi,p.stored_value_compatibility,1,'tesl-1',pg_catalog.current_setting('application_name')
 from unnest(array['retired','contracting','contracted']) step;
 update ` + ns + `tesl_schema_state set min_version=2,compat_floor=2 where id=1;
 return true;
end`}}
}

func pgRowQueueRetirementDocument(ctx context.Context, tx pgx.Tx, namespace string, state PgMigrationControlState) (pgRowQueueRetirement, error) {
	var result pgRowQueueRetirement
	ns := quoteIdentifier(namespace) + "."
	var raw []byte
	var physical, inventory, family string
	err := tx.QueryRow(ctx, "select p.contract,p.contract_hash,p.compiler_abi,q.inventory_hash,r.family from "+ns+"tesl_row_physical p cross join "+ns+"tesl_queue_versions q cross join "+ns+"tesl_row_versions r where p.version=2 and q.version=2 and r.version=1").Scan(&raw, &physical, &result.abi, &inventory, &family)
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
	rows, err := tx.Query(ctx, "select queue,job_type,revision,source_digest from "+ns+"tesl_row_queue_conversion_staging where from_version=1 and to_version=2 order by queue collate \"C\",job_type collate \"C\",revision")
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
	document, hash := pgRowBaselineDocument(pgRowList(pgRowAtom("tesl-row-queue-retirement-v1"), pgRowAtom(state.DatabaseUUID), pgRowAtom(fmt.Sprint(state.FenceNamespace)), pgRowAtom(family), pgRowAtom(namespace), pgRowAtom("1"), pgRowAtom("2"), pgRowAtom(physical), pgRowAtom(inventory), pgRowList(sources...), pgRowAtom(result.abi)))
	result.document = hex.EncodeToString([]byte(document))
	result.hash = hash
	return result, nil
}

func pgRetireRowQueue(ctx context.Context, conn *pgx.Conn, namespace string, roles PgMigrationControlRoles) (bool, error) {
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
		return err
	})
	if err != nil {
		return false, err
	}
	if initial.Current != 2 {
		return false, fmt.Errorf("queue retirement requires the published V2 target")
	}
	var done bool
	err = pgRowEpochDrain(ctx, conn, initial.FenceNamespace, 1, 2, func() error {
		return pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
			state, err := pgInspectRowControl(ctx, tx, namespace, roles)
			if err != nil {
				return err
			}
			if state.DatabaseUUID != initial.DatabaseUUID || state.FenceNamespace != initial.FenceNamespace || state.Current != initial.Current || state.MinVersion != initial.MinVersion {
				return fmt.Errorf("queue retirement admission changed while draining")
			}
			retirement, err := pgRowQueueRetirementDocument(ctx, tx, namespace, state)
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

func pgReadRowQueueRetirements(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, state PgMigrationControlState) (map[int]*pgRowQueueRetirement, error) {
	result := map[int]*pgRowQueueRetirement{}
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
		expected, err := pgRowQueueRetirementDocument(ctx, tx, b.history.Namespace, state)
		if err != nil {
			return nil, err
		}
		if item.version != 2 || item.hash != expected.hash || item.abi != expected.abi || !bytes.Equal(item.doc, mustQueueContractBytes(expected.document)) {
			return nil, fmt.Errorf("queue retirement differs from its complete physical/source lineage")
		}
		var final bool
		if err := tx.QueryRow(ctx, "select "+quoteIdentifier(b.history.Namespace)+".tesl_row_queue_final(2)").Scan(&final); err != nil {
			return nil, err
		}
		if !final {
			return nil, fmt.Errorf("queue retirement still contains old-version jobs")
		}
		result[item.version] = &expected
	}
	return result, nil
}
