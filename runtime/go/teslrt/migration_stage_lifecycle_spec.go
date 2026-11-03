package teslrt

func pgStageLifecycleTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{
		{"tesl_schema_stage_contracts", `version integer primary key, contract bytea not null, contract_hash text not null unique,
   window_hash text not null, settled bytea not null, settled_hash text not null, compiler_abi text not null,
   check(version>=3),check(pg_catalog.encode(pg_catalog.sha256(contract),'hex')=contract_hash),
   check(pg_catalog.encode(pg_catalog.sha256(settled),'hex')=settled_hash)`},
		{"tesl_schema_stage_promotions", `stage_id text primary key, version integer not null, ordinal integer not null,
   job_id text not null unique, contract_hash text not null, state text not null check(state in ('promoting','blocked_duplicates','enforced')),
   enforced_index_oid bigint check(enforced_index_oid>0), check((state='enforced')=(enforced_index_oid is not null)),unique(version,ordinal)`},
	}
}

func pgStageLifecycleFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_stage_settled", "v integer", "bytea", "stable", `
declare root bytea[]; body bytea[]; entity bytea; fields bytea[]; indexes bytea[]; ordered bytea[]; entities bytea[]:=array[]::bytea[]; g bytea; guard bytea[]; prep bytea[];
begin
 select ` + ns + `tesl_stage_canonical_children(p.contract) into root from ` + ns + `tesl_row_physical p where version=v;
 if root is null then raise exception 'tesl: missing promotion source'; end if;
 body:=` + ns + `tesl_stage_canonical_children(root[4]);
 if pg_catalog.cardinality(body)<>10 or ` + ns + `tesl_stage_atom(body[1])<>'tesl-retained-physical-version-v10' then raise exception 'tesl: settled promotion requires guarded source'; end if;
 foreach entity in array ` + ns + `tesl_stage_canonical_children(body[7]) loop
  fields:=` + ns + `tesl_stage_canonical_children(entity);
  if pg_catalog.cardinality(fields)<>9 then raise exception 'tesl: unsupported promotion entity'; end if;
  indexes:=` + ns + `tesl_stage_canonical_children(fields[8]);
  foreach g in array ` + ns + `tesl_stage_canonical_children(body[10]) loop
   guard:=` + ns + `tesl_stage_canonical_children(g);prep:=` + ns + `tesl_stage_canonical_children(guard[2]);
   if prep[4]=fields[1] then indexes:=pg_catalog.array_append(indexes,guard[3]); end if;
  end loop;
  select coalesce(pg_catalog.array_agg(item order by ` + ns + `tesl_stage_atom((` + ns + `tesl_stage_canonical_children(item))[1]) collate "C"),array[]::bytea[]) into ordered from pg_catalog.unnest(indexes) item;
  fields[8]:=` + ns + `tesl_stage_list(ordered);entities:=pg_catalog.array_append(entities,` + ns + `tesl_stage_list(fields));
 end loop;
 body:=body[1:8];body[1]:=` + ns + `tesl_queue_bytes(pg_catalog.convert_to('tesl-settled-physical-version-v1','UTF8'));body[7]:=` + ns + `tesl_stage_list(entities);
 root[4]:=` + ns + `tesl_stage_list(body);return ` + ns + `tesl_stage_list(root);
end`},
		{"tesl_stage_reliance_ready", "doc bytea", "void", "stable", `
declare body bytea[]; reliance bytea[]; parent bytea[]; prior integer; g bytea; s jsonb; receipt bigint;
begin
 body:=` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(doc))[4]);
 if pg_catalog.cardinality(body)<>10 or ` + ns + `tesl_stage_atom(body[1])<>'tesl-retained-physical-version-v11' then raise exception 'tesl: guarded successor requires explicit enforced reliance'; end if;
 reliance:=` + ns + `tesl_stage_canonical_children(body[10]);
 if pg_catalog.cardinality(reliance)<>3 or ` + ns + `tesl_stage_atom(reliance[1])<>'staged-unique-reliance-v1' then raise exception 'tesl: invalid enforced reliance descriptor'; end if;
 prior:=(` + ns + `tesl_stage_atom(reliance[2]))::integer;
 if prior>=(` + ns + `tesl_stage_atom(body[4]))::integer then raise exception 'tesl: reliance must follow promotion'; end if;
 select ` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(p.contract))[4]) into parent from ` + ns + `tesl_row_physical p where version=prior;
 if parent is null or pg_catalog.cardinality(parent)<>10 or ` + ns + `tesl_stage_atom(parent[1])<>'tesl-retained-physical-version-v10' or parent[10]<>reliance[3] then raise exception 'tesl: reliance differs from complete protected promotion source'; end if;
 foreach g in array ` + ns + `tesl_stage_canonical_children(reliance[3]) loop
  if pg_catalog.array_position(` + ns + `tesl_stage_canonical_children(body[9]),(` + ns + `tesl_stage_canonical_children(g))[2]) is null then raise exception 'tesl: reliance omitted immutable preparation'; end if;
  s:=` + ns + `tesl_stage_guard_spec(prior,g);
  select enforced_index_oid into receipt from ` + ns + `tesl_schema_stage_promotions where stage_id=s->>'stage' and version=prior and state='enforced';
  if receipt is null or receipt<=0 or receipt<>` + ns + `tesl_stage_target_oid(s->>'stage') then raise exception 'tesl: reliance requires durable enforcement and exact valid target'; end if;
 end loop;
end`},
		{"tesl_prepare_stage_enforcement", "stage_key text", "boolean", "volatile", `
declare p ` + ns + `tesl_schema_stage_promotions%rowtype;
begin
 select * into p from ` + ns + `tesl_schema_stage_promotions where stage_id=stage_key for update;
 if not found or p.state='enforced' then return false; end if;
 return ` + ns + `tesl_stage_target_oid(stage_key)>0 and exists(select 1 from ` + ns + `tesl_schema_index j where j.id=p.job_id and j.state='valid');
end`},
		{"tesl_stage_list", "parts bytea[]", "bytea", "immutable", `
declare result bytea; part bytea;
begin
 if parts is null or pg_catalog.array_position(parts,null) is not null then raise exception 'tesl: invalid canonical list inputs'; end if;
 result:=pg_catalog.convert_to('l'||pg_catalog.cardinality(parts)::text||':','UTF8');
 foreach part in array parts loop
  if pg_catalog.octet_length(result)+pg_catalog.octet_length(part)>67108864 then raise exception 'tesl: canonical list budget exceeded'; end if;
  result:=result||part;
 end loop;
 perform ` + ns + `tesl_stage_canonical_children(result);
 return result;
end`},
		{"tesl_register_stage_contract", "v integer, doc bytea, digest text, settled_doc bytea, settled_digest text, abi text", "void", "volatile", `
declare p ` + ns + `tesl_row_physical%rowtype; existing ` + ns + `tesl_schema_stage_contracts%rowtype;
 envelope bytea[]; c bytea[]; physical bytea[]; g bytea; operations bytea[]:=array[]::bytea[]; spec jsonb;
begin
 select * into p from ` + ns + `tesl_row_physical where version=v for share;
 if not found or v<3 or doc is null or digest is null or settled_doc is null or settled_digest is null or abi is null
  or abi!~'^tesl-source-abi-v1:[0-9a-f]{64}$' or pg_catalog.encode(pg_catalog.sha256(doc),'hex')<>digest
  or pg_catalog.encode(pg_catalog.sha256(settled_doc),'hex')<>settled_digest then raise exception 'tesl: invalid stage Contract identity'; end if;
 physical:=` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(p.contract))[4]);
 if pg_catalog.cardinality(physical)<>10 or ` + ns + `tesl_stage_atom(physical[1])<>'tesl-retained-physical-version-v10' then raise exception 'tesl: Contract requires guarded physical source'; end if;
 envelope:=` + ns + `tesl_stage_canonical_children(doc);
 if pg_catalog.cardinality(envelope)<>4 or envelope[1]<>pg_catalog.convert_to('s24:tesl-migration-canonical','UTF8') or envelope[2]<>pg_catalog.convert_to('s1:1','UTF8') or envelope[3]<>pg_catalog.convert_to('s8:contract','UTF8') then raise exception 'tesl: invalid stage Contract framing'; end if;
 c:=` + ns + `tesl_stage_canonical_children(envelope[4]);
 if pg_catalog.cardinality(c)<>10 or ` + ns + `tesl_stage_atom(c[1])<>'tesl-stage-contract-v1' or c[2]<>physical[2] or c[3]<>physical[3] or c[4]<>physical[4] or c[5]<>physical[5]
  or ` + ns + `tesl_stage_atom(c[7])<>p.contract_hash or ` + ns + `tesl_stage_atom(c[8])<>settled_digest or c[9]<>pg_catalog.convert_to('l0:','UTF8') then raise exception 'tesl: stage Contract differs from exact physical owner'; end if;
 foreach g in array ` + ns + `tesl_stage_canonical_children(physical[10]) loop
  spec:=` + ns + `tesl_stage_guard_spec(v,g);
  operations:=pg_catalog.array_append(operations,` + ns + `tesl_stage_list(array[pg_catalog.convert_to('s13:promote-stage','UTF8'),(` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(g))[2]))[4],g]));
 end loop;
 if c[10]<>` + ns + `tesl_stage_list(operations) then raise exception 'tesl: PromoteStage must name every exact semantic stage and target'; end if;
 if settled_doc<>` + ns + `tesl_stage_settled(v) then raise exception 'tesl: stage Contract settled representation differs structurally'; end if;
 if ` + ns + `tesl_stage_atom(c[6])<>pg_catalog.encode(pg_catalog.sha256(` + ns + `tesl_stage_list(array[envelope[1],envelope[2],envelope[3],
  ` + ns + `tesl_stage_list(array[pg_catalog.convert_to('s23:tesl-stage-promotion-v1','UTF8'),c[10]])])),'hex') then raise exception 'tesl: stage Contract behavior differs'; end if;
 insert into ` + ns + `tesl_schema_stage_contracts values(v,doc,digest,p.contract_hash,settled_doc,settled_digest,abi) on conflict(version) do nothing;
 select * into existing from ` + ns + `tesl_schema_stage_contracts where version=v;
 if existing.contract<>doc or existing.contract_hash<>digest or existing.window_hash<>p.contract_hash or existing.settled<>settled_doc or existing.settled_hash<>settled_digest then raise exception 'tesl: immutable reviewed stage Contract differs'; end if;
end`},
		{"tesl_stage_handoff", "v integer, digest text", "void", "volatile", `
declare c ` + ns + `tesl_schema_stage_contracts%rowtype; p ` + ns + `tesl_row_physical%rowtype;
 body bytea[]; g bytea; s jsonb; id text; job text; n integer:=0; existing ` + ns + `tesl_schema_stage_promotions%rowtype;
begin
 select * into c from ` + ns + `tesl_schema_stage_contracts where version=v and contract_hash=digest for share;
 if not found then raise exception 'tesl: stage handoff lacks reviewed Contract'; end if;
 perform ` + ns + `tesl_register_stage_contract(v,c.contract,c.contract_hash,c.settled,c.settled_hash,c.compiler_abi);
 perform ` + ns + `tesl_stage_guards_ready(v);
 if not exists(select 1 from ` + ns + `tesl_schema_state state where state.id=1 and state.current=v and state.min_version=v and state.compat_floor=v)
  or not exists(select 1 from ` + ns + `tesl_row_epochs where through_version=v) then raise exception 'tesl: stage handoff requires committed writer and compatibility retirement'; end if;
 select * into p from ` + ns + `tesl_row_physical where version=v and contract_hash=c.window_hash for share;
 if not found then raise exception 'tesl: stage handoff physical source differs'; end if;
 body:=` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(p.contract))[4]);
 foreach g in array ` + ns + `tesl_stage_canonical_children(body[10]) loop
  s:=` + ns + `tesl_stage_guard_spec(v,g);id:=s->>'stage';
  job:=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('tesl-migration-object-v1','UTF8')||pg_catalog.decode(c.contract_hash,'hex')||pg_catalog.int4send(n)),'hex');
  select * into existing from ` + ns + `tesl_schema_stage_promotions where stage_id=id;
  if found then
   if existing.version<>v or existing.ordinal<>p.operation_count+n or existing.job_id<>job or existing.contract_hash<>digest then raise exception 'tesl: immutable promotion job differs'; end if;
  else
   insert into ` + ns + `tesl_schema_stage_promotions values(id,v,p.operation_count+n,job,digest,'promoting',null);
   insert into ` + ns + `tesl_schema_index(id,version,ordinal,table_name,index_name,key_columns,is_unique) values(job,v,p.operation_count+n,s->>'table',s->>'target',array[s->>'column'],true);
   insert into ` + ns + `tesl_schema_leases(name) values('index:'||(s->>'target'));
   update ` + ns + `tesl_schema_stages set state='promoting' where stage_id=id and state='pending';
   if not found then raise exception 'tesl: promotion requires pending stage'; end if;
  end if;
  n:=n+1;
 end loop;
end`},
		{"tesl_stage_target_oid", "stage_key text", "bigint", "stable", `
declare s jsonb; result bigint;
begin
 select g.spec into s from ` + ns + `tesl_schema_stage_guards g join ` + ns + `tesl_schema_stage_promotions p on p.stage_id=g.stage_id
 join ` + ns + `tesl_schema_index j on j.id=p.job_id where g.stage_id=stage_key and j.state='valid' and j.is_unique and j.index_name=g.spec->>'target' and j.table_name=g.spec->>'table' and j.key_columns=array[g.spec->>'column'];
 if not found then return 0; end if;
 select ix.oid::bigint into result from pg_catalog.pg_index i
 join pg_catalog.pg_class ix on ix.oid=i.indexrelid join pg_catalog.pg_class t on t.oid=i.indrelid
 join pg_catalog.pg_namespace n on n.oid=t.relnamespace
 join pg_catalog.pg_attribute a on a.attrelid=t.oid and a.attname=s->>'column' and not a.attisdropped
 join pg_catalog.pg_opclass op on op.oid=i.indclass[0] join pg_catalog.pg_namespace pn on pn.oid=op.opcnamespace
 where n.nspname=` + pgStageGuardSQLLiteral(namespace) + ` and t.relname=s->>'table' and ix.relname=s->>'target'
 and ix.relnamespace=t.relnamespace and ix.relowner=t.relowner and ix.relam=403 and i.indisunique and not i.indisprimary
 and i.indisvalid and i.indisready and i.indislive and not i.indcheckxmin and i.indimmediate and not i.indisexclusion
 and i.indexprs is null and i.indpred is null and i.indnkeyatts=1 and i.indnatts=1 and i.indkey[0]=a.attnum and i.indoption[0]=0
 and not coalesce((pg_catalog.to_jsonb(i)->>'indnullsnotdistinct')::boolean,false)
 and pn.nspname='pg_catalog' and op.opcdefault and op.opcmethod=403 and op.opcintype=a.atttypid and i.indcollation[0]=a.attcollation;
 return coalesce(result,0);
end`},
		{"tesl_finish_stage_enforcement", "stage_key text", "void", "volatile", `
declare p ` + ns + `tesl_schema_stage_promotions%rowtype; s jsonb; target bigint; fname text;
begin
 select * into p from ` + ns + `tesl_schema_stage_promotions where stage_id=stage_key for update;
 if not found then raise exception 'tesl: enforcement lacks reviewed handoff'; end if;
 target:=` + ns + `tesl_stage_target_oid(stage_key);
 if target=0 or not exists(select 1 from ` + ns + `tesl_schema_index j where j.id=p.job_id and j.state='valid') then raise exception 'tesl: enforcement requires exact valid target job and catalog'; end if;
 if p.state='enforced' then
  if p.enforced_index_oid<>target then raise exception 'tesl: enforced target was replaced'; end if;
  return;
 end if;
 select spec into s from ` + ns + `tesl_schema_stage_guards where stage_id=stage_key;
 fname:='tesl_guard_'||pg_catalog.left(stage_key,48);
 if exists(select 1 from pg_catalog.pg_trigger tr join pg_catalog.pg_class t on t.oid=tr.tgrelid join pg_catalog.pg_namespace n on n.oid=t.relnamespace
  where n.nspname=` + pgStageGuardSQLLiteral(namespace) + ` and t.relname=s->>'table' and tr.tgname=fname) then raise exception 'tesl: guard switchover must share the enforcement transaction'; end if;
 execute pg_catalog.format('drop function %I.%I()',` + pgStageGuardSQLLiteral(namespace) + `,fname);
 update ` + ns + `tesl_schema_stage_promotions set state='enforced',enforced_index_oid=target where stage_id=stage_key;
 update ` + ns + `tesl_schema_stages set state='enforced' where stage_id=stage_key;
end`},
	}
}
