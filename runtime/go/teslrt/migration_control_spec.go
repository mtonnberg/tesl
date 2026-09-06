package teslrt

// The initial production format supports additive expansion only. These closed
// definitions serve both installation and same-server catalog comparison; they
// are never assembled from a source program's SQL or a database's stored text.
const pgMigrationControlFormat = 3

type pgMigrationControlTable struct{ name, columns string }

var pgMigrationControlTablesV2 = []pgMigrationControlTable{
	{"tesl_schema_meta", `
 id smallint primary key check (id = 1),
 format_version integer not null,
 database_uuid uuid not null unique,
 initial_version integer not null check (initial_version between 1 and 2147483646),
 max_observed_protocol integer not null,
 retirement_protocol_floor integer not null,
 fence_ns integer not null check (fence_ns between 1 and 2147483646),
 fence_domain text not null`},
	{"tesl_schema_state", `
 id smallint primary key check (id = 1),
 min_version integer not null,
 current integer not null,
 installing_version integer,
 compat_floor integer not null default 0`},
	{"tesl_schema_versions", `
 version integer not null,
 step text not null check (step in ('expanded','retired','contracting','contracted','repair')),
 seq smallint not null default 0,
 snapshot_hash text,
 artefact_hash text not null,
 source_abi text not null,
 stored_value_compatibility text not null,
 applied_at timestamptz not null default pg_catalog.now(),
 protocol_level integer not null,
 fence_domain text not null,
 epoch_preserving boolean,
 executed_by text,
 check ((step = 'expanded') = (epoch_preserving is not null)),
 primary key (version, step, seq)`},
	{"tesl_schema_expansions", `
 version integer primary key check (version between 1 and 2147483646),
 snapshot_hash text not null,
 artefact_hash text not null,
 source_abi text not null,
 stored_value_compatibility text not null,
 operation_count integer not null check (operation_count >= 0),
 epoch_preserving boolean not null,
 started_at timestamptz not null default pg_catalog.now()`},
	{"tesl_schema_expansion_objects", `
 version integer not null,
 ordinal integer not null check (ordinal >= 0),
 operation_hash text not null,
 committed_at timestamptz not null default pg_catalog.now(),
 primary key (version, ordinal)`},
	{"tesl_schema_instances", `
 instance text primary key,
 version integer not null,
 protocol_level integer not null,
 last_seen timestamptz not null,
 compat_floor_seen integer not null default 0`},
}

var pgMigrationFenceRegistry = pgMigrationControlTable{"tesl_fence_namespaces", `
 fence_ns integer generated always as identity primary key check (fence_ns between 1 and 2147483646),
 database_uuid uuid not null unique`}

type pgMigrationControlFunction struct {
	name, arguments, result, volatility, body string
}

// Function bodies use only pg_catalog functions and explicitly qualified control
// tables. The installer adds SECURITY DEFINER, an empty search_path and ownership
// by the no-login control role, and revokes PUBLIC in the creation transaction.
// There is no entity DDL or arbitrary SQL entry point in this interface.
func pgMigrationControlFunctionsV2(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_admit", "v integer", "integer", "stable", `
declare s ` + ns + `tesl_schema_state%rowtype;
begin
 select * into s from ` + ns + `tesl_schema_state where id = 1;
 if not found then raise exception 'tesl: admission state is missing'; end if;
 if v is null or v < 1 or v > 2147483646 then raise exception 'tesl: invalid schema version'; end if;
 if v < s.min_version then raise exception 'tesl: schema version % is retired (min_version %)', v, s.min_version; end if;
 if s.current = 0 or v > s.current then raise exception 'tesl: schema version % is not installed', v; end if;
 if v < s.current - 1 and exists (select 1 from ` + ns + `tesl_schema_versions
   where step = 'expanded' and version > v and version <= s.current and not epoch_preserving) then
   raise exception 'tesl: schema version % must be deployed in order', v;
 end if;
 return s.compat_floor;
end`},
		{"tesl_begin_expansion", "v integer, snap text, art text, abi text, compatibility text, ops integer, ep boolean", "void", "volatile", `
declare s ` + ns + `tesl_schema_state%rowtype; r ` + ns + `tesl_schema_expansions%rowtype;
begin
 if v is null or v < 1 or v > 2147483646 or snap is null or art is null or
   snap !~ '^[0-9a-f]{64}$' or art !~ '^[0-9a-f]{64}$' or abi is null or abi !~ '^tesl-source-abi-v1:[0-9a-f]{64}$' or
   compatibility is null or compatibility !~ '^tesl-stored-value-v1:[0-9a-f]{64}$' or
   ops is null or ops < 0 or ep is distinct from true then
   raise exception 'tesl: invalid additive expansion intent';
 end if;
 select * into s from ` + ns + `tesl_schema_state where id = 1 for update;
 if not found then raise exception 'tesl: expansion state is missing'; end if;
 if (s.current = 0 and s.installing_version is distinct from v) or
   (s.current <> 0 and v <> s.current + 1 and not exists
     (select 1 from ` + ns + `tesl_schema_expansions where version = v)) then
   raise exception 'tesl: expansion must follow the recorded installation target and history';
 end if;
 insert into ` + ns + `tesl_schema_expansions(version,snapshot_hash,artefact_hash,source_abi,stored_value_compatibility,operation_count,epoch_preserving)
   values (v,snap,art,abi,compatibility,ops,ep) on conflict (version) do nothing;
 select * into r from ` + ns + `tesl_schema_expansions where version = v;
 if r.snapshot_hash is distinct from snap or r.artefact_hash is distinct from art or
   r.source_abi is distinct from abi or r.stored_value_compatibility is distinct from compatibility or
   r.operation_count is distinct from ops or r.epoch_preserving is distinct from ep then
   raise exception 'tesl: immutable expansion intent differs at V%', v;
 end if;
end`},
		{"tesl_record_expansion_object", "v integer, n integer, art text", "void", "volatile", `
declare count_ops integer; step_hash text; recorded text; c integer; completed bigint; expected_hash text;
begin
 select current into c from ` + ns + `tesl_schema_state where id = 1 for update;
 if not found then raise exception 'tesl: expansion state is missing'; end if;
 select operation_count,artefact_hash into count_ops,step_hash from ` + ns + `tesl_schema_expansions where version = v;
 if not found or n is null or n < 0 or n >= count_ops or art is null or art !~ '^[0-9a-f]{64}$' then
   raise exception 'tesl: expansion object has no matching intent';
 end if;
 expected_hash := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('tesl-migration-object-v1','UTF8') ||
   pg_catalog.decode(step_hash,'hex') || pg_catalog.int4send(n)),'hex');
 if art is distinct from expected_hash then raise exception 'tesl: expansion object identity does not match its intent'; end if;
 select operation_hash into recorded from ` + ns + `tesl_schema_expansion_objects where version = v and ordinal = n;
 if found then
   if recorded is distinct from art then raise exception 'tesl: immutable expansion object differs'; end if;
   return;
 end if;
 if c >= v then raise exception 'tesl: cannot append objects to completed history'; end if;
 select pg_catalog.count(*) into completed from ` + ns + `tesl_schema_expansion_objects where version = v;
 if n <> completed then raise exception 'tesl: expansion objects must be recorded in order'; end if;
 insert into ` + ns + `tesl_schema_expansion_objects(version,ordinal,operation_hash) values (v,n,art);
end`},
		{"tesl_record_expanded", "v integer", "void", "volatile", `
declare s ` + ns + `tesl_schema_state%rowtype; r ` + ns + `tesl_schema_expansions%rowtype; completed bigint;
begin
 select * into s from ` + ns + `tesl_schema_state where id = 1 for update;
 if not found then raise exception 'tesl: expansion state is missing'; end if;
 select * into r from ` + ns + `tesl_schema_expansions where version = v;
 if not found then raise exception 'tesl: expansion intent is missing'; end if;
 if exists (select 1 from ` + ns + `tesl_schema_versions where version = v and step = 'expanded') then return; end if;
 if (s.current = 0 and s.installing_version is distinct from v) or (s.current <> 0 and v <> s.current + 1) then
   raise exception 'tesl: expansion must follow the recorded installation target and history';
 end if;
 select pg_catalog.count(*) into completed from ` + ns + `tesl_schema_expansion_objects where version = v;
 if completed <> r.operation_count then raise exception 'tesl: expansion objects are incomplete'; end if;
 insert into ` + ns + `tesl_schema_versions(version,step,snapshot_hash,artefact_hash,source_abi,stored_value_compatibility,protocol_level,fence_domain,epoch_preserving,executed_by)
   values (v,'expanded',r.snapshot_hash,r.artefact_hash,r.source_abi,r.stored_value_compatibility,1,'tesl-1',true,pg_catalog.current_setting('application_name'));
 if s.current = 0 then
   insert into ` + ns + `tesl_schema_versions(version,step,artefact_hash,source_abi,stored_value_compatibility,protocol_level,fence_domain,executed_by)
   values (v,'contracting',r.artefact_hash,r.source_abi,r.stored_value_compatibility,1,'tesl-1',pg_catalog.current_setting('application_name')),
          (v,'contracted',r.artefact_hash,r.source_abi,r.stored_value_compatibility,1,'tesl-1',pg_catalog.current_setting('application_name'));
 end if;
 update ` + ns + `tesl_schema_state set current = v, installing_version = null,
   min_version = case when s.current = 0 then v else min_version end,
   compat_floor = case when s.current = 0 then v else compat_floor end where id = 1;
end`},
		{"tesl_heartbeat", "v integer, proto integer, seen_floor integer", "void", "volatile", `
declare instance_id text := pg_catalog.current_setting('application_name',true); admitted_floor integer;
begin
 admitted_floor := ` + ns + `tesl_admit(v);
 if instance_id is null or instance_id !~ '^tesl-(app|exec):' or proto is distinct from 1 or
   seen_floor is null or seen_floor < 0 or seen_floor > admitted_floor then
   raise exception 'tesl: invalid registered instance heartbeat';
 end if;
 insert into ` + ns + `tesl_schema_instances(instance,version,protocol_level,last_seen,compat_floor_seen)
 values (instance_id,v,proto,pg_catalog.clock_timestamp(),seen_floor)
 on conflict (instance) do update set version=excluded.version, protocol_level=excluded.protocol_level,
   last_seen=excluded.last_seen, compat_floor_seen=greatest(tesl_schema_instances.compat_floor_seen,excluded.compat_floor_seen);
 update ` + ns + `tesl_schema_meta set max_observed_protocol=greatest(max_observed_protocol,proto) where id=1;
end`},
	}
}
