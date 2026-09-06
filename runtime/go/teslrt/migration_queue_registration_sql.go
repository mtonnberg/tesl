package teslrt

import "strings"

// Unpublished format 4 only. Production format 3 retains its exact function
// catalog. These helpers accept data, never stored/source SQL or role names.
func pgQueueCandidateControlFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	functions := pgMigrationControlFunctions(namespace)
	for i := range functions {
		if functions[i].name == "tesl_record_expanded" {
			guard := `begin
 if not exists(select 1 from ` + ns + `tesl_queue_baseline b join ` + ns + `tesl_queue_versions q
   on q.version=b.initial_version and q.inventory_hash=b.inventory_hash
   join ` + ns + `tesl_schema_meta m on m.id=1 and m.initial_version=b.initial_version
   where b.id=1 and b.inventory_authority='complete' and b.established_by='fresh-install' and m.format_version=4) then
   raise exception 'tesl: candidate expansion requires a complete queue baseline; unknown upgrades require a future adoption protocol';
 end if;
 perform ` + ns + `tesl_queue_inventory_json(v);
 if not exists(select 1 from ` + ns + `tesl_queue_versions q join ` + ns + `tesl_schema_expansions e
   on e.version=q.version and e.snapshot_hash=q.storage_snapshot_hash and e.source_abi=q.compiler_abi
   and e.stored_value_compatibility=q.stored_value_compatibility where q.version=v) then
   raise exception 'tesl: expansion has no matching complete queue inventory';
 end if;
`
			if !strings.Contains(functions[i].body, "begin\n") {
				panic("candidate expanded function has no closed body boundary")
			}
			functions[i].body = strings.Replace(functions[i].body, "begin\n", guard, 1)
		}
	}
	functions = append(functions, pgQueueRegistrationFunctions(namespace)...)
	return append(functions, pgQueueOperationFunctions(namespace)...)
}

func pgQueueRegistrationFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_queue_bytes", "value bytea", "bytea", "immutable", `
begin
 if value is null then raise exception 'tesl: null canonical bytes'; end if;
 return pg_catalog.convert_to('s'||pg_catalog.octet_length(value)::text||':','UTF8')||value;
end`},
		{"tesl_queue_contract_valid", "value bytea", "boolean", "immutable", `
declare prefix bytea := pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s8:contractl2:s16:queue-payload-v1','UTF8');
 pos integer:=0; size integer; tag integer; digit integer; count_node bigint; start_pos integer;
 remaining integer[]:=array[1]; depth integer:=1;
begin
 if value is null then return false; end if;
 size:=pg_catalog.octet_length(value);
 if size>67108864 or pg_catalog.substring(value,1,pg_catalog.octet_length(prefix))<>prefix then return false; end if;
 -- Iterative framing validation avoids PostgreSQL call-stack depth limits.
 while depth>0 loop
   if pos>=size then return false; end if;
   remaining[depth]:=remaining[depth]-1;
   tag:=pg_catalog.get_byte(value,pos);pos:=pos+1;
   if tag not in (108,115) then return false; end if;
   start_pos:=pos;count_node:=0;
   while pos<size loop
     digit:=pg_catalog.get_byte(value,pos);
     exit when digit<48 or digit>57;
     count_node:=count_node*10+digit-48;
     if count_node>size then return false; end if;
     pos:=pos+1;
   end loop;
   if pos=start_pos or pos>=size or pg_catalog.get_byte(value,pos)<>58 or
     (pos-start_pos>1 and pg_catalog.get_byte(value,start_pos)=48) then return false; end if;
   pos:=pos+1;
   if tag=115 then
     if count_node>size-pos then return false; end if;
     pos:=pos+count_node::integer;
   elsif count_node>0 then
     depth:=depth+1;if depth>513 then return false; end if;
     remaining[depth]:=count_node::integer;
   end if;
   while depth>0 and remaining[depth]=0 loop depth:=depth-1;end loop;
 end loop;
 return pos=size;
end`},
		{"tesl_queue_inventory_node", "contracts jsonb", "bytea", "immutable", `
declare q jsonb; p jsonb; qid text; jid text; lastq text:=''; lastj text; seen text[]:=array[]::text[];
 qbytes bytea:=''::bytea; pbytes bytea; raw bytea; ctext text; hash text; answer bytea;
begin
 if contracts is null or pg_catalog.jsonb_typeof(contracts)<>'array' or pg_catalog.octet_length(contracts::text)>67108864 then
   raise exception 'tesl: invalid queue inventory array';
 end if;
 for q in select * from pg_catalog.jsonb_array_elements(contracts) loop
   if pg_catalog.jsonb_typeof(q)<>'object' or (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(q))<>2 or not(q ?& array['queue','payloads']) or
      pg_catalog.jsonb_typeof(q->'queue')<>'string' or pg_catalog.jsonb_typeof(q->'payloads')<>'array' then
     raise exception 'tesl: invalid queue inventory contract';
   end if;
   qid:=q->>'queue';
   if qid !~ '^[A-Z][A-Za-z0-9_]*([.][A-Z][A-Za-z0-9_]*)*$' or qid collate "C"<=lastq collate "C" or pg_catalog.jsonb_array_length(q->'payloads')=0 then
     raise exception 'tesl: unsorted, duplicate or empty queue contract';
   end if;
   lastq:=qid;lastj:='';pbytes:=''::bytea;
   for p in select * from pg_catalog.jsonb_array_elements(q->'payloads') loop
     if pg_catalog.jsonb_typeof(p)<>'object' or (select pg_catalog.count(*) from pg_catalog.jsonb_object_keys(p))<>3 or not(p ?& array['job','contract','contractHash']) or
       pg_catalog.jsonb_typeof(p->'job')<>'string' or pg_catalog.jsonb_typeof(p->'contract')<>'string' or pg_catalog.jsonb_typeof(p->'contractHash')<>'string' then
       raise exception 'tesl: invalid queue inventory payload';
     end if;
     jid:=p->>'job';ctext:=p->>'contract';hash:=p->>'contractHash';
     if jid !~ '^[A-Z][A-Za-z0-9_]*([.][A-Z][A-Za-z0-9_]*)*$' or jid collate "C"<=lastj collate "C" or jid=any(seen) or
        ctext !~ '^([0-9a-f][0-9a-f])+$' or hash !~ '^[0-9a-f]{64}$' then
       raise exception 'tesl: invalid, unsorted or duplicate queue payload identity';
     end if;
     lastj:=jid;seen:=pg_catalog.array_append(seen,jid);raw:=pg_catalog.decode(ctext,'hex');
     if not ` + ns + `tesl_queue_contract_valid(raw) or pg_catalog.encode(pg_catalog.sha256(raw),'hex')<>hash then
       raise exception 'tesl: queue payload canonical bytes or digest differ';
     end if;
     pbytes:=pbytes||pg_catalog.convert_to('l4:','UTF8')||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(jid,'UTF8'))||
       ` + ns + `tesl_queue_bytes(pg_catalog.convert_to('tesl-queue-payload-v1','UTF8'))||` + ns + `tesl_queue_bytes(raw)||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(hash,'UTF8'));
   end loop;
   qbytes:=qbytes||pg_catalog.convert_to('l2:','UTF8')||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(qid,'UTF8'))||
     pg_catalog.convert_to('l'||pg_catalog.jsonb_array_length(q->'payloads')::text||':','UTF8')||pbytes;
 end loop;
 answer:=pg_catalog.convert_to('l'||pg_catalog.jsonb_array_length(contracts)::text||':','UTF8')||qbytes;
 return answer;
end`},
		{"tesl_queue_inventory_hash", "family text, v integer, storage_snapshot text, schema_snapshot text, compatibility text, contracts jsonb", "text", "immutable", `
declare body bytea;
begin
 if family is null or family='' or v is null or v<1 or v>2147483646 or storage_snapshot is null or storage_snapshot !~ '^[0-9a-f]{64}$' or
   schema_snapshot is null or schema_snapshot !~ '^[0-9a-f]{64}$' or compatibility is null or compatibility !~ '^tesl-stored-value-v1:[0-9a-f]{64}$' then
   raise exception 'tesl: invalid queue semantic inventory binding';
 end if;
 body:=pg_catalog.convert_to('l7:','UTF8')||` + ns + `tesl_queue_bytes(pg_catalog.convert_to('tesl-queue-inventory-v1','UTF8'))||
   ` + ns + `tesl_queue_bytes(pg_catalog.convert_to(family,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(v::text,'UTF8'))||
   ` + ns + `tesl_queue_bytes(pg_catalog.convert_to(storage_snapshot,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(schema_snapshot,'UTF8'))||
   ` + ns + `tesl_queue_bytes(pg_catalog.convert_to(compatibility,'UTF8'))||` + ns + `tesl_queue_inventory_node(contracts);
 return pg_catalog.encode(pg_catalog.sha256(body),'hex');
end`},
		{"tesl_queue_inventory_preserves", "old_contracts jsonb, new_contracts jsonb", "boolean", "immutable", `
begin
 return not exists(select 1 from pg_catalog.jsonb_array_elements(old_contracts) oq
   cross join lateral pg_catalog.jsonb_array_elements(oq->'payloads') op
   where not exists(select 1 from pg_catalog.jsonb_array_elements(new_contracts) nq
     cross join lateral pg_catalog.jsonb_array_elements(nq->'payloads') np
     where nq->>'queue'=oq->>'queue' and np=op));
end`},
		{"tesl_queue_inventory_json", "v integer", "jsonb", "stable", `
declare answer jsonb; r ` + ns + `tesl_queue_versions%rowtype; cc bigint; pc bigint; declared_pc bigint;
begin
 select * into r from ` + ns + `tesl_queue_versions where version=v;
 if not found then raise exception 'tesl: complete queue inventory is missing at V%',v; end if;
 select pg_catalog.count(*),coalesce(pg_catalog.sum(payload_count),0) into cc,declared_pc from ` + ns + `tesl_queue_contracts where version=v;
 select pg_catalog.count(*) into pc from ` + ns + `tesl_queue_payloads where version=v;
 if cc<>r.contract_count or pc<>r.payload_count or pc<>declared_pc or exists
   (select 1 from ` + ns + `tesl_queue_contracts q where q.version=v and q.payload_count<>(select pg_catalog.count(*) from ` + ns + `tesl_queue_payloads p where p.version=q.version and p.queue=q.queue)) then
   raise exception 'tesl: complete queue inventory counts differ at V%',v;
 end if;
 select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('queue',q.queue,'payloads',
   (select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('job',p.job_type,'contract',pg_catalog.encode(p.contract,'hex'),'contractHash',p.contract_hash) order by p.job_type collate "C"),'[]'::jsonb)
    from ` + ns + `tesl_queue_payloads p where p.version=q.version and p.queue=q.queue)) order by q.queue collate "C"),'[]'::jsonb)
 into answer from ` + ns + `tesl_queue_contracts q where q.version=v;
 perform ` + ns + `tesl_queue_inventory_node(answer);
 return answer;
end`},
		{"tesl_queue_verify_inventory", "family text", "void", "stable", `
declare origin integer; current_v integer; expected integer; limit_v integer; original_hash text; original_compat text;
 r ` + ns + `tesl_queue_versions%rowtype; e ` + ns + `tesl_schema_expansions%rowtype;
 contracts jsonb; previous jsonb:='[]'::jsonb;
begin
 select m.initial_version,s.current into origin,current_v from ` + ns + `tesl_schema_meta m cross join ` + ns + `tesl_schema_state s where m.id=1 and s.id=1 and m.format_version=4;
 if not found then raise exception 'tesl: exact candidate queue format is missing'; end if;
 select inventory_hash into original_hash from ` + ns + `tesl_queue_baseline where id=1 and initial_version=origin and inventory_authority='complete' and established_by='fresh-install';
 if not found then raise exception 'tesl: unknown candidate baseline cannot authorize source registration or expansion'; end if;
 expected:=origin;limit_v:=case when current_v=0 then origin else current_v+1 end;
 for r in select * from ` + ns + `tesl_queue_versions order by version loop
   if r.version<>expected or r.version>limit_v then raise exception 'tesl: queue inventory versions are not a contiguous installed prefix';end if;
   contracts:=` + ns + `tesl_queue_inventory_json(r.version);
   if ` + ns + `tesl_queue_inventory_hash(family,r.version,r.storage_snapshot_hash,r.schema_snapshot_hash,r.stored_value_compatibility,contracts)<>r.inventory_hash then
     raise exception 'tesl: queue inventory family, source or canonical digest differs at V%',r.version;
   end if;
   if r.version=origin then
     if r.inventory_hash<>original_hash then raise exception 'tesl: complete queue origin digest differs';end if;
     original_compat:=r.stored_value_compatibility;
   elsif not ` + ns + `tesl_queue_inventory_preserves(previous,contracts) then
     raise exception 'tesl: registered queue payload was removed, moved or changed';
   end if;
   if r.stored_value_compatibility<>original_compat then raise exception 'tesl: registered queue compatibility changed';end if;
   select * into e from ` + ns + `tesl_schema_expansions where version=r.version;
   if found then
     if e.snapshot_hash<>r.storage_snapshot_hash or e.source_abi<>r.compiler_abi or e.stored_value_compatibility<>r.stored_value_compatibility then
       raise exception 'tesl: registered queue creator or snapshot differs from expansion intent';end if;
   elsif r.version<>origin or current_v<>0 then raise exception 'tesl: registered queue has no expansion intent';end if;
   if r.version<=current_v and not exists(select 1 from ` + ns + `tesl_schema_versions s where s.version=r.version and s.step='expanded' and s.snapshot_hash=r.storage_snapshot_hash and s.source_abi=r.compiler_abi and s.stored_value_compatibility=r.stored_value_compatibility) then
     raise exception 'tesl: registered queue has no completed expansion';end if;
   previous:=contracts;expected:=expected+1;
 end loop;
 if expected<=greatest(origin,current_v) then raise exception 'tesl: installed queue inventory is incomplete';end if;
end`},
		{"tesl_register_queue_inventory", "family text, v integer, storage_snapshot text, schema_snapshot text, creator_abi text, compatibility text, source_seal text, inventory_hash text, contracts jsonb", "void", "volatile", `
declare s ` + ns + `tesl_schema_state%rowtype; e ` + ns + `tesl_schema_expansions%rowtype; old ` + ns + `tesl_queue_versions%rowtype;
 q jsonb;p jsonb; count_payload integer:=0; origin integer; actual_hash text;
begin
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then raise exception 'tesl: queue inventory registration requires read committed';end if;
 if creator_abi is null or creator_abi !~ '^tesl-source-abi-v1:[0-9a-f]{64}$' or source_seal is null or source_seal not in ('complete','unknown','unrecorded') or inventory_hash is null or inventory_hash !~ '^[0-9a-f]{64}$' then
   raise exception 'tesl: invalid queue source registration provenance';end if;
 actual_hash:=` + ns + `tesl_queue_inventory_hash(family,v,storage_snapshot,schema_snapshot,compatibility,contracts);
 if actual_hash<>inventory_hash then raise exception 'tesl: supplied queue semantic inventory digest differs';end if;
 -- Serialize registration with expansion publication; no partially inserted set
 -- can be observed as a complete version by another transaction.
 select * into s from ` + ns + `tesl_schema_state where id=1 for update;
 if not found then raise exception 'tesl: queue source registration has no control state';end if;
 perform ` + ns + `tesl_queue_verify_inventory(family);
 select initial_version into origin from ` + ns + `tesl_schema_meta where id=1;
 select * into old from ` + ns + `tesl_queue_versions where version=v;
 if found then
   if old.inventory_hash<>inventory_hash or old.storage_snapshot_hash<>storage_snapshot or old.schema_snapshot_hash<>schema_snapshot or old.stored_value_compatibility<>compatibility or ` + ns + `tesl_queue_inventory_json(v)<>contracts then
     raise exception 'tesl: immutable queue source registration differs';end if;
   if v>s.current and old.compiler_abi<>creator_abi then raise exception 'tesl: pending queue source registration is pinned to its original compiler';end if;
   return; -- Preserve original creator ABI and source-seal provenance.
 end if;
 if s.current<origin or v<>s.current+1 then raise exception 'tesl: queue source registration must follow completed inventory';end if;
 select * into e from ` + ns + `tesl_schema_expansions where version=v;
 if not found or e.snapshot_hash<>storage_snapshot or e.source_abi<>creator_abi or e.stored_value_compatibility<>compatibility then
   raise exception 'tesl: queue source registration has no matching pending expansion intent';end if;
 if not ` + ns + `tesl_queue_inventory_preserves(` + ns + `tesl_queue_inventory_json(v-1),contracts) then
   raise exception 'tesl: existing queue payloads require a migration and cannot be removed, moved or changed';end if;
 for q in select * from pg_catalog.jsonb_array_elements(contracts) loop count_payload:=count_payload+pg_catalog.jsonb_array_length(q->'payloads');end loop;
 insert into ` + ns + `tesl_queue_versions(version,storage_snapshot_hash,schema_snapshot_hash,inventory_hash,source_seal_inventory,compiler_abi,stored_value_compatibility,contract_count,payload_count)
 values(v,storage_snapshot,schema_snapshot,inventory_hash,source_seal,creator_abi,compatibility,pg_catalog.jsonb_array_length(contracts),count_payload);
 for q in select * from pg_catalog.jsonb_array_elements(contracts) loop
   insert into ` + ns + `tesl_queue_contracts(version,queue,payload_count) values(v,q->>'queue',pg_catalog.jsonb_array_length(q->'payloads'));
   for p in select * from pg_catalog.jsonb_array_elements(q->'payloads') loop
     insert into ` + ns + `tesl_queue_payloads(version,queue,job_type,contract_format,contract,contract_hash)
     values(v,q->>'queue',p->>'job','tesl-queue-payload-v1',pg_catalog.decode(p->>'contract','hex'),p->>'contractHash');
   end loop;
 end loop;
 perform ` + ns + `tesl_queue_verify_inventory(family);
end`},
	}
}
