package teslrt

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// This descriptor never contains SQL. The only supported index is a plain btree
// with default builtin operator classes, NULLS DISTINCT and no expression,
// predicate, INCLUDE columns or constraint ownership. Catalog readers establish
// that finite shape independently; a job state alone never proves readiness.
type pgMigrationIndexJob struct {
	Version, Ordinal                 int
	ID, ObjectHash, SourceABI, Table string
	Index                            PgMigrationCatalogIndex
	State                            string
	TerminalVersion                  *int
	Holder                           string
	Token                            int64
	ExpiresAt                        *time.Time
	Attempts                         int64
	Error                            string
}

var pgMigrationIndexTables = []pgMigrationControlTable{
	{"tesl_schema_index", `
 id text primary key,
 version integer not null check (version between 1 and 2147483646),
 ordinal integer not null check (ordinal >= 0),
 table_name text not null,
 index_name text not null unique,
 key_columns text[] not null,
 is_unique boolean not null,
 state text not null default 'pending' check (state in ('pending','building','valid','failed','terminal')),
 terminal_version integer check (terminal_version between 1 and 2147483646),
 attempts bigint not null default 0 check (attempts >= 0),
 error text,
 check ((state = 'terminal') = (terminal_version is not null)),
 unique (version, ordinal)`},
	{"tesl_schema_leases", `
 name text primary key,
 holder text,
 token bigint not null default 0 check (token >= 0),
 expires_at timestamptz,
 check ((holder is null) = (expires_at is null))`},
}

var pgMigrationControlTables = append(append([]pgMigrationControlTable{}, pgMigrationControlTablesV2...), pgMigrationIndexTables...)

func pgSupportedMigrationControlFormat(format int) bool { return format == 2 || format == 3 }

func pgControlTablesForFormat(format int) []pgMigrationControlTable {
	if format == 2 {
		return pgMigrationControlTablesV2
	}
	if format == 3 {
		return pgMigrationControlTables
	}
	return nil
}

func pgMigrationControlFunctions(namespace string) []pgMigrationControlFunction {
	return pgControlFunctionsForFormat(namespace, pgMigrationControlFormat)
}

func pgControlFunctionsForFormat(namespace string, format int) []pgMigrationControlFunction {
	if !pgSupportedMigrationControlFormat(format) {
		return nil
	}
	functions := pgMigrationControlFunctionsV2(namespace)
	if format == 3 {
		functions = append(functions, pgMigrationIndexFunctions(namespace)...)
	}
	return functions
}

// The caller has already verified the exact control format and reads all rows
// under the same snapshot. Future jobs need the same immutable intent binding as
// locally known jobs; their descriptors are subsequently checked against actual
// catalog semantics and the reader's own admitted schema.
func pgReadMigrationIndexJobs(ctx context.Context, tx pgx.Tx, namespace string, intents map[int]*pgExpansionIntent) ([]pgMigrationIndexJob, error) {
	ns := quoteIdentifier(namespace) + "."
	rows, err := tx.Query(ctx, `select j.version,j.ordinal,j.id,j.table_name,j.index_name,j.key_columns,j.is_unique,
 j.state,j.terminal_version,j.attempts,j.error,l.name,coalesce(l.holder,''),l.token,l.expires_at,
 pg_catalog.array_ndims(j.key_columns),pg_catalog.array_lower(j.key_columns,1),pg_catalog.array_upper(j.key_columns,1)
 from `+ns+`tesl_schema_index j left join `+ns+`tesl_schema_leases l on l.name='index:' || j.index_name order by j.version,j.ordinal`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var jobs []pgMigrationIndexJob
	for rows.Next() {
		var job pgMigrationIndexJob
		var leaseName *string
		var token *int64
		var detail *string
		var dimensions, lower, upper *int
		if err := rows.Scan(&job.Version, &job.Ordinal, &job.ID, &job.Table, &job.Index.Name, &job.Index.Columns, &job.Index.Unique,
			&job.State, &job.TerminalVersion, &job.Attempts, &detail, &leaseName, &job.Holder, &token, &job.ExpiresAt,
			&dimensions, &lower, &upper); err != nil {
			return nil, err
		}
		intent := intents[job.Version]
		if intent == nil || job.Ordinal < 0 || job.Ordinal >= len(intent.Objects) ||
			job.ID != pgMigrationObjectHash(intent.ArtifactHash, job.Ordinal) || intent.Objects[job.Ordinal] != job.ID ||
			!pgMigrationIdentifier(job.Table) || !pgMigrationIdentifier(job.Index.Name) ||
			len(job.Index.Columns) == 0 || len(job.Index.Columns) > 32 || job.Attempts < 0 ||
			dimensions == nil || *dimensions != 1 || lower == nil || *lower != 1 || upper == nil || *upper != len(job.Index.Columns) ||
			leaseName == nil || *leaseName != "index:"+job.Index.Name || token == nil || *token < 0 ||
			(job.Holder == "") != (job.ExpiresAt == nil) || (job.Holder != "" && (!pgMigrationIndexHolder(job.Holder) || *token == 0)) {
			return nil, fmt.Errorf("migration index descriptor or lease lacks matching immutable intent at V%d object %d", job.Version, job.Ordinal)
		}
		seen := map[string]bool{}
		for _, key := range job.Index.Columns {
			if !pgMigrationIdentifier(key) || seen[key] {
				return nil, fmt.Errorf("migration index %s has invalid or repeated key columns", job.Index.Name)
			}
			seen[key] = true
		}
		switch job.State {
		case "pending", "building", "valid", "failed", "terminal":
		default:
			return nil, fmt.Errorf("migration index %s has an unsupported lifecycle state", job.Index.Name)
		}
		if (job.State == "terminal") != (job.TerminalVersion != nil) ||
			(job.TerminalVersion != nil && (*job.TerminalVersion < job.Version || *job.TerminalVersion > 2147483646)) {
			return nil, fmt.Errorf("migration index %s has an invalid removal target", job.Index.Name)
		}
		if job.State == "failed" && (detail == nil || *detail == "") || job.State != "failed" && detail != nil ||
			detail != nil && len(*detail) > 8192 || job.State == "building" && job.Attempts == 0 {
			return nil, fmt.Errorf("migration index %s has invalid failure or attempt evidence", job.Index.Name)
		}
		if detail != nil {
			job.Error = *detail
		}
		job.ObjectHash, job.SourceABI, job.Token = job.ID, intent.SourceABI, *token
		jobs = append(jobs, job)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	var orphan bool
	if err := tx.QueryRow(ctx, `select exists(select 1 from `+ns+`tesl_schema_leases l where not exists
 (select 1 from `+ns+`tesl_schema_index j where l.name='index:' || j.index_name))`).Scan(&orphan); err != nil {
		return nil, err
	}
	if orphan {
		return nil, fmt.Errorf("migration index lease has no matching immutable job")
	}
	return jobs, nil
}

func pgMigrationIndexHolder(holder string) bool {
	if !strings.HasPrefix(holder, "tesl-exec:") || len(holder) <= len("tesl-exec:") || len(holder) > 63 {
		return false
	}
	for _, c := range strings.TrimPrefix(holder, "tesl-exec:") {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func pgMigrationIndexFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_register_index", "j text, v integer, n integer, tbl text, idx text, cols text[], uniq boolean", "void", "volatile", `
declare intent ` + ns + `tesl_schema_expansions%rowtype; existing ` + ns + `tesl_schema_index%rowtype; c integer;
begin
 select current into c from ` + ns + `tesl_schema_state where id=1 for update;
 if not found then raise exception 'tesl: index expansion state is missing'; end if;
 select * into intent from ` + ns + `tesl_schema_expansions where version=v;
 if not found or n is null or n<0 or n>=intent.operation_count or j is null or
   j is distinct from pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('tesl-migration-object-v1','UTF8') ||
     pg_catalog.decode(intent.artefact_hash,'hex') || pg_catalog.int4send(n)),'hex') or
   tbl is null or pg_catalog.octet_length(tbl) not between 1 and 63 or idx is null or pg_catalog.octet_length(idx) not between 1 and 63 or
   uniq is null or cols is null or pg_catalog.array_ndims(cols) is distinct from 1 or pg_catalog.array_lower(cols,1) is distinct from 1 or
   pg_catalog.cardinality(cols) not between 1 and 32 or exists(select 1 from pg_catalog.unnest(cols) k where k is null or pg_catalog.octet_length(k) not between 1 and 63) or
   (select pg_catalog.count(distinct k) from pg_catalog.unnest(cols) k) <> pg_catalog.cardinality(cols) then
   raise exception 'tesl: invalid index descriptor or expansion identity';
 end if;
 select * into existing from ` + ns + `tesl_schema_index where id=j;
 if found then
   if existing.version is distinct from v or existing.ordinal is distinct from n or existing.table_name is distinct from tbl or
     existing.index_name is distinct from idx or existing.key_columns is distinct from cols or existing.is_unique is distinct from uniq then
     raise exception 'tesl: immutable index descriptor differs';
   end if;
   if not exists(select 1 from ` + ns + `tesl_schema_leases where name='index:' || idx) then
     raise exception 'tesl: index lease is missing';
   end if;
 else
   if c>=v then raise exception 'tesl: cannot append index jobs to completed history'; end if;
   insert into ` + ns + `tesl_schema_index(id,version,ordinal,table_name,index_name,key_columns,is_unique) values(j,v,n,tbl,idx,cols,uniq);
   insert into ` + ns + `tesl_schema_leases(name) values('index:' || idx);
 end if;
 perform ` + ns + `tesl_record_expansion_object(v,n,j);
end`},
		{"tesl_claim_index", "j text, v integer, abi text, ttl_ms integer", "bigint", "volatile", `
declare job ` + ns + `tesl_schema_index%rowtype; lease ` + ns + `tesl_schema_leases%rowtype;
 who text := pg_catalog.current_setting('application_name',true); creator text; result bigint;
begin
 if who is null or who !~ '^tesl-exec:[A-Za-z0-9_-]{1,53}$' or ttl_ms is null or ttl_ms<1 or ttl_ms>600000 then
   raise exception 'tesl: invalid index executor identity or lease duration';
 end if;
 perform ` + ns + `tesl_admit(v);
 select * into job from ` + ns + `tesl_schema_index where id=j for update;
 if not found then raise exception 'tesl: index job is missing'; end if;
 if v<job.version then raise exception 'tesl: index executor version predates its job'; end if;
 if job.state in ('valid','terminal') then return 0; end if;
 select source_abi into creator from ` + ns + `tesl_schema_expansions where version=job.version;
 if not found or abi is null or abi is distinct from creator then raise exception 'tesl: unfinished index compiler ABI differs'; end if;
 select * into lease from ` + ns + `tesl_schema_leases where name='index:' || job.index_name for update;
 if not found then raise exception 'tesl: index lease is missing'; end if;
 -- Expiry cannot establish that an autocommit statement stopped. A successor
 -- may claim only after every backend carrying the old full tag has disappeared.
 if lease.holder is not null and exists(select 1 from pg_catalog.pg_stat_activity where datname=pg_catalog.current_database() and application_name=lease.holder) then return 0; end if;
 if lease.token=9223372036854775807 then raise exception 'tesl: index fencing token exhausted'; end if;
 update ` + ns + `tesl_schema_leases set holder=who,token=token+1,
   expires_at=pg_catalog.clock_timestamp()+ttl_ms*interval '1 millisecond' where name=lease.name returning token into result;
 return result;
end`},
		{"tesl_renew_index", "j text, tok bigint, ttl_ms integer", "boolean", "volatile", `
declare job ` + ns + `tesl_schema_index%rowtype;
begin
 if ttl_ms is null or ttl_ms<1 or ttl_ms>600000 then raise exception 'tesl: invalid index lease duration'; end if;
 select * into job from ` + ns + `tesl_schema_index where id=j for update;
 if not found or job.state in ('valid','terminal') then return false; end if;
 update ` + ns + `tesl_schema_leases set expires_at=pg_catalog.clock_timestamp()+ttl_ms*interval '1 millisecond'
 where name='index:' || job.index_name and token=tok and holder=pg_catalog.current_setting('application_name',true)
   and expires_at>pg_catalog.clock_timestamp();
 return found;
end`},
		{"tesl_release_index", "j text, tok bigint", "boolean", "volatile", `
declare job ` + ns + `tesl_schema_index%rowtype;
begin
 select * into job from ` + ns + `tesl_schema_index where id=j for update;
 if not found or job.state='terminal' then return false; end if;
 update ` + ns + `tesl_schema_leases set holder=null,expires_at=null
 where name='index:' || job.index_name and token=tok and holder=pg_catalog.current_setting('application_name',true);
 return found;
end`},
		{"tesl_record_index_state", "j text, tok bigint, new_state text, detail text", "boolean", "volatile", `
declare job ` + ns + `tesl_schema_index%rowtype;
begin
 if new_state is null or new_state not in ('building','valid','failed') or
   (new_state='failed' and (detail is null or detail='')) or (new_state<>'failed' and detail is not null) or
   pg_catalog.octet_length(detail)>8192 then raise exception 'tesl: invalid index state update'; end if;
 select * into job from ` + ns + `tesl_schema_index where id=j for update;
 if not found or job.state in ('valid','terminal') then return false; end if;
 perform 1 from ` + ns + `tesl_schema_leases where name='index:' || job.index_name and token=tok
   and holder=pg_catalog.current_setting('application_name',true) and expires_at>pg_catalog.clock_timestamp() for update;
 if not found then return false; end if;
 if new_state='building' and job.attempts=9223372036854775807 then raise exception 'tesl: index attempts exhausted'; end if;
 update ` + ns + `tesl_schema_index set state=new_state,error=detail,
   attempts=attempts+case when new_state='building' then 1 else 0 end where id=j;
 return true;
end`},
	}
}
