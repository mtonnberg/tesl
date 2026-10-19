package teslrt

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
)

func pgStageGuardCatalogFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_stage_guard_catalog", "id text", "void", "volatile", `
declare s jsonb; tbl oid; keynum smallint; pknum smallint; typ oid; coll oid; prep oid; idx record; locales jsonb; authorized_target boolean;
begin
 select spec into s from ` + ns + `tesl_schema_stage_guards where stage_id=id;
 if not found then raise exception 'tesl: stage guard has no protected activation'; end if;
 select c.oid into tbl from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname=` + pgStageGuardSQLLiteral(namespace) + ` and c.relname=s->>'table' and c.relkind='r' and c.relpersistence='p'
 and not c.relrowsecurity and not c.relforcerowsecurity and not c.relispartition and c.relam=2
 and not exists(select 1 from pg_catalog.pg_inherits h where h.inhrelid=c.oid or h.inhparent=c.oid);
 if tbl is null then raise exception 'tesl: guard requires ordinary heap table'; end if;
 select a.attnum,a.atttypid,a.attcollation into keynum,typ,coll from pg_catalog.pg_attribute a join pg_catalog.pg_type t on t.oid=a.atttypid
 join pg_catalog.pg_namespace n on n.oid=t.typnamespace where a.attrelid=tbl and a.attname=s->>'column' and not a.attisdropped
 and a.attnum>0 and t.typname=s->>'scalar' and n.nspname='pg_catalog' and t.typtype='b' and a.atttypmod=-1 and a.attgenerated='' and a.attidentity='';
 select a.attnum into pknum from pg_catalog.pg_attribute a join pg_catalog.pg_type t on t.oid=a.atttypid
 join pg_catalog.pg_namespace n on n.oid=t.typnamespace where a.attrelid=tbl and a.attname=s->>'pk' and a.attnotnull and not a.attisdropped
 and t.typname=s->>'pk_type' and n.nspname='pg_catalog' and t.typtype='b' and a.attcollation=t.typcollation and a.atttypmod=-1;
 if keynum is null or pknum is null or keynum=pknum then raise exception 'tesl: guard key catalog differs'; end if;
 if s->>'scalar'='text' then
  select pg_catalog.to_jsonb(d) into locales from pg_catalog.pg_database d where d.datname=pg_catalog.current_database();
  if coll<>100 or not exists(select 1 from pg_catalog.pg_collation c where c.oid=100 and c.collprovider='d' and c.collisdeterministic)
   or coalesce(locales->>'datlocprovider','c')<>'c' or locales->>'datcollate' not in ('C','POSIX') or locales->>'datctype' not in ('C','POSIX') then
   raise exception 'tesl: guard TEXT requires database-default libc C/POSIX'; end if;
 elsif coll<>0 then raise exception 'tesl: unexpected guard collation'; end if;
 -- The permitted secondary indexes are exactly valid single-column stage
 -- preparations. In particular no covering/nonleading index can be chosen.
 for idx in select i.*,c.relname,c.reltablespace,c.relam from pg_catalog.pg_index i join pg_catalog.pg_class c on c.oid=i.indexrelid where i.indrelid=tbl loop
  authorized_target:=exists(select 1 from ` + ns + `tesl_schema_stage_promotions p join ` + ns + `tesl_schema_stage_guards g on g.stage_id=p.stage_id
   join ` + ns + `tesl_schema_index j on j.id=p.job_id join pg_catalog.pg_attribute a on a.attrelid=tbl and a.attname=g.spec->>'column'
   where g.spec->>'table'=s->>'table' and g.spec->>'target'=idx.relname and j.index_name=idx.relname and j.table_name=s->>'table'
    and j.is_unique and j.key_columns=array[g.spec->>'column'] and idx.indkey[0]=a.attnum);
  if (not authorized_target and (not idx.indisvalid or not idx.indisready or not idx.indislive or idx.indcheckxmin))
   or idx.indexprs is not null or idx.indpred is not null or coalesce((pg_catalog.to_jsonb(idx)->>'indnullsnotdistinct')::boolean,false)
   or idx.indnkeyatts<>1 or idx.indnatts<>1 or idx.relam<>403 or idx.indisexclusion or not idx.indimmediate or idx.indoption[0]<>0 then
   raise exception 'tesl: unusable or unsafe guard index path'; end if;
  if idx.indisprimary then
   if idx.indkey[0]<>pknum or not idx.indisunique then raise exception 'tesl: guard PK index differs'; end if;
  elsif authorized_target then
   if not idx.indisunique or (idx.indisvalid and (not idx.indisready or not idx.indislive)) then raise exception 'tesl: guarded target lifecycle differs'; end if;
  elsif idx.indisunique or not exists(select 1 from ` + ns + `tesl_schema_stages st join ` + ns + `tesl_schema_index j on j.id=st.job_id
   join pg_catalog.pg_attribute a on a.attrelid=tbl and a.attname=j.key_columns[1]
   where st.table_name=s->>'table' and st.index_name=idx.relname and j.table_name=st.table_name and j.index_name=st.index_name
    and j.state='valid' and not j.is_unique and pg_catalog.cardinality(j.key_columns)=1 and idx.indkey[0]=a.attnum) then
   raise exception 'tesl: unapproved guard index path';
  end if;
  if not exists(select 1 from pg_catalog.pg_opclass op join pg_catalog.pg_namespace n on n.oid=op.opcnamespace
   join pg_catalog.pg_attribute a on a.attrelid=tbl and a.attnum=idx.indkey[0]
   where op.oid=idx.indclass[0] and op.opcdefault and op.opcmethod=403 and op.opcintype=a.atttypid and n.nspname='pg_catalog' and idx.indcollation[0]=a.attcollation) then
   raise exception 'tesl: guard index equality differs'; end if;
  if idx.relname=s->>'prep' and idx.indkey[0]=keynum and not idx.indisunique then prep:=idx.indexrelid; end if;
 end loop;
 if prep is null then raise exception 'tesl: guard prep index is absent'; end if;
 if exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_database d on d.datname=pg_catalog.current_database()
  join pg_catalog.pg_tablespace sp on sp.oid=case when c.reltablespace=0 then d.dattablespace else c.reltablespace end
  cross join lateral pg_catalog.pg_options_to_table(sp.spcoptions) opt
  where (c.oid=tbl or c.oid in(select indexrelid from pg_catalog.pg_index where indrelid=tbl))
   and opt.option_name in ('seq_page_cost','random_page_cost') and opt.option_value::double precision<>0) then
  raise exception 'tesl: guard tablespace costs must inherit zero profile or be zero'; end if;
 -- As with builtin opclasses, this profile assumes the stock PostgreSQL
 -- planner. Administrative installation of replacement planner hooks is outside
 -- the managed catalog protocol; Request does not gain pg_read_all_settings.
end`},
		{"tesl_activate_stage_guards", "v integer", "void", "volatile", `
declare p ` + ns + `tesl_row_physical%rowtype; body bytea[]; doc bytea; spec jsonb; id text; fname text; existing ` + ns + `tesl_schema_stage_guards%rowtype;
begin
 select * into p from ` + ns + `tesl_row_physical where version=v for share;
 if not found then raise exception 'tesl: missing guard physical plan'; end if;
 body:=` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(p.contract))[4]);
 if pg_catalog.cardinality(body)<>10 or ` + ns + `tesl_stage_atom(body[1])<>'tesl-retained-physical-version-v10' then
  raise exception 'tesl: activation requires guarded physical source'; end if;
 if not exists(select 1 from ` + ns + `tesl_schema_state state where state.id=1 and state.current=v-1 and state.installing_version is null) then
  raise exception 'tesl: guard activation requires exact predecessor admission'; end if;
 -- Publication's compatibility drain closes all prior statement/transaction
 -- plans before adding a trigger. It never retires the older producer here.
 if exists(select 1 from ` + ns + `tesl_schema_state s cross join ` + ns + `tesl_schema_meta m
  cross join lateral pg_catalog.generate_series(s.min_version,s.current) n(v)
  where not exists(select 1 from pg_catalog.pg_locks l where l.pid=pg_catalog.pg_backend_pid() and l.locktype='advisory' and l.granted
   and l.classid=(4294967296::bigint-m.fence_ns)::oid and l.objid=n.v::oid and l.objsubid=2 and l.mode='ExclusiveLock')) then
  raise exception 'tesl: guard activation requires drained compatibility plans'; end if;
 foreach doc in array ` + ns + `tesl_stage_canonical_children(body[10]) loop
  spec:=` + ns + `tesl_stage_guard_spec(v,doc);id:=spec->>'stage';fname:='tesl_guard_'||pg_catalog.left(id,48);
  select * into existing from ` + ns + `tesl_schema_stage_guards where stage_id=id;
  if found then raise exception 'tesl: guard activation already exists outside publication'; end if;
  insert into ` + ns + `tesl_schema_stage_guards values(id,v,doc,p.contract_hash,spec);
  perform ` + ns + `tesl_stage_guard_catalog(id);
  execute pg_catalog.format('create function %I.%I() returns trigger language plpgsql volatile security definer set search_path='''' as %L',
   ` + pgStageGuardSQLLiteral(namespace) + `,fname,` + ns + `tesl_stage_guard_body(spec));
  execute pg_catalog.format('revoke all on function %I.%I() from public',` + pgStageGuardSQLLiteral(namespace) + `,fname);
  execute pg_catalog.format('create trigger %I before insert or update on %I.%I for each row execute function %I.%I()',
   fname,` + pgStageGuardSQLLiteral(namespace) + `,spec->>'table',` + pgStageGuardSQLLiteral(namespace) + `,fname);
 end loop;
end`},
		{"tesl_stage_guards_ready", "v integer", "void", "stable", `
declare p ` + ns + `tesl_row_physical%rowtype; body bytea[]; doc bytea; s jsonb;
begin
 select * into p from ` + ns + `tesl_row_physical where version=v;
 if found and (` + ns + `tesl_row_physical_source_header(p.contract)->>'format')='tesl-retained-physical-version-v11' then perform ` + ns + `tesl_stage_reliance_ready(p.contract); return; end if;
 if not found or (` + ns + `tesl_row_physical_source_header(p.contract)->>'format')<>'tesl-retained-physical-version-v10' then return; end if;
 body:=` + ns + `tesl_stage_canonical_children((` + ns + `tesl_stage_canonical_children(p.contract))[4]);
 foreach doc in array ` + ns + `tesl_stage_canonical_children(body[10]) loop
  s:=` + ns + `tesl_stage_guard_spec(v,doc);
  if exists(select 1 from ` + ns + `tesl_schema_stage_promotions pr where pr.stage_id=s->>'stage' and pr.state='enforced' and (coalesce(pr.enforced_index_oid,0)<=0 or pr.enforced_index_oid<>` + ns + `tesl_stage_target_oid(pr.stage_id))) then raise exception 'tesl: enforced target catalog drift'; end if;
  if not exists(select 1 from ` + ns + `tesl_schema_stage_guards g where g.stage_id=s->>'stage' and g.version=v and g.descriptor=doc and g.physical_hash=p.contract_hash and g.spec=s) then
   raise exception 'tesl: promotion window guard activation is incomplete'; end if;
 end loop;
end`},
	}
}

// Reconstruct every dynamic control function from the complete protected intent;
// no stored function text is accepted as an expected catalog definition.
func pgStageGuardCatalogSpecs(ctx context.Context, tx pgx.Tx, namespace string) ([]pgMigrationControlFunction, error) {
	rows, err := tx.Query(ctx, "select g.version,g.descriptor,g.physical_hash,g.spec,p.contract,p.contract_hash from "+quoteIdentifier(namespace)+".tesl_schema_stage_guards g left join "+quoteIdentifier(namespace)+".tesl_row_physical p on p.version=g.version where not exists(select 1 from "+quoteIdentifier(namespace)+".tesl_schema_stage_promotions pr where pr.stage_id=g.stage_id and pr.state='enforced') order by g.stage_id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var functions []pgMigrationControlFunction
	for rows.Next() {
		var version int
		var raw, physical []byte
		var hash, actualHash string
		var spec map[string]json.RawMessage
		if err := rows.Scan(&version, &raw, &hash, &spec, &physical, &actualHash); err != nil {
			return nil, err
		}
		plan, err := pgParseRowPhysicalPlan(hex.EncodeToString(physical), actualHash)
		if err != nil {
			return nil, err
		}
		if plan.version != version || hash != actualHash {
			return nil, fmt.Errorf("guard activation physical identity differs")
		}
		at := slices.IndexFunc(plan.stageGuards, func(g pgStageGuard) bool { return g.descriptor == string(raw) })
		if at < 0 {
			return nil, fmt.Errorf("guard activation is not in protected source")
		}
		g := plan.stageGuards[at]
		e := plan.entity(g.preparation.entity)
		if e == nil {
			return nil, fmt.Errorf("guard activation entity missing")
		}
		pk, pkt := "", ""
		for _, c := range e.columns {
			if c.catalog.PrimaryKey {
				pk, pkt = c.catalog.Name, c.catalog.Type
			}
		}
		want := map[string]any{"stage": g.preparation.id, "version": version, "table": g.preparation.table, "column": g.preparation.column, "scalar": g.preparation.scalar, "target": g.target, "prep": g.preparation.index, "pk": pk, "pk_type": pkt}
		encoded, _ := json.Marshal(want)
		actual, _ := json.Marshal(spec)
		if string(encoded) != string(actual) {
			return nil, fmt.Errorf("guard activation specification differs")
		}
		functions = append(functions, pgStageGuardFunction(namespace, version, g, pk, pkt))
	}
	return functions, rows.Err()
}

func pgVerifyStageGuardTriggers(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, actual *pgCatalogTable) error {
	rows, err := tx.Query(ctx, "select stage_id,version,descriptor,spec->>'pk',spec->>'pk_type' from "+pgx.Identifier{namespace, "tesl_schema_stage_guards"}.Sanitize()+" g where spec->>'table'=$1 and not exists(select 1 from "+pgx.Identifier{namespace, "tesl_schema_stage_promotions"}.Sanitize()+" p where p.stage_id=g.stage_id and p.state='enforced') order by stage_id", actual.Name)
	if err != nil {
		return err
	}
	type expected struct {
		id      string
		version int
		g       pgStageGuard
		pk, pkt string
	}
	var expectedGuards []expected
	for rows.Next() {
		var e expected
		var raw []byte
		if err := rows.Scan(&e.id, &e.version, &raw, &e.pk, &e.pkt); err != nil {
			rows.Close()
			return err
		}
		n, _, err := pgReadRowCanonical(hex.EncodeToString(raw))
		if err != nil {
			rows.Close()
			return err
		}
		gs, err := pgParseStageGuards(pgRowList(n))
		if err != nil {
			rows.Close()
			return err
		}
		if gs == nil || len(gs) != 1 {
			rows.Close()
			return fmt.Errorf("guard record requires exactly one descriptor")
		}
		e.g = gs[0]
		if e.id != e.g.preparation.id {
			rows.Close()
			return fmt.Errorf("guard record identity differs")
		}
		expectedGuards = append(expectedGuards, e)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, e := range expectedGuards {
		fn := pgStageGuardFunction(namespace, e.version, e.g, e.pk, e.pkt)
		if actual.TriggerDefinitions == nil {
			return fmt.Errorf("missing protected stage guard trigger")
		}
		i := slices.IndexFunc(actual.TriggerDefinitions, func(t pgCatalogTrigger) bool { return t.Name == fn.name })
		if i < 0 {
			return fmt.Errorf("missing protected stage guard trigger")
		}
		one := *actual
		one.Triggers = []string{fn.name}
		one.TriggerDefinitions = []pgCatalogTrigger{actual.TriggerDefinitions[i]}
		spec := pgRowInvalidation{name: fn.name, function: fn, entity: &pgRowPhysicalEntity{table: actual.Name}}
		if err := pgVerifyRowInvalidation(ctx, tx, namespace, PgMigrationControlRoles{Worker: roles.Owner}, &one, spec); err != nil {
			return fmt.Errorf("stage guard: %w", err)
		}
		if _, err := tx.Exec(ctx, "select "+pgx.Identifier{namespace, "tesl_stage_guard_catalog"}.Sanitize()+"($1)", e.id); err != nil {
			return err
		}
		actual.TriggerDefinitions = slices.Delete(actual.TriggerDefinitions, i, i+1)
		actual.Triggers = slices.DeleteFunc(actual.Triggers, func(s string) bool { return s == fn.name })
	}
	if len(actual.TriggerDefinitions) == 0 {
		actual.TriggerDefinitions = nil
	}
	return nil
}
