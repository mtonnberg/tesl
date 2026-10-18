package teslrt

import (
	"encoding/hex"
	"strings"
)

func pgRowQueueFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{{"tesl_row_physical_source_header", "doc bytea", "jsonb", "immutable", `
declare prefix bytea:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s9:migration','UTF8');
 pos integer; size integer; width integer; i integer; count_bytes integer; digit integer; start_pos integer; fields text[]:=array[]::text[];
begin
 -- Only the fixed framed header is projected here. The independently verified
 -- physical parser still owns the complete descriptor, lineage and catalog.
 if doc is null then raise exception 'tesl: missing physical source header'; end if;
 size:=pg_catalog.octet_length(doc);pos:=pg_catalog.octet_length(prefix);
 if size>67108864 or size<pos+3 or pg_catalog.substring(doc,1,pos)<>prefix or pg_catalog.get_byte(doc,pos)<>108 then raise exception 'tesl: invalid physical source document prefix'; end if;
 -- Materialize a possibly TOAST-compressed stored descriptor once. Otherwise
 -- each byte accessor below may repeatedly decompress the entire large plan.
 doc:=doc||''::bytea;
 if size>=pos+4 and pg_catalog.substring(doc,pos+1,4)=pg_catalog.convert_to('l10:','UTF8') then
  width:=10;pos:=pos+4;
 else
  width:=pg_catalog.get_byte(doc,pos+1)-48;
  if width not in (8,9) or pg_catalog.get_byte(doc,pos+2)<>58 then raise exception 'tesl: unsupported physical source document width'; end if;
  pos:=pos+3;
 end if;
 for i in 1..6 loop
  if pos>=size or pg_catalog.get_byte(doc,pos)<>115 then raise exception 'tesl: physical source header atom required'; end if;
  pos:=pos+1;start_pos:=pos;count_bytes:=0;
  while pos<size loop
   digit:=pg_catalog.get_byte(doc,pos);exit when digit=58;
   if digit<48 or digit>57 or pos-start_pos>=8 or (pos>start_pos and pg_catalog.get_byte(doc,start_pos)=48) then raise exception 'tesl: noncanonical physical source atom length'; end if;
   count_bytes:=count_bytes*10+digit-48;pos:=pos+1;
  end loop;
  if pos=start_pos or pos>=size or count_bytes>size-pos-1 then raise exception 'tesl: truncated physical source header atom'; end if;
  pos:=pos+1;
  fields:=pg_catalog.array_append(fields,pg_catalog.convert_from(pg_catalog.substring(doc,pos+1,count_bytes),'UTF8'));
  pos:=pos+count_bytes;
 end loop;
 if (width=8 and fields[1] not in ('tesl-retained-physical-version-v1','tesl-retained-physical-version-v2')) or
     (width=9 and fields[1] not in ('tesl-retained-physical-version-v3','tesl-retained-physical-version-v4','tesl-retained-physical-version-v6','tesl-retained-physical-version-v8','tesl-retained-physical-version-v9')) or
     (width=10 and fields[1] not in ('tesl-retained-physical-version-v5','tesl-retained-physical-version-v7','tesl-retained-physical-version-v10','tesl-retained-physical-version-v11','tesl-retained-physical-version-v12')) or
    fields[2]!~'^(Schema\.[A-Z][A-Za-z0-9_]*|[A-Z][A-Za-z0-9_]*Schema)$' or
    pg_catalog.octet_length(fields[3])<1 or pg_catalog.octet_length(fields[3])>63 or
    fields[4]!~'^[1-9][0-9]{0,9}$' or fields[5]!~'^[0-9a-f]{64}$' or fields[6]!~'^[0-9a-f]{64}$' then raise exception 'tesl: invalid physical source header fields'; end if;
 if fields[4]::bigint>2147483646 or pos>=size or pg_catalog.get_byte(doc,pos)<>108 then raise exception 'tesl: invalid physical source version or entity framing'; end if;
 return pg_catalog.jsonb_build_object('format',fields[1],'family',fields[2],'namespace',fields[3],'version',fields[4],'schema',fields[5],'storage',fields[6]);
end`},
		{"tesl_register_row_queue_source", "family text, v integer, storage_snapshot text, schema_snapshot text, creator_abi text, compatibility text, source_seal text, inventory_hash text, contracts jsonb, binding bytea, binding_hash text, expansion_hash text", "void", "volatile", `
declare s ` + ns + `tesl_schema_state%rowtype; old ` + ns + `tesl_queue_versions%rowtype;
 physical ` + ns + `tesl_row_physical%rowtype; q jsonb; p jsonb; payloads integer:=0; expected bytea; source_header jsonb;
begin
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then raise exception 'tesl: row queue registration requires read committed'; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_meta where id=1 and format_version=5 and initial_version=1) then raise exception 'tesl: row queue registration requires original format5'; end if;
 if not exists(select 1 from ` + ns + `tesl_row_versions r where r.version=1 and r.family=tesl_register_row_queue_source.family and r.stored_value_compatibility=compatibility) then raise exception 'tesl: row queue source family or compatibility differs from original baseline'; end if;
 if creator_abi is null or creator_abi !~ '^tesl-source-abi-v1:[0-9a-f]{64}$' or source_seal is null or source_seal not in ('complete','unknown','unrecorded') then raise exception 'tesl: invalid row queue provenance'; end if;
 if inventory_hash is null or ` + ns + `tesl_queue_inventory_hash(family,v,storage_snapshot,schema_snapshot,compatibility,contracts)<>inventory_hash then raise exception 'tesl: row queue semantic inventory differs'; end if;
 expected:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s9:migrationl7:s24:tesl-row-queue-source-v1','UTF8')
 ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(family,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(v::text,'UTF8'))
 ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(schema_snapshot,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(storage_snapshot,'UTF8'))
 ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(compatibility,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(inventory_hash,'UTF8'));
 if binding is null or binding<>expected or binding_hash is null or pg_catalog.encode(pg_catalog.sha256(binding),'hex')<>binding_hash then raise exception 'tesl: row queue canonical source binding differs'; end if;
 select * into s from ` + ns + `tesl_schema_state where id=1 for update;
 if not found then raise exception 'tesl: missing row queue control state'; end if;
 select * into physical from ` + ns + `tesl_row_physical where version=v;
 if not found or expansion_hash is null or physical.contract_hash<>expansion_hash or physical.stored_value_compatibility<>compatibility then raise exception 'tesl: row queue inventory lacks exact physical expansion binding'; end if;
 source_header:=` + ns + `tesl_row_physical_source_header(physical.contract);
  if source_header->>'family'<>family or source_header->>'namespace'<>pg_catalog.convert_from(pg_catalog.decode('` + hex.EncodeToString([]byte(namespace)) + `','hex'),'UTF8') or source_header->>'version'<>v::text or source_header->>'schema'<>schema_snapshot or source_header->>'storage'<>storage_snapshot then raise exception 'tesl: row queue source hashes differ from the stored physical header'; end if;
 if source_header->>'format'='tesl-retained-physical-version-v9' then
  if not ` + ns + `tesl_row_queue_removal_source_valid(v) or not exists(
   select 1 from ` + ns + `tesl_row_queue_removal_staging d
   join ` + ns + `tesl_row_queue_target_staging t on t.version=d.version and t.contract=physical.contract and t.contract_hash=physical.contract_hash
   join ` + ns + `tesl_row_queue_retirements receipt on receipt.version=d.version and receipt.retirement=d.retirement and receipt.retirement_hash=d.retirement_hash
   where d.version=v and d.source->'new'=contracts and d.source->>'newHash'=inventory_hash
    and t.compiler_abi=creator_abi and t.stored_value_compatibility=compatibility) then
   raise exception 'tesl: removal source registration requires exact staged source and atomic receipt'; end if;
 end if;
 select * into old from ` + ns + `tesl_queue_versions where version=v;
 if found then
  if old.inventory_hash<>inventory_hash or old.storage_snapshot_hash<>storage_snapshot or old.schema_snapshot_hash<>schema_snapshot or old.stored_value_compatibility<>compatibility or ` + ns + `tesl_queue_inventory_json(v)<>contracts
   or not exists(select 1 from ` + ns + `tesl_row_queue_sources r where r.version=v and r.source_binding=binding and r.source_binding_hash=binding_hash and r.inventory_hash=tesl_register_row_queue_source.inventory_hash and r.expansion_hash=tesl_register_row_queue_source.expansion_hash) then raise exception 'tesl: immutable row queue inventory differs'; end if;
  if v>s.current and old.compiler_abi<>creator_abi then raise exception 'tesl: pending row queue inventory is pinned to creator ABI'; end if;
  return;
 end if;
 if v<>s.current+1 or v<2 or physical.compiler_abi<>creator_abi then raise exception 'tesl: row queue registration must follow the complete installed prefix'; end if;
 if (select count(*) from ` + ns + `tesl_queue_versions)<>v-1 or (select count(*) from ` + ns + `tesl_row_queue_sources)<>v-1 then raise exception 'tesl: row queue prefix inventory is incomplete'; end if;
  if not ` + ns + `tesl_row_queue_transition_valid(` + ns + `tesl_queue_inventory_json(v-1),contracts,v) then raise exception 'tesl: existing queue payload requires exact staged migration authority'; end if;
 for q in select * from pg_catalog.jsonb_array_elements(contracts) loop payloads:=payloads+pg_catalog.jsonb_array_length(q->'payloads'); end loop;
 insert into ` + ns + `tesl_queue_versions(version,storage_snapshot_hash,schema_snapshot_hash,inventory_hash,source_seal_inventory,compiler_abi,stored_value_compatibility,contract_count,payload_count)
 values(v,storage_snapshot,schema_snapshot,inventory_hash,source_seal,creator_abi,compatibility,pg_catalog.jsonb_array_length(contracts),payloads);
 for q in select * from pg_catalog.jsonb_array_elements(contracts) loop
  insert into ` + ns + `tesl_queue_contracts(version,queue,payload_count) values(v,q->>'queue',pg_catalog.jsonb_array_length(q->'payloads'));
  for p in select * from pg_catalog.jsonb_array_elements(q->'payloads') loop
   insert into ` + ns + `tesl_queue_payloads(version,queue,job_type,contract_format,contract,contract_hash) values(v,q->>'queue',p->>'job','tesl-queue-payload-v1',pg_catalog.decode(p->>'contract','hex'),p->>'contractHash');
  end loop;
 end loop;
 insert into ` + ns + `tesl_row_queue_sources values(v,binding,binding_hash,inventory_hash,expansion_hash);
end`},
		{"tesl_row_queue_transition_valid", "old_contracts jsonb, new_contracts jsonb, v integer", "boolean", "stable", `
begin
 if exists(select 1 from ` + ns + `tesl_row_queue_removal_staging where version<v) then
  if not ` + ns + `tesl_queue_inventory_preserves(old_contracts,new_contracts) then return false; end if;
  if exists(select 1 from ` + ns + `tesl_row_queue_removal_staging d
   cross join lateral pg_catalog.jsonb_array_elements(new_contracts) q
   where d.version<v and (q->>'queue'=d.queue or exists(
    select 1 from pg_catalog.jsonb_array_elements(d.source->'old') old_queue
    cross join lateral pg_catalog.jsonb_array_elements(old_queue->'payloads') old_job
    cross join lateral pg_catalog.jsonb_array_elements(q->'payloads') new_job
    where old_queue->>'queue'=d.queue and old_job->>'job'=new_job->>'job'))) then return false; end if;
 end if;
 if exists(select 1 from ` + ns + `tesl_row_queue_removal_staging where version=v) then
  return ` + ns + `tesl_row_queue_removal_source_valid(v) and exists(select 1 from ` + ns + `tesl_row_queue_removal_staging d
   join ` + ns + `tesl_row_queue_target_staging t on t.version=d.version
   join ` + ns + `tesl_row_physical p on p.version=t.version and p.contract=t.contract and p.contract_hash=t.contract_hash
    and p.predecessor_hash=t.predecessor_hash and p.compiler_abi=t.compiler_abi and p.stored_value_compatibility=t.stored_value_compatibility and not p.epoch_preserving and p.operation_count=0
   join ` + ns + `tesl_row_queue_retirements r on r.version=d.version and r.retirement=d.retirement and r.retirement_hash=d.retirement_hash
   where d.version=v and d.source->'old'=old_contracts and d.source->'new'=new_contracts);
 end if;
 if not exists(select 1 from ` + ns + `tesl_row_queue_target_staging where version=v)
  and ` + ns + `tesl_queue_inventory_preserves(old_contracts,new_contracts) then return true; end if;
  if v is null or v<2 or v>2147483646 then return false; end if;
 if not exists(select 1 from ` + ns + `tesl_row_queue_target_staging t
 join ` + ns + `tesl_schema_meta m on m.id=1 and m.database_uuid=t.database_uuid and m.fence_ns=t.fence_ns
 join ` + ns + `tesl_row_physical p on p.version=t.version and p.contract=t.contract and p.contract_hash=t.contract_hash
  and p.compiler_abi=t.compiler_abi and p.stored_value_compatibility=t.stored_value_compatibility
  and p.predecessor_hash=t.predecessor_hash and p.operation_count=0 and not p.epoch_preserving
 where t.version=v) then return false; end if;
 -- First path retains the complete queue/job membership; additions and
 -- removals need their own full source authority, not a changed-payload receipt.
  -- Expand each already-validated inventory once per statement. Repeated nested
  -- JSON-array scans used to multiply complete payload documents per staged job.
  -- This is no admission cache: all exact comparisons run in this snapshot.
  return (with old_payloads as materialized (
    select q->>'queue' as queue,p->>'job' as job,p as payload
    from pg_catalog.jsonb_array_elements(old_contracts) q
    cross join lateral pg_catalog.jsonb_array_elements(q->'payloads') p),
   new_payloads as materialized (
    select q->>'queue' as queue,p->>'job' as job,p as payload
    from pg_catalog.jsonb_array_elements(new_contracts) q
   cross join lateral pg_catalog.jsonb_array_elements(q->'payloads') p),
  pairs as materialized (
   select coalesce(op.queue,np.queue) as queue,coalesce(op.job,np.job) as job,
    op.payload as old_payload,np.payload as new_payload
   from old_payloads op full join new_payloads np on np.queue=op.queue and np.job=op.job),
  roots as materialized (
   select c.* from ` + ns + `tesl_row_queue_conversion_staging c
   join ` + ns + `tesl_schema_meta m on m.id=1 and m.database_uuid=c.database_uuid and m.fence_ns=c.fence_ns
   join ` + ns + `tesl_row_queue_sources source on source.version=c.from_version and source.inventory_hash=c.inventory_hash and source.expansion_hash=c.expansion_hash
   where c.from_version=v-1 and c.to_version=v and c.revision=0)
  select not exists(select 1 from pairs p where p.old_payload is null or p.new_payload is null
   or (p.old_payload<>p.new_payload and not exists(select 1 from roots c where c.queue=p.queue and c.job_type=p.job
    and c.old_contract=pg_catalog.decode(p.old_payload->>'contract','hex') and c.new_contract=pg_catalog.decode(p.new_payload->>'contract','hex'))))
  and not exists(select 1 from ` + ns + `tesl_row_queue_conversion_staging c where c.from_version=v-1 and c.revision=0
   and not exists(select 1 from pairs p where p.queue=c.queue and p.job=c.job_type and p.old_payload<>p.new_payload
    and c.old_contract=pg_catalog.decode(p.old_payload->>'contract','hex') and c.new_contract=pg_catalog.decode(p.new_payload->>'contract','hex'))));
end`}}
}

// Keep the private format4 lifecycle byte-for-byte unchanged. Row5 selects a
// different admission proof; all attempt ownership and lease operations share
// the same implementation after that proof succeeds.
func pgRowQueueOperationFunctions(namespace string) []pgMigrationControlFunction {
	functions := pgQueueOperationFunctions(namespace)
	ns := quoteIdentifier(namespace) + "."
	for i := range functions {
		if functions[i].name == "tesl_queue_complete" {
			functions[i].body = strings.Replace(functions[i].body, " delete from "+ns+"tesl_jobs j", " delete from "+ns+"tesl_row_queue_conversion_attempts a where a.job_id=tesl_queue_complete.job_id;\n delete from "+ns+"tesl_jobs j", 1)
		}
		if functions[i].name == "tesl_queue_enqueue" {
			functions[i].body = strings.Replace(functions[i].body, " insert into "+ns+"tesl_jobs", " if exists(select 1 from "+ns+"tesl_row_queue_removal_restamps r where r.job_id=tesl_queue_enqueue.job_id) then raise exception 'tesl: audited job identity cannot be reused'; end if;\n insert into "+ns+"tesl_jobs", 1)
			functions[i].body = strings.Replace(functions[i].body, " insert into "+ns+"tesl_jobs", " if exists(select 1 from "+ns+"tesl_row_queue_discards d where d.job_id=tesl_queue_enqueue.job_id) then raise exception 'tesl: discarded job identity cannot be reused'; end if;\n insert into "+ns+"tesl_jobs", 1)
			functions[i].body = strings.Replace(functions[i].body, " insert into "+ns+"tesl_jobs", " if exists(select 1 from "+ns+"tesl_row_queue_conversion_receipts r where r.job_id=tesl_queue_enqueue.job_id) or exists(select 1 from "+ns+"tesl_row_queue_conversion_failures r where r.job_id=tesl_queue_enqueue.job_id) or exists(select 1 from "+ns+"tesl_row_queue_restamps r where r.job_id=tesl_queue_enqueue.job_id) then raise exception 'tesl: audited job identity cannot be reused'; end if;\n insert into "+ns+"tesl_jobs", 1)
		}
		if functions[i].name != "tesl_queue_admit" {
			continue
		}
		functions[i].body = `
declare fence integer; floor integer; ` + pgRowQueueVerificationDeclarations(namespace) + `
begin
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then raise exception 'tesl: queue operations require read committed isolation'; end if;
 if v is null or v<1 or v>2147483646 or q is null or q='' then raise exception 'tesl: invalid queue operation identity'; end if;
 select fence_ns into fence from ` + ns + `tesl_schema_meta where id=1 and format_version=5 and initial_version=1;
 if not found then raise exception 'tesl: protected row queue format is not installed'; end if;
 -- Keep the post-wait state read in separate volatile SPI statements.
 perform pg_catalog.pg_advisory_xact_lock_shared(fence,v);
  perform ` + ns + `tesl_row_admit_version(v);
 select min_version into floor from ` + ns + `tesl_schema_state where id=1;
 if not found or floor<1 or floor>v then raise exception 'tesl: invalid queue admission state'; end if;
 if exists(select 1 from ` + ns + `tesl_jobs where schema_version<floor and status<>'quarantined') then
  raise exception 'tesl: non-quarantined queue job is below the admission floor'; end if;
 ` + pgRowQueueVerificationSQL(namespace, "v") + `
 if not exists(select 1 from ` + ns + `tesl_queue_contracts where version=v and queue=q) then raise exception 'tesl: queue contract has no installed inventory'; end if;
 return floor;
end`
	}
	return functions
}

// Source verification grants no admission and takes no request fence. Sharing
// this fragment lets retirement validate under its drained repeatable-read
// snapshot without weakening queue operations' post-wait READ COMMITTED rule.
func pgRowQueueVerificationDeclarations(namespace string) string {
	ns := quoteIdentifier(namespace) + "."
	return `n integer; family text; compatibility text;
 original ` + ns + `tesl_row_versions%rowtype; source ` + ns + `tesl_queue_versions%rowtype;
 binding ` + ns + `tesl_row_queue_sources%rowtype; physical ` + ns + `tesl_row_physical%rowtype;
  contracts jsonb; inventory_node bytea; previous jsonb:='[]'::jsonb; expected bytea; source_header jsonb;
 expected_expansion text; expected_artifact text; expected_abi text;`
}

func pgRowQueueVerificationSQL(namespace, version string) string {
	ns := quoteIdentifier(namespace) + "."
	return `
 select * into original from ` + ns + `tesl_row_versions where version=1;
 if not found then raise exception 'tesl: missing original row queue source'; end if;
 family:=original.family; compatibility:=original.stored_value_compatibility;
 if not exists(select 1 from ` + ns + `tesl_row_baseline b where b.id=1 and b.initial_version=1
 and b.established_by='fresh-install' and b.inventory_authority='complete' and b.inventory_hash=original.inventory_hash
 and b.queue_authority='complete' and b.queue_count=original.queue_count and b.facility_authority='complete'
 and b.facility_count=original.facility_count and original.facility_count=original.queue_count
 and original.queue_count=(select count(*) from ` + ns + `tesl_queue_contracts where version=1)) then
 raise exception 'tesl: incomplete original row queue baseline'; end if;
 if not exists(select 1 from ` + ns + `tesl_queue_baseline b join ` + ns + `tesl_queue_versions baseline_source on baseline_source.version=1 and baseline_source.inventory_hash=b.inventory_hash
 where b.id=1 and b.initial_version=1 and b.inventory_authority='complete' and b.established_by='fresh-install') then
 raise exception 'tesl: queue installation baseline is unknown or incomplete'; end if;
 for n in 1..` + version + ` loop
  select * into source from ` + ns + `tesl_queue_versions where version=n;
  if not found then raise exception 'tesl: row queue source prefix is incomplete'; end if;
  select * into binding from ` + ns + `tesl_row_queue_sources where version=n;
  if not found then raise exception 'tesl: row queue source binding is missing'; end if;
   select checked.contracts,checked.node into contracts,inventory_node from ` + ns + `tesl_queue_inventory_checked(n) checked;
  if source.stored_value_compatibility<>compatibility or source.inventory_hash<>binding.inventory_hash
    or ` + ns + `tesl_queue_inventory_digest(family,n,source.storage_snapshot_hash,source.schema_snapshot_hash,compatibility,inventory_node)<>source.inventory_hash
    or (n>1 and not ` + ns + `tesl_row_queue_transition_valid(previous,contracts,n)) then
   raise exception 'tesl: row queue semantic inventory differs'; end if;
  previous:=contracts;
  expected:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s9:migrationl7:s24:tesl-row-queue-source-v1','UTF8')
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(family,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(n::text,'UTF8'))
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(source.schema_snapshot_hash,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(source.storage_snapshot_hash,'UTF8'))
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(compatibility,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(source.inventory_hash,'UTF8'));
  if binding.source_binding<>expected or binding.source_binding_hash<>pg_catalog.encode(pg_catalog.sha256(expected),'hex') then
   raise exception 'tesl: row queue canonical source binding differs'; end if;
  if n=1 then
   if source.schema_snapshot_hash<>original.schema_snapshot_hash or source.storage_snapshot_hash<>original.storage_snapshot_hash or source.compiler_abi<>original.compiler_abi then
    raise exception 'tesl: row queue original source differs'; end if;
   expected_expansion:=original.catalog_hash; expected_artifact:=original.inventory_hash; expected_abi:=original.compiler_abi;
  else
   select * into physical from ` + ns + `tesl_row_physical where version=n;
   if not found then raise exception 'tesl: row queue physical receipt is missing'; end if;
   source_header:=` + ns + `tesl_row_physical_source_header(physical.contract);
   if source_header->>'family'<>family or source_header->>'namespace'<>pg_catalog.convert_from(pg_catalog.decode('` + hex.EncodeToString([]byte(namespace)) + `','hex'),'UTF8')
    or source_header->>'version'<>n::text or source_header->>'schema'<>source.schema_snapshot_hash or source_header->>'storage'<>source.storage_snapshot_hash
    or physical.stored_value_compatibility<>compatibility or source.compiler_abi<>physical.compiler_abi then
    raise exception 'tesl: row queue physical source differs'; end if;
   expected_expansion:=physical.contract_hash; expected_artifact:=physical.contract_hash; expected_abi:=physical.compiler_abi;
  end if;
   if binding.expansion_hash<>expected_expansion or not exists(select 1 from ` + ns + `tesl_schema_expansions e
    join ` + ns + `tesl_schema_versions expansion_receipt on expansion_receipt.version=e.version and expansion_receipt.step='expanded'
   where e.version=n and e.snapshot_hash=expected_expansion and e.artefact_hash=expected_artifact
    and e.source_abi=expected_abi and e.stored_value_compatibility=compatibility
     and expansion_receipt.snapshot_hash=e.snapshot_hash and expansion_receipt.artefact_hash=e.artefact_hash and expansion_receipt.source_abi=e.source_abi and expansion_receipt.stored_value_compatibility=e.stored_value_compatibility) then
   raise exception 'tesl: row queue has no exact completed expansion receipt'; end if;
 end loop;
 `
}
