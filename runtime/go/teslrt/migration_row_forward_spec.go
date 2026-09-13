package teslrt

// These fixed definitions ship in the original V1 reader. A later executable
// appends bounded manifests; it cannot alter this protected schema or SQL.
func pgRowForwardTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{
		{"tesl_row_physical", `
 version integer primary key check(version between 1 and 2147483646),
 predecessor_hash text not null,
 contract bytea not null,
 contract_hash text not null check(contract_hash ~ '^[0-9a-f]{64}$'),
 compiler_abi text not null check(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'),
 stored_value_compatibility text not null check(stored_value_compatibility ~ '^tesl-stored-value-v1:[0-9a-f]{64}$'),
 operation_count integer not null check(operation_count>=0),
 epoch_preserving boolean not null,
 check((version=1 and predecessor_hash='' and operation_count=0) or (version>1 and predecessor_hash ~ '^[0-9a-f]{64}$' and operation_count>=0)),
 check(pg_catalog.encode(pg_catalog.sha256(contract),'hex')=contract_hash)`},
		{"tesl_row_epochs", `
 through_version integer primary key check(through_version between 2 and 2147483646),
 old_min integer not null check(old_min>=1 and old_min<through_version),
 retirement bytea not null,
 retirement_hash text not null check(retirement_hash ~ '^[0-9a-f]{64}$'),
 compiler_abi text not null check(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'),
 forced boolean not null,
 check(pg_catalog.encode(pg_catalog.sha256(retirement),'hex')=retirement_hash)`},
		{"tesl_row_processing", `
 version integer primary key check(version between 2 and 2147483646),
 compiler_abi text not null check(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$')`},
	}
}

func pgRowForwardFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_register_row_physical", "v integer, prior text, doc bytea, digest text, creator text, compatibility text, ops integer, preserving boolean", "void", "volatile", `
declare s ` + ns + `tesl_schema_state%rowtype; p ` + ns + `tesl_row_physical%rowtype; r ` + ns + `tesl_row_physical%rowtype;
begin
 if v is null or v<2 or v>2147483646 or prior is null or prior !~ '^[0-9a-f]{64}$' or doc is null or digest is null or
 digest !~ '^[0-9a-f]{64}$' or pg_catalog.encode(pg_catalog.sha256(doc),'hex') is distinct from digest or
 creator is null or creator !~ '^tesl-source-abi-v1:[0-9a-f]{64}$' or compatibility is null or
 compatibility !~ '^tesl-stored-value-v1:[0-9a-f]{64}$' or ops is null or ops<0 or preserving is null then
 raise exception 'tesl: invalid bounded row manifest'; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_meta where id=1 and format_version=5 and initial_version=1) then
 raise exception 'tesl: row manifest requires format5 fresh origin'; end if;
 select * into s from ` + ns + `tesl_schema_state where id=1 for update;
 if not found or s.current not in (v-1,v) or s.min_version>v-1 or s.compat_floor>v-1 then
 raise exception 'tesl: row manifest predecessor is not final baseline'; end if;
 select * into p from ` + ns + `tesl_row_physical where version=v-1;
 if not found or p.stored_value_compatibility is distinct from compatibility or
 not ((p.epoch_preserving and p.contract_hash=prior and exists(select 1 from ` + ns + `tesl_schema_versions where version=v-1 and step='expanded')) or exists(select 1 from ` + ns + `tesl_row_contracts c join ` + ns + `tesl_schema_versions prior_version on prior_version.version=c.version and prior_version.step='contracted' and prior_version.artefact_hash=c.contract_hash where c.version=v-1 and c.settled_hash=prior)) then
 raise exception 'tesl: row manifest predecessor identity differs'; end if;
 if not preserving and s.min_version<v-1 then raise exception 'tesl: close additive epoch first: app --schema close-epoch --through V%',v-1; end if;
 if s.current=v and not exists(select 1 from ` + ns + `tesl_row_physical where version=v) then
 raise exception 'tesl: cannot append manifest to published history'; end if;
 insert into ` + ns + `tesl_row_physical values(v,prior,doc,digest,creator,compatibility,ops,preserving) on conflict(version) do nothing;
 select * into r from ` + ns + `tesl_row_physical where version=v;
 if r.predecessor_hash is distinct from prior or r.contract is distinct from doc or r.contract_hash is distinct from digest or
 r.compiler_abi is distinct from creator or r.stored_value_compatibility is distinct from compatibility or r.operation_count is distinct from ops or r.epoch_preserving is distinct from preserving then
 raise exception 'tesl: immutable row manifest differs'; end if;
end`},
		{"tesl_row_record_birth", "v integer, n integer, ent text, object_hash text", "void", "volatile", `
declare p ` + ns + `tesl_row_physical%rowtype; r ` + ns + `tesl_row_finality%rowtype;
begin
 if v is null or v<2 or n is null or n<0 or ent is null or ent='' or object_hash is null or object_hash !~ '^[0-9a-f]{64}$' then
 raise exception 'tesl: invalid row birth identity'; end if;
 select * into p from ` + ns + `tesl_row_physical where version=v;
 if not found or n>=p.operation_count or
 not exists(select 1 from ` + ns + `tesl_schema_state where id=1 and current=v) or
 not exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='expanded' and artefact_hash=p.contract_hash and source_abi=p.compiler_abi) or
 not exists(select 1 from ` + ns + `tesl_schema_expansion_objects where version=v and ordinal=n and operation_hash=object_hash) then
 raise exception 'tesl: row birth lacks exact published expansion object'; end if;
 insert into ` + ns + `tesl_row_finality(entity,generation,version,physical_hash,retirement_hash,compiler_abi)
 values(ent,1,v,p.contract_hash,object_hash,p.compiler_abi) on conflict(entity,generation) do nothing;
 select * into r from ` + ns + `tesl_row_finality where entity=ent and generation=1;
 if r.version is distinct from v or r.physical_hash is distinct from p.contract_hash or r.retirement_hash is distinct from object_hash or r.compiler_abi is distinct from p.compiler_abi then
 raise exception 'tesl: immutable row birth differs'; end if;
end`},
		{"tesl_row_processing", "v integer, abi text, physical_hash text", "void", "volatile", `
declare recorded text; fence integer;
begin
 perform ` + ns + `tesl_admit(v);
 if v is null or v<2 or v>2147483646 or abi is null or abi !~ '^tesl-source-abi-v1:[0-9a-f]{64}$' or physical_hash is null or
 not exists(select 1 from ` + ns + `tesl_row_physical where version=v and contract_hash=physical_hash and not epoch_preserving) then
 raise exception 'tesl: processing requires exact installed row manifest'; end if;
 if exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='retired') then return; end if;
 select compiler_abi into recorded from ` + ns + `tesl_row_processing where version=v;
 if found then
 if recorded is distinct from abi then raise exception 'tesl: transforming generation compiler ABI is pinned'; end if;
 return; end if;
 select fence_ns into fence from ` + ns + `tesl_schema_meta where id=1;
 perform pg_catalog.pg_advisory_xact_lock(fence,-v);
 if exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='retired') then return; end if;
 insert into ` + ns + `tesl_row_processing(version,compiler_abi) values(v,abi) on conflict(version) do nothing;
 select compiler_abi into recorded from ` + ns + `tesl_row_processing where version=v for update;
 if recorded is distinct from abi then raise exception 'tesl: transforming generation compiler ABI is pinned'; end if;
end`},
		{"tesl_row_check_abi", "v integer, abi text, physical_hash text", "void", "volatile", `
declare recorded text; fence integer;
begin
 if v is null or v<2 or v>2147483646 or abi is null or abi !~ '^tesl-source-abi-v1:[0-9a-f]{64}$' or physical_hash is null or
 not exists(select 1 from ` + ns + `tesl_row_physical where version=v and contract_hash=physical_hash and not epoch_preserving) then
 raise exception 'tesl: row read requires exact installed physical manifest'; end if;
 if exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='retired') then return; end if;
 perform ` + ns + `tesl_admit(v);
 select compiler_abi into recorded from ` + ns + `tesl_row_processing where version=v;
 if found then
 if recorded is distinct from abi then raise exception 'tesl: transforming generation compiler ABI is pinned'; end if;
 return; end if;
 select fence_ns into fence from ` + ns + `tesl_schema_meta where id=1;
 perform pg_catalog.pg_advisory_xact_lock(fence,-v);
 if exists(select 1 from ` + ns + `tesl_schema_versions where version=v and step='retired') then return; end if;
 select compiler_abi into recorded from ` + ns + `tesl_row_processing where version=v;
 if found and recorded is distinct from abi then raise exception 'tesl: transforming generation compiler ABI is pinned'; end if;
end`},
	}
}
