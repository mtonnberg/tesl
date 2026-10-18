package teslrt

import (
	"context"
	"encoding/hex"
	"fmt"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgStageCancellation struct {
	version int
	stage   pgStagePreparation
	job     string
}

func pgStageCancellationTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{
		{"tesl_schema_stage_cancellations", `stage_id text primary key, version integer not null check(version>=3), descriptor bytea not null,
 physical_hash text not null, job_id text not null unique, compiler_abi text not null`},
	}
}

func pgStageCancellationFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_stage_cancellations_ready", "v integer", "void", "stable", `
declare p ` + ns + `tesl_row_physical%rowtype; body bytea[]; doc bytea; d bytea[];
begin
 select * into p from ` + ns + `tesl_row_physical where version=v;
 if not found then return; end if;
 if (` + ns + `tesl_row_physical_source_header(p.contract)->>'format')<>'tesl-retained-physical-version-v12' then return; end if;
 body:=` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(p.contract))[4]);
 foreach doc in array ` + ns + `tesl_stage_canonical_children(body[10]) loop
  d:=` + ns + `tesl_stage_canonical_children(doc);
  if not exists(select 1 from ` + ns + `tesl_schema_stage_cancellations c join ` + ns + `tesl_schema_stages s on s.stage_id=c.stage_id and s.descriptor=c.descriptor and s.job_id=c.job_id
   join ` + ns + `tesl_schema_index j on j.id=c.job_id and j.state='terminal' and j.terminal_version=c.version
   where c.version=v and c.physical_hash=p.contract_hash and c.descriptor=doc and c.stage_id=` + ns + `tesl_stage_atom(d[2]) and s.state='cancelled') then raise exception 'tesl: pending-stage cancellation is incomplete'; end if;
 end loop;
end`},
		{"tesl_finish_stage_cancellation", "v integer, doc bytea, abi text", "void", "volatile", `
declare p ` + ns + `tesl_row_physical%rowtype; s ` + ns + `tesl_schema_stages%rowtype; body bytea[]; d bytea[]; uuid bytea; domain bytea; job bytea; lock_digest bytea; prior ` + ns + `tesl_schema_stage_cancellations%rowtype;
begin
 select * into p from ` + ns + `tesl_row_physical where version=v for share;
 if not found or abi is null or abi!~'^tesl-source-abi-v1:[0-9a-f]{64}$' then raise exception 'tesl: cancellation lacks physical source'; end if;
 body:=` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(p.contract))[4]);
 if pg_catalog.cardinality(body)<>10 or ` + ns + `tesl_stage_atom(body[1])<>'tesl-retained-physical-version-v12'
  or pg_catalog.array_position(` + ns + `tesl_stage_canonical_children(body[10]),doc) is null
  or pg_catalog.array_position(` + ns + `tesl_stage_canonical_children(body[9]),doc) is null then raise exception 'tesl: cancellation is not a direct source decision'; end if;
 d:=` + ns + `tesl_stage_canonical_children(doc);
 if pg_catalog.cardinality(d)<>10 then raise exception 'tesl: cancellation descriptor malformed'; end if;
 select * into s from ` + ns + `tesl_schema_stages where stage_id=` + ns + `tesl_stage_atom(d[2]) for update;
 if not found or s.descriptor<>doc or s.introduced_version>=v or s.state not in ('pending','cancelled')
  or exists(select 1 from ` + ns + `tesl_schema_stage_guards where stage_id=s.stage_id) then raise exception 'tesl: only exact pending unguarded stages can be cancelled'; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_state where id=1 and current>=v and min_version>=v and compat_floor>=v)
  or not exists(select 1 from ` + ns + `tesl_row_epochs where through_version=v) then raise exception 'tesl: cancellation requires fenced retirement'; end if;
 select pg_catalog.convert_to(database_uuid::text,'UTF8') into uuid from ` + ns + `tesl_schema_meta where id=1;
 domain:=pg_catalog.convert_to('tesl-ddl-job','UTF8');job:=pg_catalog.convert_to(s.job_id,'UTF8');
 lock_digest:=pg_catalog.sha256(pg_catalog.int4send(pg_catalog.octet_length(uuid))||uuid||pg_catalog.int4send(pg_catalog.octet_length(domain))||domain||pg_catalog.int4send(pg_catalog.octet_length(job))||job);
 if not exists(select 1 from pg_catalog.pg_locks l where l.pid=pg_catalog.pg_backend_pid() and l.locktype='advisory' and l.granted and l.mode='ExclusiveLock' and l.objsubid=1
  and l.classid=(('x'||pg_catalog.encode(pg_catalog.substring(lock_digest,1,4),'hex'))::bit(32)::bigint)::oid
  and l.objid=(('x'||pg_catalog.encode(pg_catalog.substring(lock_digest,5,4),'hex'))::bit(32)::bigint)::oid) then raise exception 'tesl: cancellation requires the exclusive index-job barrier'; end if;
 if pg_catalog.to_regclass(pg_catalog.format('%I.%I',` + pgStageGuardSQLLiteral(namespace) + `,s.index_name)) is not null then raise exception 'tesl: cancellation index retirement is incomplete'; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_index j where j.id=s.job_id and j.index_name=s.index_name and j.table_name=s.table_name and not j.is_unique and j.key_columns=array[` + ns + `tesl_stage_atom(d[7])]) then raise exception 'tesl: cancellation job differs'; end if;
 insert into ` + ns + `tesl_schema_stage_cancellations values(s.stage_id,v,doc,p.contract_hash,s.job_id,abi) on conflict(stage_id) do nothing;
 select * into prior from ` + ns + `tesl_schema_stage_cancellations where stage_id=s.stage_id;
 if prior.version<>v or prior.descriptor<>doc or prior.physical_hash<>p.contract_hash or prior.job_id<>s.job_id then raise exception 'tesl: cancellation receipt differs'; end if;
 update ` + ns + `tesl_schema_index set state='terminal',terminal_version=v,error=null where id=s.job_id;
 update ` + ns + `tesl_schema_leases set holder=null,expires_at=null where name='index:'||s.index_name;
 update ` + ns + `tesl_schema_stages set state='cancelled' where stage_id=s.stage_id;
end`}}
}

func pgStageCancellationAuthorities(ctx context.Context, tx pgx.Tx, namespace string) (map[string]pgStageCancellation, error) {
	result := map[string]pgStageCancellation{}
	ns := quoteIdentifier(namespace) + "."
	var format int
	if err := tx.QueryRow(ctx, "select format_version from "+ns+"tesl_schema_meta where id=1").Scan(&format); err != nil {
		return nil, err
	}
	if format != pgRowControlFormat {
		return result, nil
	}
	rows, err := tx.Query(ctx, `select c.stage_id,c.version,c.descriptor,c.physical_hash,c.job_id,c.compiler_abi,p.contract,p.contract_hash,s.descriptor,s.job_id,
 st.min_version,st.compat_floor,exists(select 1 from `+ns+`tesl_row_epochs where through_version=c.version)
 from `+ns+`tesl_schema_stage_cancellations c left join `+ns+`tesl_row_physical p on p.version=c.version
 left join `+ns+`tesl_schema_stages s on s.stage_id=c.stage_id cross join `+ns+`tesl_schema_state st where st.id=1 order by c.stage_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, hash, job, abi, actualHash, actualJob string
		var v, min, floor int
		var doc, physical, original []byte
		var epoch bool
		if err := rows.Scan(&id, &v, &doc, &hash, &job, &abi, &physical, &actualHash, &original, &actualJob, &min, &floor, &epoch); err != nil {
			return nil, err
		}
		p, err := pgParseRowPhysicalPlan(hex.EncodeToString(physical), actualHash)
		if err != nil {
			return nil, err
		}
		at := slices.IndexFunc(p.stageCancellations, func(s pgStagePreparation) bool { return s.id == id && s.descriptor == string(doc) })
		if p.version != v || hash != actualHash || at < 0 || string(original) != string(doc) || job != actualJob || min < v || floor < v || !epoch || !strings.HasPrefix(abi, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(abi, "tesl-source-abi-v1:")) {
			return nil, fmt.Errorf("cancellation receipt lacks exact source, predecessor or retirement")
		}
		result[job] = pgStageCancellation{v, p.stageCancellations[at], job}
	}
	return result, rows.Err()
}

func pgExecuteStageCancellations(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, requireDrained bool) (PgMigrationControlState, error) {
	var state PgMigrationControlState
	if b.target == nil || len(b.target.stageCancellations) == 0 {
		return state, fmt.Errorf("missing compiled cancellation window")
	}
	complete := false
	if err := pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		var err error
		state, _, err = pgReadRowIndexExecutionState(ctx, tx, b, roles)
		if err != nil {
			return err
		}
		receipts, err := pgStageCancellationAuthorities(ctx, tx, b.history.Namespace)
		if err != nil {
			return err
		}
		complete = true
		for _, s := range b.target.stageCancellations {
			found := false
			for _, c := range receipts {
				if c.version == b.target.version && c.stage == s {
					found = true
					break
				}
			}
			if !found {
				complete = false
			}
		}
		return nil
	}); err != nil {
		return state, err
	}
	if complete {
		return state, nil
	}
	if _, err := pgExecuteRowEpoch(ctx, conn, b, roles, b.target.version, !requireDrained, false); err != nil {
		return state, err
	}
	if err := pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		var err error
		state, _, err = pgReadRowIndexExecutionState(ctx, tx, b, roles)
		return err
	}); err != nil {
		return state, err
	}
	for _, stage := range b.target.stageCancellations {
		var job pgMigrationIndexJob
		err := pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
			intents, err := pgReadExpansionIntents(ctx, tx, b.history.Namespace)
			if err != nil {
				return err
			}
			jobs, err := pgReadMigrationIndexJobRows(ctx, tx, b.history.Namespace, intents)
			if err != nil {
				return err
			}
			for _, j := range jobs {
				if j.Index.Name == stage.index && j.Table == stage.table {
					job = j
					return nil
				}
			}
			return fmt.Errorf("cancellation lacks original prep job")
		})
		if err != nil {
			return state, err
		}
		if job.State == "terminal" {
			continue
		}
		err = pgIndexJobLockMode(ctx, conn, pgMigrationDDLJobKey(state.DatabaseUUID, job.ID), true, func() error {
			observation, err := pgIndexObserve(ctx, conn, b.history.Namespace, roles.Worker, job)
			if err != nil {
				return err
			}
			if observation.active {
				return fmt.Errorf("cancellation found an active index executor beyond its barrier")
			}
			err = pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
				migrationBoundary("stage-cancel-before-drop")
				if _, err := tx.Exec(ctx, "drop index if exists "+pgx.Identifier{b.history.Namespace, stage.index}.Sanitize()); err != nil {
					return err
				}
				if _, err := tx.Exec(ctx, "select "+pgx.Identifier{b.history.Namespace, "tesl_finish_stage_cancellation"}.Sanitize()+"($1,$2,$3)", b.target.version, []byte(stage.descriptor), b.history.SourceCompilerABI); err != nil {
					return err
				}
				migrationBoundary("stage-cancel-after-receipt")
				return nil
			})
			if err == nil {
				migrationBoundary("stage-cancel-after-commit")
			}
			return err
		})
		if err != nil {
			return state, err
		}
	}
	err := pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		var err error
		state, _, err = pgReadRowIndexExecutionState(ctx, tx, b, roles)
		return err
	})
	return state, err
}
