package teslrt

func pgRowQueueRemovalTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{{"tesl_schema_queue_removal_protocol", `
 id smallint primary key check(id=1), format integer not null check(format=1)`},
		{"tesl_row_queue_removal_staging", `
 version integer primary key check(version between 2 and 2147483646), queue text not null,
 source jsonb not null, retirement bytea not null,
 retirement_hash text not null check(retirement_hash ~ '^[0-9a-f]{64}$'),
 check(pg_catalog.encode(pg_catalog.sha256(retirement),'hex')=retirement_hash)`},
		{"tesl_row_queue_removal_restamps", `
 job_id text not null, from_version integer not null check(from_version>=1),
 to_version integer not null check(to_version>from_version and to_version<=2147483646),
 queue text not null, job_type text not null,
 contract_hash text not null check(contract_hash ~ '^[0-9a-f]{64}$'),
 payload_hash text not null check(payload_hash ~ '^[0-9a-f]{64}$'),
 retirement_hash text not null check(retirement_hash ~ '^[0-9a-f]{64}$'),
 claim_seq bigint not null check(claim_seq>=0), primary key(job_id,from_version)`}}
}

func pgRowQueueRemovalFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_row_queue_removal_inventory", "contracts jsonb", "bytea", "immutable", `
declare q jsonb; p jsonb; result bytea; payloads bytea;
begin
 result:=pg_catalog.convert_to('l'||pg_catalog.jsonb_array_length(contracts)::text||':','UTF8');
 for q in select * from pg_catalog.jsonb_array_elements(contracts) loop
  payloads:=pg_catalog.convert_to('l'||pg_catalog.jsonb_array_length(q->'payloads')::text||':','UTF8');
  for p in select * from pg_catalog.jsonb_array_elements(q->'payloads') loop
   payloads:=payloads||pg_catalog.convert_to('l2:','UTF8')
    ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(p->>'job','UTF8'))
    ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(p->>'contract','UTF8'));
  end loop;
  result:=result||pg_catalog.convert_to('l2:','UTF8')||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(q->>'queue','UTF8'))||payloads;
 end loop;
 return result;
end`},
		{"tesl_row_queue_removal_source_valid", "v integer", "boolean", "stable", `
declare r ` + ns + `tesl_row_queue_removal_staging%rowtype;
 t ` + ns + `tesl_row_queue_target_staging%rowtype; prior ` + ns + `tesl_row_physical%rowtype;
 old_header jsonb; new_header jsonb; expected bytea; receipt bytea; expected_binding bytea; survivors jsonb;
 envelope bytea[]; target_fields bytea[]; prior_fields bytea[];
 old_hash text; new_hash text; family text; n text; k integer;
 prefix record; prefix_entry jsonb; prefix_bytes bytea; prefix_hash text; preceding_hash text:='';
begin
 if v is null or v<2 or v>2147483646 then return false; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_queue_removal_protocol where id=1 and format=1) then return false; end if;
 if exists(select 1 from ` + ns + `tesl_row_queue_removal_staging where version<>v) then return false; end if;
 select * into r from ` + ns + `tesl_row_queue_removal_staging where version=v;
 if not found then return false; end if;
 if pg_catalog.jsonb_typeof(r.source) is distinct from 'object' then return false; end if;
 if (select count(*) from pg_catalog.jsonb_object_keys(r.source))<>10 or
  not (r.source ?& array['old','new','oldSchema','oldStorage','oldHash','newSchema','newStorage','newHash','seal','prefix']) then return false; end if;
 if pg_catalog.jsonb_typeof(r.source->'prefix') is distinct from 'array' then return false; end if;
 if pg_catalog.jsonb_array_length(r.source->'prefix')<>v-1 then return false; end if;
 select * into t from ` + ns + `tesl_row_queue_target_staging where version=v;
 if not found or not exists(select 1 from ` + ns + `tesl_schema_meta where id=1 and format_version=5 and initial_version=1 and database_uuid=t.database_uuid and fence_ns=t.fence_ns) then return false; end if;
 select * into prior from ` + ns + `tesl_row_physical where version=v-1;
 if not found or prior.contract_hash<>t.predecessor_hash or prior.stored_value_compatibility<>t.stored_value_compatibility or not prior.epoch_preserving then return false; end if;
 old_header:=` + ns + `tesl_row_physical_source_header(prior.contract);
 new_header:=` + ns + `tesl_row_physical_source_header(t.contract);
 family:=old_header->>'family';
 if new_header->>'format'<>'tesl-retained-physical-version-v9' or new_header->>'version'<>v::text or old_header->>'version'<>(v-1)::text
  or new_header->>'family'<>family or new_header->>'namespace'<>old_header->>'namespace'
  or old_header->>'schema' is distinct from r.source->>'oldSchema' or old_header->>'storage' is distinct from r.source->>'oldStorage'
  or new_header->>'schema' is distinct from r.source->>'newSchema' or new_header->>'storage' is distinct from r.source->>'newStorage'
  or r.source->>'seal' is distinct from 'complete' then return false; end if;
 old_hash:=` + ns + `tesl_queue_inventory_hash(family,v-1,r.source->>'oldStorage',r.source->>'oldSchema',t.stored_value_compatibility,r.source->'old');
 new_hash:=` + ns + `tesl_queue_inventory_hash(family,v,r.source->>'newStorage',r.source->>'newSchema',t.stored_value_compatibility,r.source->'new');
 if old_hash is distinct from r.source->>'oldHash' or new_hash is distinct from r.source->>'newHash'
  or not exists(select 1 from ` + ns + `tesl_queue_versions q join ` + ns + `tesl_row_queue_sources s on s.version=q.version
   where q.version=v-1 and q.inventory_hash=old_hash and s.inventory_hash=old_hash
    and q.schema_snapshot_hash=old_header->>'schema' and q.storage_snapshot_hash=old_header->>'storage'
    and s.expansion_hash=case when v=2 then (select catalog_hash from ` + ns + `tesl_row_versions where version=1) else prior.contract_hash end)
  or ` + ns + `tesl_queue_inventory_json(v-1) is distinct from r.source->'old' then return false; end if;
 -- Every older producer's inventory belongs to the checked additive prefix.
 -- Pin actual descriptors and source bindings to the compiler-owned full prefix,
 -- rather than trusting an epoch_preserving flag or a later Go observation.
 prefix_bytes:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s9:migrationl2:','UTF8')
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to('tesl-row-queue-removal-prefix-v1','UTF8'))
  ||pg_catalog.convert_to('l'||(v-1)::text||':','UTF8');
 for k in 1..v-1 loop
  prefix_entry:=r.source->'prefix'->(k-1);
  if pg_catalog.jsonb_typeof(prefix_entry)<>'array' then return false; end if;
  if pg_catalog.jsonb_array_length(prefix_entry)<>3 or prefix_entry->>0<>k::text
   or pg_catalog.jsonb_typeof(prefix_entry->0)<>'string' or pg_catalog.jsonb_typeof(prefix_entry->1)<>'string'
   or pg_catalog.jsonb_typeof(prefix_entry->2)<>'string' then return false; end if;
  select p.*,q.schema_snapshot_hash as source_schema,q.storage_snapshot_hash as source_storage,q.inventory_hash,
   source.source_binding,source.source_binding_hash,source.expansion_hash into prefix
   from ` + ns + `tesl_row_physical p join ` + ns + `tesl_queue_versions q on q.version=p.version
   join ` + ns + `tesl_row_queue_sources source on source.version=q.version and source.inventory_hash=q.inventory_hash
   join ` + ns + `tesl_schema_versions e on e.version=p.version and e.step='expanded'
   where p.version=k and p.epoch_preserving and p.stored_value_compatibility=t.stored_value_compatibility
    and p.contract_hash=prefix_entry->>1 and q.inventory_hash=prefix_entry->>2
    and p.predecessor_hash=preceding_hash
    and (` + ns + `tesl_row_physical_source_header(p.contract))->>'format'='tesl-retained-physical-version-v1'
    and (k=1 or (e.artefact_hash=p.contract_hash and e.source_abi=p.compiler_abi));
  if not found then return false; end if;
  if prefix.expansion_hash is distinct from (case when k=1 then (select catalog_hash from ` + ns + `tesl_row_versions where version=1) else prefix.contract_hash end)
   or not ` + ns + `tesl_queue_inventory_preserves(` + ns + `tesl_queue_inventory_json(k),r.source->'old') then return false; end if;
  expected_binding:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s9:migrationl7:s24:tesl-row-queue-source-v1','UTF8')
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(family,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(k::text,'UTF8'))
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(prefix.source_schema,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(prefix.source_storage,'UTF8'))
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(t.stored_value_compatibility,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(prefix.inventory_hash,'UTF8'));
  if prefix.source_binding<>expected_binding or prefix.source_binding_hash<>pg_catalog.encode(pg_catalog.sha256(expected_binding),'hex') then return false; end if;
  prefix_bytes:=prefix_bytes||pg_catalog.convert_to('l3:','UTF8')||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(k::text,'UTF8'))
   ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(prefix.contract_hash,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(prefix.inventory_hash,'UTF8'));
  preceding_hash:=prefix.contract_hash;
 end loop;
 prefix_hash:=pg_catalog.encode(pg_catalog.sha256(prefix_bytes),'hex');
 expected_binding:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s9:migrationl7:s24:tesl-row-queue-source-v1','UTF8')
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(family,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to((v-1)::text,'UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(r.source->>'oldSchema','UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(r.source->>'oldStorage','UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(t.stored_value_compatibility,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(old_hash,'UTF8'));
 if not exists(select 1 from ` + ns + `tesl_row_queue_sources s where s.version=v-1 and s.source_binding=expected_binding
  and s.source_binding_hash=pg_catalog.encode(pg_catalog.sha256(expected_binding),'hex')) then return false; end if;
 if (select count(*) from pg_catalog.jsonb_array_elements(r.source->'old') q where q->>'queue'=r.queue)<>1 then return false; end if;
 select coalesce(pg_catalog.jsonb_agg(q order by q->>'queue' collate "C"),'[]'::jsonb) into survivors
  from pg_catalog.jsonb_array_elements(r.source->'old') q where q->>'queue'<>r.queue;
 if survivors is distinct from r.source->'new' then return false; end if;
 -- Parse the whole framed tree. A matching byte suffix inside another node is
 -- not a direct removal decision, and unchanged entities must be exact bytes.
 envelope:=` + ns + `tesl_stage_canonical_children(t.contract);
 if pg_catalog.cardinality(envelope)<>4 or envelope[1]<>pg_catalog.convert_to('s24:tesl-migration-canonical','UTF8')
  or envelope[2]<>pg_catalog.convert_to('s1:1','UTF8') or envelope[3]<>pg_catalog.convert_to('s9:migration','UTF8') then return false; end if;
 target_fields:=` + ns + `tesl_stage_canonical_children(envelope[4]);
 envelope:=` + ns + `tesl_stage_canonical_children(prior.contract);
 if pg_catalog.cardinality(envelope)<>4 then return false; end if;
 prior_fields:=` + ns + `tesl_stage_canonical_children(envelope[4]);
 if pg_catalog.cardinality(target_fields)<>9 or pg_catalog.cardinality(prior_fields)<>8
  or target_fields[1]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to('tesl-retained-physical-version-v9','UTF8'))
  or target_fields[4]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(v::text,'UTF8')) or prior_fields[4]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to((v-1)::text,'UTF8'))
  or target_fields[7]<>prior_fields[7] or target_fields[8]<>pg_catalog.convert_to('l0:','UTF8')
  or prior_fields[8]<>pg_catalog.convert_to('l0:','UTF8') then return false; end if;
 -- Bind the complete direct decision, not just its header or inventory hashes.
 expected:=pg_catalog.convert_to('l6:','UTF8')||` + ns + `tesl_queue_bytes(pg_catalog.convert_to('remove-empty-v1','UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(r.queue,'UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(r.source->>'oldSchema','UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(r.source->>'oldStorage','UTF8'))
  ||` + ns + `tesl_row_queue_removal_inventory(r.source->'old')||` + ns + `tesl_row_queue_removal_inventory(r.source->'new');
 if target_fields[9]<>expected then return false; end if;
 receipt:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s9:migrationl11:','UTF8');
 foreach n in array array['tesl-row-queue-removal-v2',t.database_uuid::text,t.fence_ns::text,v::text,r.queue,t.predecessor_hash,t.contract_hash,old_hash,new_hash,prefix_hash,t.compiler_abi] loop
  receipt:=receipt||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(n,'UTF8'));
 end loop;
 return r.retirement=receipt and pg_catalog.encode(pg_catalog.sha256(receipt),'hex')=r.retirement_hash;
end`},
		{"tesl_remove_empty_queue", "uuid text, fence integer, digest text, abi text, v integer", "boolean", "volatile", `
declare s ` + ns + `tesl_schema_state%rowtype; r ` + ns + `tesl_row_queue_removal_staging%rowtype;
 t ` + ns + `tesl_row_queue_target_staging%rowtype; binding bytea; binding_hash text; family text; n integer; old_version integer;
begin
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then raise exception 'tesl: queue removal requires read committed'; end if;
 if uuid is null or fence is null or digest is null or abi is null or abi !~ '^tesl-source-abi-v1:[0-9a-f]{64}$'
  or ` + ns + `tesl_row_queue_removal_source_valid(v) is distinct from true then raise exception 'tesl: queue removal lacks exact reviewed source'; end if;
 select * into t from ` + ns + `tesl_row_queue_target_staging where version=v;
 select * into r from ` + ns + `tesl_row_queue_removal_staging where version=v;
 if t.database_uuid::text<>uuid or t.fence_ns<>fence or t.contract_hash<>digest then raise exception 'tesl: queue removal installation or target differs'; end if;
 select * into s from ` + ns + `tesl_schema_state where id=1 for update;
 if not found or s.current<v-1 then raise exception 'tesl: queue removal requires its installed adjacent predecessor or completed replay'; end if;
 -- Replay is observation, even from a later binary after an additive suffix.
 -- Never lower later floors or normalize later admitted claims.
 if s.current>=v then
  if s.min_version<v or s.compat_floor<v
   or not exists(select 1 from ` + ns + `tesl_row_queue_retirements c where c.version=v and c.retirement=r.retirement and c.retirement_hash=r.retirement_hash and c.compiler_abi=t.compiler_abi)
   or not exists(select 1 from ` + ns + `tesl_row_physical p where p.version=v and p.contract=t.contract and p.contract_hash=t.contract_hash and p.predecessor_hash=t.predecessor_hash and p.compiler_abi=t.compiler_abi)
   or ` + ns + `tesl_queue_inventory_json(v) is distinct from r.source->'new'
   or not ` + ns + `tesl_row_queue_final(v) or exists(select 1 from ` + ns + `tesl_jobs where queue=r.queue) then
   raise exception 'tesl: immutable queue removal replay differs'; end if;
  return true;
 end if;
 if s.min_version<1 or s.min_version>v-1 or s.compat_floor<>s.min_version or s.installing_version is not null then raise exception 'tesl: queue removal requires its complete additive predecessor'; end if;
 -- Check EVERY admitted older version in both domains, not just v-1.
 for old_version in s.min_version..v-1 loop
  foreach n in array array[fence,-fence] loop
   if not exists(select 1 from pg_catalog.pg_locks where locktype='advisory' and pid=pg_catalog.pg_backend_pid() and granted
    and classid=(case when n<0 then 4294967296::bigint+n else n::bigint end)::oid and objid=old_version::oid and objsubid=2 and mode='ExclusiveLock') then
    raise exception 'tesl: queue removal lacks both exclusive fences for every admitted older version'; end if;
  end loop;
 end loop;
 if t.compiler_abi<>abi then raise exception 'tesl: unfinished queue removal is pinned to its staged compiler ABI'; end if;
 if exists(select 1 from ` + ns + `tesl_schema_index where version<v and state<>'valid') then
  raise exception 'tesl: queue removal requires completed retained index jobs'; end if;
 perform j.id from ` + ns + `tesl_jobs j order by j.seq for update;
 -- ANY retained removed-queue row blocks, including expired claims, quarantine,
 -- dead letters and delayed jobs. There is no implicit discard operation.
 if exists(select 1 from ` + ns + `tesl_jobs where queue=r.queue) then return false; end if;
 if exists(select 1 from ` + ns + `tesl_row_queue_conversion_attempts)
  or exists(select 1 from ` + ns + `tesl_row_queue_conversion_staging where from_version<v) then return false; end if;
 -- Preserve unchanged survivors using the existing audited restamp protocol.
 -- Live claims and quarantines require their ordinary resolution before retry.
 if exists(select 1 from ` + ns + `tesl_jobs j where j.schema_version<s.min_version or j.schema_version>=v or j.status='quarantined'
  or (j.status in ('processing','dead_processing') and j.lease_until>pg_catalog.clock_timestamp())
  or (j.status in ('processing','dead_processing') and (j.claimed_by_version<s.min_version or j.claimed_by_version>=v))
  or not exists(select 1 from ` + ns + `tesl_queue_payloads p join ` + ns + `tesl_queue_payloads target
   on target.version=v-1 and target.queue=p.queue and target.job_type=p.job_type and target.contract=p.contract and target.contract_hash=p.contract_hash
   where p.version=j.schema_version and p.queue=j.queue and p.job_type=j.job_type)) then return false; end if;
 insert into ` + ns + `tesl_row_queue_retirements values(v,r.retirement,r.retirement_hash,t.compiler_abi);
 perform ` + ns + `tesl_register_row_physical(v,t.predecessor_hash,t.contract,t.contract_hash,t.compiler_abi,t.stored_value_compatibility,0,false);
 family:=(` + ns + `tesl_row_physical_source_header(t.contract))->>'family';
 binding:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s9:migrationl7:s24:tesl-row-queue-source-v1','UTF8')
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(family,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(v::text,'UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(r.source->>'newSchema','UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(r.source->>'newStorage','UTF8'))
  ||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(t.stored_value_compatibility,'UTF8'))||` + ns + `tesl_queue_bytes(pg_catalog.convert_to(r.source->>'newHash','UTF8'));
 binding_hash:=pg_catalog.encode(pg_catalog.sha256(binding),'hex');
 perform ` + ns + `tesl_register_row_queue_source(family,v,r.source->>'newStorage',r.source->>'newSchema',t.compiler_abi,t.stored_value_compatibility,r.source->>'seal',r.source->>'newHash',r.source->'new',binding,binding_hash,t.contract_hash);
 perform ` + ns + `tesl_begin_expansion(v,t.contract_hash,t.contract_hash,t.compiler_abi,t.stored_value_compatibility,0,false);
 insert into ` + ns + `tesl_row_queue_removal_restamps(job_id,from_version,to_version,queue,job_type,contract_hash,payload_hash,retirement_hash,claim_seq)
 select j.id,j.schema_version,v,j.queue,j.job_type,p.contract_hash,pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(j.payload::text,'UTF8')),'hex'),r.retirement_hash,j.claim_seq
 from ` + ns + `tesl_jobs j join ` + ns + `tesl_queue_payloads p on p.version=j.schema_version and p.queue=j.queue and p.job_type=j.job_type where j.schema_version<v;
 update ` + ns + `tesl_jobs set schema_version=v,
  status=case when status='processing' then 'pending' when status='dead_processing' then 'dead' else status end,
  locked_at=null,locked_by=null,claim_token=null,claimed_by_version=null,claim_xid=null,lease_until=null where schema_version<v;
 if not ` + ns + `tesl_row_queue_final(v) then raise exception 'tesl: queue removal lost finality'; end if;
 perform ` + ns + `tesl_record_expanded(v);
 insert into ` + ns + `tesl_schema_versions(version,step,artefact_hash,source_abi,stored_value_compatibility,protocol_level,fence_domain,executed_by)
 select v,step,r.retirement_hash,t.compiler_abi,t.stored_value_compatibility,1,'tesl-1',pg_catalog.current_setting('application_name') from unnest(array['retired','contracting','contracted']) step;
 update ` + ns + `tesl_schema_state set min_version=v,compat_floor=v where id=1;
 return true;
end`},
	}
}
