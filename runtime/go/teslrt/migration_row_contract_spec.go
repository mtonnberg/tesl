package teslrt

func pgRowContractFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_register_row_contract", "v integer, prior text, doc bytea, digest text, window_hash text, settled_doc bytea, settled_digest text, ops integer, preparations integer, abi text", "void", "volatile", `
declare r ` + ns + `tesl_row_contracts%rowtype; s ` + ns + `tesl_schema_state%rowtype; previous text;
begin
 if v is null or v<2 or doc is null or digest is null or digest !~ '^[0-9a-f]{64}$' or
 pg_catalog.encode(pg_catalog.sha256(doc),'hex') is distinct from digest or settled_doc is null or
 settled_digest is null or settled_digest !~ '^[0-9a-f]{64}$' or pg_catalog.encode(pg_catalog.sha256(settled_doc),'hex') is distinct from settled_digest or
 abi is null or abi !~ '^tesl-source-abi-v1:[0-9a-f]{64}$' or ops is null or ops<0 or preparations is null or preparations<0 or preparations>ops then
 raise exception 'tesl: invalid checked Contract intent'; end if;
 select * into s from ` + ns + `tesl_schema_state where id=1 for update;
 if not found or s.current<v or s.min_version>v then raise exception 'tesl: Contract target is not admitted'; end if;
 if not exists(select 1 from ` + ns + `tesl_row_physical p where p.version=v and p.contract_hash=window_hash) then
 raise exception 'tesl: Contract window differs from installed manifest'; end if;
 select contract_hash into previous from ` + ns + `tesl_row_contracts where version<v order by version desc limit 1;
 if prior is distinct from coalesce(previous,'') then raise exception 'tesl: Contract predecessor differs'; end if;
 insert into ` + ns + `tesl_row_contracts(version,predecessor_hash,contract,contract_hash,window_hash,settled,settled_hash,operation_count,preparation_count,compiler_abi)
 values(v,prior,doc,digest,window_hash,settled_doc,settled_digest,ops,preparations,abi) on conflict(version) do nothing;
 select * into r from ` + ns + `tesl_row_contracts where version=v;
 if r.predecessor_hash is distinct from prior or r.contract is distinct from doc or r.contract_hash is distinct from digest or
 r.window_hash is distinct from window_hash or r.settled is distinct from settled_doc or r.settled_hash is distinct from settled_digest or
 r.operation_count is distinct from ops or r.preparation_count is distinct from preparations then raise exception 'tesl: immutable Contract intent differs'; end if;
end`},
		{"tesl_retire_row_window", "v integer, digest text, retirement text, entities text[], generations smallint[], executor_abi text", "void", "volatile", `
declare s ` + ns + `tesl_schema_state%rowtype; c ` + ns + `tesl_row_contracts%rowtype; compatibility text; fence integer; old integer; i integer;
begin
 select * into s from ` + ns + `tesl_schema_state where id=1 for update;
 select * into c from ` + ns + `tesl_row_contracts where version=v;
 if not found or c.contract_hash is distinct from digest or retirement is null or retirement !~ '^[0-9a-f]{64}$' or
 executor_abi is null or executor_abi !~ '^tesl-source-abi-v1:[0-9a-f]{64}$' or
 entities is null or generations is null or pg_catalog.cardinality(entities)=0 or pg_catalog.cardinality(entities)<>pg_catalog.cardinality(generations) then
 raise exception 'tesl: retirement requires exact Contract and final generation inventory'; end if;
 if exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='retired' and artefact_hash=retirement) then return; end if;
 select fence_ns into fence from ` + ns + `tesl_schema_meta where id=1;
 perform pg_catalog.pg_advisory_xact_lock(fence,-v);
 if exists(select 1 from ` + ns + `tesl_row_processing where version=v and compiler_abi<>executor_abi) then raise exception 'tesl: retirement executor differs from processing ABI'; end if;
 if s.current<>v or s.min_version>=v then raise exception 'tesl: retirement must close current open window'; end if;
 select fence_ns into fence from ` + ns + `tesl_schema_meta where id=1;
 for old in s.min_version..v-1 loop
 if not exists(select 1 from pg_catalog.pg_locks where locktype='advisory' and pid=pg_catalog.pg_backend_pid() and granted
 and classid=fence::oid and objid=old::oid and objsubid=2 and mode='ExclusiveLock') then
 raise exception 'tesl: retirement lacks exclusive retiring writer fence'; end if;
 end loop;
 for i in 1..pg_catalog.cardinality(entities) loop
 if entities[i] is null or generations[i] is null or generations[i]<2 or
 not exists(select 1 from ` + ns + `tesl_row_finality where entity=entities[i] and generation=generations[i]-1) or
 not exists(select 1 from ` + ns + `tesl_schema_backfill_shards where version=v and entity=entities[i] and target_generation=generations[i]) then
 raise exception 'tesl: retirement lacks predecessor finality or exact row work'; end if;
 insert into ` + ns + `tesl_row_finality(entity,generation,version,physical_hash,retirement_hash,compiler_abi)
 values(entities[i],generations[i],v,c.window_hash,retirement,executor_abi);
 update ` + ns + `tesl_schema_backfill_shards set state='final',updated_at=pg_catalog.clock_timestamp() where version=v and entity=entities[i] and target_generation=generations[i];
 end loop;
 select stored_value_compatibility into compatibility from ` + ns + `tesl_row_physical where version=v;
 insert into ` + ns + `tesl_schema_versions(version,step,artefact_hash,source_abi,stored_value_compatibility,protocol_level,fence_domain,executed_by)
 values(v,'retired',retirement,executor_abi,compatibility,1,'tesl-1',pg_catalog.current_setting('application_name'));
 update ` + ns + `tesl_schema_state set min_version=v where id=1;
end`},
		{"tesl_begin_row_contract", "v integer, digest text", "void", "volatile", `
declare s ` + ns + `tesl_schema_state%rowtype; c ` + ns + `tesl_row_contracts%rowtype; fence integer; compatibility text;
begin
 select * into s from ` + ns + `tesl_schema_state where id=1 for update;
 select * into c from ` + ns + `tesl_row_contracts where version=v;
 if not found or c.contract_hash is distinct from digest or s.min_version<v or
 not exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='retired') then
 raise exception 'tesl: Contract requires completed retirement'; end if;
 if exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='contracting' and artefact_hash=digest) then return; end if;
 if (select count(*) from ` + ns + `tesl_row_contract_objects where version=v)<c.preparation_count then raise exception 'tesl: Contract preparation is incomplete'; end if;
 select fence_ns into fence from ` + ns + `tesl_schema_meta where id=1;
 if exists(select 1 from pg_catalog.generate_series(s.compat_floor,v) retiring_version(value)
 where not exists(select 1 from pg_catalog.pg_locks where locktype='advisory' and pid=pg_catalog.pg_backend_pid() and granted
 and classid=(4294967296::bigint-fence)::oid and objid=retiring_version.value::oid and objsubid=2 and mode='ExclusiveLock')) then
 raise exception 'tesl: Contract requires drained compatibility plans'; end if;
 select stored_value_compatibility into compatibility from ` + ns + `tesl_row_physical where version=v;
 insert into ` + ns + `tesl_schema_versions(version,step,artefact_hash,source_abi,stored_value_compatibility,protocol_level,fence_domain,executed_by)
 values(v,'contracting',digest,(select source_abi from ` + ns + `tesl_schema_versions where version=v and step='retired'),compatibility,1,'tesl-1',pg_catalog.current_setting('application_name'));
 update ` + ns + `tesl_schema_state set compat_floor=greatest(compat_floor,v) where id=1;
end`},
		{"tesl_record_row_contract_object", "v integer, n integer, art text", "void", "volatile", `
declare c ` + ns + `tesl_row_contracts%rowtype; completed bigint; expected text; recorded text;
begin
 perform 1 from ` + ns + `tesl_schema_state where id=1 and min_version>=v for update;
 if not found then raise exception 'tesl: Contract object precedes retirement'; end if;
 select * into c from ` + ns + `tesl_row_contracts where version=v;
 if not found or n is null or n<0 or n>=c.operation_count or
 not exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='retired') then
 raise exception 'tesl: Contract object has no matching intent'; end if;
 if n>=c.preparation_count and not exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='contracting' and artefact_hash=c.contract_hash) then raise exception 'tesl: destructive Contract object precedes compatibility floor'; end if;
 expected:=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('tesl-migration-object-v1','UTF8')||pg_catalog.decode(c.contract_hash,'hex')||pg_catalog.int4send(n)),'hex');
 if art is distinct from expected then raise exception 'tesl: Contract operation identity differs'; end if;
 select operation_hash into recorded from ` + ns + `tesl_row_contract_objects where version=v and ordinal=n;
 if found then if recorded is distinct from art then raise exception 'tesl: immutable Contract operation differs'; end if; return; end if;
 if exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='contracted') then raise exception 'tesl: Contract already completed'; end if;
 select count(*) into completed from ` + ns + `tesl_row_contract_objects where version=v;
 if completed<>n then raise exception 'tesl: Contract operations must be recorded in order'; end if;
 insert into ` + ns + `tesl_row_contract_objects(version,ordinal,operation_hash) values(v,n,art);
end`},
		{"tesl_finish_row_contract", "v integer, digest text", "void", "volatile", `
declare c ` + ns + `tesl_row_contracts%rowtype; compatibility text; completed bigint;
begin
 perform 1 from ` + ns + `tesl_schema_state where id=1 and min_version>=v and compat_floor>=v for update;
 if not found then raise exception 'tesl: Contract completion precedes retirement/floor'; end if;
 select * into c from ` + ns + `tesl_row_contracts where version=v;
 if not found or c.contract_hash is distinct from digest then raise exception 'tesl: Contract completion identity differs'; end if;
 if exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='contracted' and artefact_hash=digest) then return; end if;
 select count(*) into completed from ` + ns + `tesl_row_contract_objects where version=v;
 if completed<>c.operation_count then raise exception 'tesl: Contract object inventory is incomplete'; end if;
 select stored_value_compatibility into compatibility from ` + ns + `tesl_row_physical where version=v;
 insert into ` + ns + `tesl_schema_versions(version,step,artefact_hash,source_abi,stored_value_compatibility,protocol_level,fence_domain,executed_by)
 values(v,'contracted',digest,(select source_abi from ` + ns + `tesl_schema_versions where version=v and step='retired'),compatibility,1,'tesl-1',pg_catalog.current_setting('application_name'));
end`},
	}
}
