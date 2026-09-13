package teslrt

import "encoding/hex"

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
 width:=pg_catalog.get_byte(doc,pos+1)-48;
 if width not in (8,9) or pg_catalog.get_byte(doc,pos+2)<>58 then raise exception 'tesl: unsupported physical source document width'; end if;
 pos:=pos+3;
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
    (width=9 and fields[1] not in ('tesl-retained-physical-version-v3','tesl-retained-physical-version-v4')) or
    fields[2]!~'^(Schema\.[A-Z][A-Za-z0-9_]*|[A-Z][A-Za-z0-9_]*Schema)$' or
    pg_catalog.octet_length(fields[3])<1 or pg_catalog.octet_length(fields[3])>63 or
    fields[4]!~'^[1-9][0-9]{0,9}$' or fields[5]!~'^[0-9a-f]{64}$' or fields[6]!~'^[0-9a-f]{64}$' then raise exception 'tesl: invalid physical source header fields'; end if;
 if fields[4]::bigint>2147483646 or pos>=size or pg_catalog.get_byte(doc,pos)<>108 then raise exception 'tesl: invalid physical source version or entity framing'; end if;
 return pg_catalog.jsonb_build_object('family',fields[2],'namespace',fields[3],'version',fields[4],'schema',fields[5],'storage',fields[6]);
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
 select * into old from ` + ns + `tesl_queue_versions where version=v;
 if found then
  if old.inventory_hash<>inventory_hash or old.storage_snapshot_hash<>storage_snapshot or old.schema_snapshot_hash<>schema_snapshot or old.stored_value_compatibility<>compatibility or ` + ns + `tesl_queue_inventory_json(v)<>contracts
   or not exists(select 1 from ` + ns + `tesl_row_queue_sources r where r.version=v and r.source_binding=binding and r.source_binding_hash=binding_hash and r.inventory_hash=tesl_register_row_queue_source.inventory_hash and r.expansion_hash=tesl_register_row_queue_source.expansion_hash) then raise exception 'tesl: immutable row queue inventory differs'; end if;
  if v>s.current and old.compiler_abi<>creator_abi then raise exception 'tesl: pending row queue inventory is pinned to creator ABI'; end if;
  return;
 end if;
 if v<>s.current+1 or v<2 or physical.compiler_abi<>creator_abi then raise exception 'tesl: row queue registration must follow the complete installed prefix'; end if;
 if (select count(*) from ` + ns + `tesl_queue_versions)<>v-1 or (select count(*) from ` + ns + `tesl_row_queue_sources)<>v-1 then raise exception 'tesl: row queue prefix inventory is incomplete'; end if;
 if not ` + ns + `tesl_queue_inventory_preserves(` + ns + `tesl_queue_inventory_json(v-1),contracts) then raise exception 'tesl: existing queue payload requires a migration'; end if;
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
end`}}
}
