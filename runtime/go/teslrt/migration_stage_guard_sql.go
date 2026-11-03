package teslrt

import (
	"fmt"
	"strconv"
	"strings"
)

func pgStageGuardTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{{"tesl_schema_stage_guards", `
 stage_id text primary key,
 version integer not null check(version>=3),
 descriptor bytea not null,
 physical_hash text not null,
 spec jsonb not null`}}
}

// All substitution operands are SQL literals/identifiers derived from the
// sealed descriptor. No Worker-supplied function text is accepted.
const pgStageGuardBodyTemplate = `
declare writer integer; duplicate boolean; prior text[]; i integer;
 settings text[]:=array['plan_cache_mode','enable_seqscan','enable_bitmapscan','enable_indexscan','enable_indexonlyscan','max_parallel_workers_per_gather','jit','seq_page_cost','random_page_cost','cpu_tuple_cost','cpu_index_tuple_cost','cpu_operator_cost'];
 setting_values text[]:=array['force_custom_plan','off','off','on','on','0','off','0','0','0','0','0'];
 key_bytes bytea; db_bytes bytea; stage_bytes bytea;
begin
 writer:=%[1]stesl_writer_version();
 if writer<%[2]s then return NEW; end if;
 if writer<>%[2]s then raise exception 'tesl: unsupported stage guard writer release'; end if;
 if NEW.%[3]s is null then return NEW; end if;
 if TG_OP='UPDATE' and NEW.%[3]s is not distinct from OLD.%[3]s then return NEW; end if;
 perform %[1]stesl_stage_guard_catalog(%[4]s);
 key_bytes:=pg_catalog.%[5]s(NEW.%[3]s);
 select pg_catalog.convert_to(database_uuid::text,'UTF8') into db_bytes from %[1]stesl_schema_meta where id=1;
 stage_bytes:=pg_catalog.convert_to(%[4]s,'UTF8');
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(pg_catalog.encode(
  pg_catalog.int4send(pg_catalog.octet_length(db_bytes))||db_bytes||
  pg_catalog.int4send(pg_catalog.octet_length(stage_bytes))||stage_bytes||
  pg_catalog.int4send(pg_catalog.octet_length(key_bytes))||key_bytes,'hex'),0));
 -- VOLATILE SPI: the probe obtains a fresh READ COMMITTED snapshot after the
 -- lock wait. EXECUTE replans this actual probe, not an earlier EXPLAIN.
 for i in 1..pg_catalog.cardinality(settings) loop
  prior[i]:=pg_catalog.current_setting(settings[i]);
  perform pg_catalog.set_config(settings[i],setting_values[i],true);
 end loop;
 if TG_OP='UPDATE' then
  execute %[6]s into duplicate using NEW.%[3]s,OLD.%[7]s;
 else
  execute %[8]s into duplicate using NEW.%[3]s;
 end if;
 for i in 1..pg_catalog.cardinality(settings) loop
  perform pg_catalog.set_config(settings[i],prior[i],true);
 end loop;
 if duplicate then
  raise unique_violation using message='duplicate key violates staged unique guard',constraint=%[9]s,schema=%[10]s,table=%[11]s;
 end if;
 return NEW;
exception when others then
 -- The exception subtransaction restores all settings and locks changed by
 -- this call before rethrowing; callers may catch it at their own savepoint.
 raise;
end`

func pgStageGuardSQLLiteral(s string) string {
	if strings.Contains(s, "\\") {
		return "E'" + strings.ReplaceAll(strings.ReplaceAll(s, "\\", "\\\\"), "'", "''") + "'"
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func pgStageGuardFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	template := pgStageGuardBodyTemplate
	for i := 1; i <= 11; i++ {
		template = strings.ReplaceAll(template, "%["+strconv.Itoa(i)+"]s", "%"+strconv.Itoa(i)+"$s")
	}
	return []pgMigrationControlFunction{
		{"tesl_stage_atom", "doc bytea", "text", "immutable", `
begin
 perform ` + ns + `tesl_stage_canonical_children(pg_catalog.convert_to('l1:','UTF8')||doc);
 if pg_catalog.get_byte(doc,0)<>115 then raise exception 'tesl: stage atom required'; end if;
 return pg_catalog.substring(pg_catalog.convert_from(doc,'UTF8'),pg_catalog.strpos(pg_catalog.convert_from(doc,'UTF8'),':')+1);
end`},
		{"tesl_stage_guard_spec", "v integer, doc bytea", "jsonb", "stable", `
declare p ` + ns + `tesl_row_physical%rowtype; s ` + ns + `tesl_schema_stages%rowtype;
 root bytea[]; body bytea[]; g bytea[]; d bytea[]; target bytea[]; keys bytea[];
 e bytea; ef bytea[]; c bytea; cf bytea[]; pk text; pkt text; matched boolean:=false;
 id text; tbl text; col text; typ text; dest text;
begin
 select * into p from ` + ns + `tesl_row_physical where version=v;
 if not found or v<3 or not p.epoch_preserving then raise exception 'tesl: guard requires protected promotion window'; end if;
 root:=` + ns + `tesl_stage_canonical_children(p.contract);
 if pg_catalog.cardinality(root)<>4 then raise exception 'tesl: guard physical envelope differs'; end if;
 body:=` + ns + `tesl_stage_canonical_children(root[4]);
 if pg_catalog.cardinality(body)<>10 or ` + ns + `tesl_stage_atom(body[1])<>'tesl-retained-physical-version-v10' or
  body[4]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(v::text,'UTF8')) or
  pg_catalog.array_position(` + ns + `tesl_stage_canonical_children(body[10]),doc) is null or body[8]<>pg_catalog.convert_to('l0:','UTF8') then
  raise exception 'tesl: guard is not a direct member of protected promotion source'; end if;
 g:=` + ns + `tesl_stage_canonical_children(doc);
 if pg_catalog.cardinality(g)<>3 or ` + ns + `tesl_stage_atom(g[1])<>'staged-unique-guard-v1' or
  pg_catalog.array_position(` + ns + `tesl_stage_canonical_children(body[9]),g[2]) is null then raise exception 'tesl: guard preparation membership differs'; end if;
 d:=` + ns + `tesl_stage_canonical_children(g[2]);
 if pg_catalog.cardinality(d)<>10 then raise exception 'tesl: guard preparation width differs'; end if;
 id:=` + ns + `tesl_stage_atom(d[2]);tbl:=` + ns + `tesl_stage_atom(d[6]);col:=` + ns + `tesl_stage_atom(d[7]);typ:=` + ns + `tesl_stage_atom(d[8]);
 select * into s from ` + ns + `tesl_schema_stages where stage_id=id;
 if not found or s.descriptor<>g[2] or s.table_name<>tbl or s.introduced_version>=v or s.state not in ('pending','promoting','blocked_duplicates','enforced') or
  typ not in ('bool','int4','int8','text') then raise exception 'tesl: guard lacks exact pending stage'; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_index j where j.id=s.job_id and j.state='valid' and not j.is_unique
  and j.index_name=s.index_name and j.table_name=tbl and j.key_columns=array[col]) then raise exception 'tesl: guard requires its valid immutable prep job'; end if;
 if not exists(select 1 from ` + ns + `tesl_row_physical old where old.version=v-1 and old.contract_hash=p.predecessor_hash
  and pg_catalog.array_position(` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(old.contract))[4]))[9]),g[2]) is not null) then
  raise exception 'tesl: guard predecessor preparation differs'; end if;
 target:=` + ns + `tesl_stage_canonical_children(g[3]);
 if pg_catalog.cardinality(target)<>3 then raise exception 'tesl: guard target width differs'; end if;
 dest:=` + ns + `tesl_stage_atom(target[1]);keys:=` + ns + `tesl_stage_canonical_children(target[2]);
 if dest=s.index_name or pg_catalog.octet_length(dest) not between 1 and 63 or keys<>array[d[7]] or
  target[3]<>pg_catalog.convert_to('l2:s4:bools4:true','UTF8') then raise exception 'tesl: guard target differs'; end if;
 foreach e in array ` + ns + `tesl_stage_canonical_children(body[7]) loop
  ef:=` + ns + `tesl_stage_canonical_children(e);
  if pg_catalog.cardinality(ef)<>9 then raise exception 'tesl: guard requires additive entity shape'; end if;
  if ef[1]<>d[4] or ef[2]<>d[6] then continue; end if;
  foreach c in array ` + ns + `tesl_stage_canonical_children(ef[6]) loop
   cf:=` + ns + `tesl_stage_canonical_children(c);
   if pg_catalog.cardinality(cf)<>6 then raise exception 'tesl: guard column shape differs'; end if;
   if cf[1]=d[7] and cf[2]=d[8] and cf[3]=d[9] and cf[4]=pg_catalog.convert_to('l2:s4:bools5:false','UTF8') then matched:=true; end if;
   if cf[4]=pg_catalog.convert_to('l2:s4:bools4:true','UTF8') then
    if pk is not null or cf[3]<>pg_catalog.convert_to('l2:s4:bools5:false','UTF8') then raise exception 'tesl: guard requires one nonnull PK'; end if;
    pk:=` + ns + `tesl_stage_atom(cf[1]);pkt:=` + ns + `tesl_stage_atom(cf[2]);
   end if;
  end loop;
 end loop;
 if not matched or pk is null or pkt not in ('bool','int4','int8','text','numeric') then raise exception 'tesl: guard physical key/PK differs'; end if;
 return pg_catalog.jsonb_build_object('stage',id,'version',v,'table',tbl,'column',col,'scalar',typ,'target',dest,'prep',s.index_name,'pk',pk,'pk_type',pkt);
end`},
		{"tesl_stage_guard_body", "s jsonb", "text", "immutable", `
declare probe text; update_probe text; send text; col text; tbl text; typ text; pk text; pkt text;
begin
 send:=case s->>'scalar' when 'bool' then 'boolsend' when 'int4' then 'int4send' when 'int8' then 'int8send' when 'text' then 'textsend' end;
 if send is null then raise exception 'tesl: unsupported guard send function'; end if;
 col:='"'||pg_catalog.replace(s->>'column','"','""')||'"';tbl:='"'||pg_catalog.replace(s->>'table','"','""')||'"';
 typ:='"'||pg_catalog.replace(s->>'scalar','"','""')||'"';pk:='"'||pg_catalog.replace(s->>'pk','"','""')||'"';pkt:='"'||pg_catalog.replace(s->>'pk_type','"','""')||'"';
 probe:='select exists(select 1 from '||` + pgStageGuardSQLLiteral(ns) + `||tbl||' where '||col||' OPERATOR(pg_catalog.=) $1::pg_catalog.'||typ;
 update_probe:=probe||' and '||pk||' IS DISTINCT FROM $2::pg_catalog.'||pkt||' limit 1)';
 probe:=probe||' limit 1)';
 return pg_catalog.format(` + pgStageGuardSQLLiteral(template) + `,` + pgStageGuardSQLLiteral(ns) + `,s->>'version',col,pg_catalog.quote_literal(s->>'stage'),send,
  pg_catalog.quote_literal(update_probe),pk,pg_catalog.quote_literal(probe),pg_catalog.quote_literal(s->>'target'),` + pgStageGuardSQLLiteral(pgStageGuardSQLLiteral(namespace)) + `,pg_catalog.quote_literal(s->>'table'));
end`},
	}
}

func pgStageGuardFunction(namespace string, version int, guard pgStageGuard, pk, pkType string) pgMigrationControlFunction {
	s := guard.preparation
	probe := "select exists(select 1 from " + quoteIdentifier(namespace) + "." + quoteIdentifier(s.table) + " where " + quoteIdentifier(s.column) + " OPERATOR(pg_catalog.=) $1::pg_catalog." + quoteIdentifier(s.scalar)
	update := probe + " and " + quoteIdentifier(pk) + " IS DISTINCT FROM $2::pg_catalog." + quoteIdentifier(pkType) + " limit 1)"
	probe += " limit 1)"
	send := map[string]string{"bool": "boolsend", "int4": "int4send", "int8": "int8send", "text": "textsend"}[s.scalar]
	args := []any{quoteIdentifier(namespace) + ".", strconv.Itoa(version), quoteIdentifier(s.column), pgStageGuardSQLLiteral(s.id), send,
		pgStageGuardSQLLiteral(update), quoteIdentifier(pk), pgStageGuardSQLLiteral(probe), pgStageGuardSQLLiteral(guard.target), pgStageGuardSQLLiteral(namespace), pgStageGuardSQLLiteral(s.table)}
	return pgMigrationControlFunction{pgStageGuardName(s.id), "", "trigger", "volatile", fmt.Sprintf(pgStageGuardBodyTemplate, args...)}
}
