package teslrt

import "strings"

func pgRowControlTables() []pgMigrationControlTable {
	return append([]pgMigrationControlTable{
		{"tesl_row_baseline", `
 id smallint primary key check(id=1),
 initial_version integer not null check(initial_version=1),
 established_by text not null check(established_by='fresh-install'),
 inventory_authority text not null check(inventory_authority='complete'),
 inventory bytea not null,
 inventory_hash text not null check(inventory_hash ~ '^[0-9a-f]{64}$'),
 queue_authority text not null check(queue_authority='complete'),
 queue_count integer not null check(queue_count=0),
 facility_authority text not null check(facility_authority='complete'),
 facility_count integer not null check(facility_count=0),
 check(pg_catalog.encode(pg_catalog.sha256(inventory),'hex')=inventory_hash)`},
		{"tesl_row_versions", `
 version integer primary key check(version between 1 and 2147483646),
 family text not null,
 schema_snapshot bytea not null,
 schema_snapshot_hash text not null check(schema_snapshot_hash ~ '^[0-9a-f]{64}$'),
 storage_snapshot bytea not null,
 storage_snapshot_hash text not null check(storage_snapshot_hash ~ '^[0-9a-f]{64}$'),
 inventory_hash text not null check(inventory_hash ~ '^[0-9a-f]{64}$'),
 catalog_hash text not null check(catalog_hash ~ '^[0-9a-f]{64}$'),
 entity_count integer not null check(entity_count>=0),
 queue_count integer not null check(queue_count=0),
 facility_count integer not null check(facility_count=0),
 compiler_abi text not null check(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'),
 stored_value_compatibility text not null check(stored_value_compatibility ~ '^tesl-stored-value-v1:[0-9a-f]{64}$'),
 check(pg_catalog.encode(pg_catalog.sha256(schema_snapshot),'hex')=schema_snapshot_hash),
 check(pg_catalog.encode(pg_catalog.sha256(storage_snapshot),'hex')=storage_snapshot_hash)`},
		{"tesl_row_entities", `
 version integer not null check(version between 1 and 2147483646),
 entity text not null,
 table_name text not null,
 generation smallint not null check(generation between 1 and 32767),
 insert_generation smallint not null check(insert_generation between 1 and generation),
 type_contract bytea not null,
 type_contract_hash text not null check(type_contract_hash ~ '^[0-9a-f]{64}$'),
 physical_storage bytea not null,
 physical_storage_hash text not null check(physical_storage_hash ~ '^[0-9a-f]{64}$'),
 ordinal integer not null check(ordinal>=0),
 operation_hash text not null check(operation_hash ~ '^[0-9a-f]{64}$'),
 primary key(version,entity),unique(version,table_name),unique(version,ordinal),
 check(pg_catalog.encode(pg_catalog.sha256(type_contract),'hex')=type_contract_hash),
 check(pg_catalog.encode(pg_catalog.sha256(physical_storage),'hex')=physical_storage_hash)`},
	}, append(pgRowForwardTables(), pgRowLifecycleTables()...)...)
}

// The original V1 binary knows this bounded V2 manifest protocol. Queue/index
// jobs and later transforming windows remain refused. Legacy formats are unchanged.
func pgRowControlFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	functions := pgMigrationControlFunctionsV2(namespace)
	for i, fn := range functions {
		guard := ` if v is null or v<1 or v>2147483646 or not exists(select 1 from ` + ns + `tesl_schema_meta where id=1 and format_version=5 and initial_version=1) then
 raise exception 'tesl: unsupported bounded format5 row version'; end if;
 if v>1 and not exists(select 1 from ` + ns + `tesl_row_physical where version=v) then
 raise exception 'tesl: row V2 has no protected physical manifest'; end if;
 if not exists(select 1 from ` + ns + `tesl_row_baseline b join ` + ns + `tesl_row_versions baseline_version on baseline_version.version=b.initial_version and baseline_version.inventory_hash=b.inventory_hash
 where b.id=1 and b.initial_version=1 and b.established_by='fresh-install' and b.inventory_authority='complete'
 and b.queue_authority='complete' and b.queue_count=0 and b.facility_authority='complete' and b.facility_count=0
 and baseline_version.queue_count=0 and baseline_version.facility_count=0 and baseline_version.entity_count=(select count(*) from ` + ns + `tesl_row_entities where version=1)) then
 raise exception 'tesl: row baseline inventory is incomplete'; end if;
`
		switch fn.name {
		case "tesl_begin_expansion":
			guard += ` if v=1 and not exists(select 1 from ` + ns + `tesl_row_versions baseline_version where baseline_version.version=v and baseline_version.catalog_hash=snap and baseline_version.inventory_hash=art and baseline_version.entity_count=ops and baseline_version.stored_value_compatibility=compatibility) then
 raise exception 'tesl: expansion does not match exact row baseline'; end if;
 if v>1 and (ep is distinct from false or not exists(select 1 from ` + ns + `tesl_row_physical where version=v and contract_hash=snap and contract_hash=art and compiler_abi=abi and stored_value_compatibility=compatibility and operation_count=ops)) then
 raise exception 'tesl: expansion does not match exact bounded row manifest'; end if;
`
		case "tesl_record_expansion_object":
			guard += ` if v=1 and not exists(select 1 from ` + ns + `tesl_row_entities where version=v and ordinal=n and operation_hash=art) then
 raise exception 'tesl: object does not match exact row baseline'; end if;
`
		case "tesl_record_expanded":
			guard += ` if exists(select 1 from ` + ns + `tesl_row_entities e where e.version=v and not exists(select 1 from ` + ns + `tesl_schema_expansion_objects o where o.version=e.version and o.ordinal=e.ordinal and o.operation_hash=e.operation_hash)) then
 raise exception 'tesl: row baseline objects are incomplete'; end if;
`
		}
		body := fn.body
		if fn.name == "tesl_begin_expansion" {
			body = strings.Replace(body, "ep is distinct from true", "((v=1 and ep is distinct from true) or (v>1 and ep is distinct from false))", 1)
		}
		if fn.name == "tesl_record_expanded" {
			body = strings.Replace(body, "1,'tesl-1',true,pg_catalog.current_setting", "1,'tesl-1',r.epoch_preserving,pg_catalog.current_setting", 1)
		}
		if fn.name == "tesl_record_expanded" {
			body = strings.TrimSuffix(body, "\nend") + `
 if v=1 then
 insert into ` + ns + `tesl_row_finality(entity,generation,version,physical_hash,retirement_hash,compiler_abi)
 select e.entity,1,1,coalesce(p.contract_hash,r.artefact_hash),r.artefact_hash,r.source_abi
 from ` + ns + `tesl_row_entities e left join ` + ns + `tesl_row_physical p on p.version=1 where e.version=1;
 end if;
end`
		}
		functions[i].body = strings.Replace(body, "\nbegin\n", "\nbegin\n"+guard, 1)
	}
	return append(append(append(functions, pgRowForwardFunctions(namespace)...), pgRowBackfillFunctions(namespace)...), pgRowContractFunctions(namespace)...)
}
