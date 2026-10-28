package migrationtest

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// catalogEvidence records semantic catalog inputs, not pg_get_*def strings or
// physical tuple/object identities. This independent fixture reader intentionally
// also reports benign extra objects; production reconciliation must classify them.
func catalogEvidence(t *testing.T, f *databaseFixture, conn *pgx.Conn, table string) string {
	t.Helper()
	var result string
	err := conn.QueryRow(f.ctx, `select jsonb_build_object(
		'relation',jsonb_build_object('kind',c.relkind,'owner',c.relowner,'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity,'partition',c.relispartition),
		'columns',coalesce((select jsonb_agg(jsonb_build_object('name',a.attname,'type',a.atttypid,'typmod',a.atttypmod,
			'notnull',a.attnotnull,'collation',a.attcollation,'generated',a.attgenerated,'identity',a.attidentity,
			'default',pg_get_expr(d.adbin,d.adrelid)) order by a.attnum)
			from pg_attribute a left join pg_attrdef d on (d.adrelid,d.adnum)=(a.attrelid,a.attnum)
			where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped),'[]'::jsonb),
		'indexes',coalesce((select jsonb_agg(jsonb_build_object('name',idx.relname,'method',am.amname,
			'unique',i.indisunique,'primary',i.indisprimary,'exclusion',i.indisexclusion,'immediate',i.indimmediate,
			'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive,'key_count',i.indnkeyatts,'attribute_count',i.indnatts,
			'keys',i.indkey::text,'opclasses',i.indclass::text,'collations',i.indcollation::text,'options',i.indoption::text,
			'nulls_not_distinct',coalesce((to_jsonb(i)->>'indnullsnotdistinct')::boolean,false),
			'expression',pg_get_expr(i.indexprs,i.indrelid),'predicate',pg_get_expr(i.indpred,i.indrelid),
			'constraint_owned',exists(select 1 from pg_constraint con where con.conindid=i.indexrelid and con.conrelid=c.oid)) order by idx.relname)
			from pg_index i join pg_class idx on idx.oid=i.indexrelid join pg_am am on am.oid=idx.relam where i.indrelid=c.oid),'[]'::jsonb),
		'constraints',coalesce((select jsonb_agg(jsonb_build_object('name',con.conname,'kind',con.contype,'validated',con.convalidated,
			'deferrable',con.condeferrable,'deferred',con.condeferred,'keys',con.conkey,'reference',con.confrelid,
			'reference_keys',con.confkey,'update',con.confupdtype,'delete',con.confdeltype,'match',con.confmatchtype,
			'inherited',con.coninhcount,'no_inherit',con.connoinherit,'expression',pg_get_expr(con.conbin,con.conrelid)) order by con.conname)
			from pg_constraint con where con.conrelid=c.oid),'[]'::jsonb),
		'triggers',coalesce((select jsonb_agg(jsonb_build_object('name',tg.tgname,'type',tg.tgtype,'enabled',tg.tgenabled,
			'internal',tg.tgisinternal,'function',tg.tgfoid,'args',encode(tg.tgargs,'hex'),'columns',tg.tgattr::text,
			'old_table',tg.tgoldtable,'new_table',tg.tgnewtable) order by tg.tgname) from pg_trigger tg where tg.tgrelid=c.oid),'[]'::jsonb),
		'policies',coalesce((select jsonb_agg(jsonb_build_object('name',p.polname,'command',p.polcmd,'permissive',p.polpermissive,
			'roles',p.polroles,'using',pg_get_expr(p.polqual,p.polrelid),'check',pg_get_expr(p.polwithcheck,p.polrelid)) order by p.polname)
			from pg_policy p where p.polrelid=c.oid),'[]'::jsonb)
	)::text from pg_class c where c.oid=$1::regclass`, table).Scan(&result)
	if err != nil {
		t.Fatal(err)
	}
	if !json.Valid([]byte(result)) {
		t.Fatalf("invalid catalog evidence: %q", result)
	}
	return result
}

// INV-CATALOG-EVIDENCE; TR-CATALOG-COMPARE.
func TestPostgresCatalogEvidenceDetectsBehavioralDrift(t *testing.T) {
	f := newDatabaseFixture(t)
	f.exec(t, "set search_path = ''")
	table := f.schema + ".catalog_notes"
	f.exec(t, "create table "+table+` (id integer primary key, title text collate pg_catalog."C" not null, amount numeric default 0, constraint amount_positive check (amount>=0))`)
	f.exec(t, "create index title_search on "+table+" (lower(title)) where amount>=0")
	f.exec(t, "create table "+f.schema+".reference_notes(id int primary key)")
	f.exec(t, "create function "+f.schema+".catalog_trigger() returns trigger language plpgsql as 'begin return NEW; end'")
	baseline := catalogEvidence(t, f, f.conn, table)
	cases := []struct{ name, sql string }{
		{"type", "alter table " + table + " alter column title type varchar(20)"},
		{"typmod", "alter table " + table + " alter column amount type numeric(5,2)"},
		{"nullability", "alter table " + table + " alter column title drop not null"},
		{"collation", "alter table " + table + ` alter column title type text collate pg_catalog."POSIX"`},
		{"default", "alter table " + table + " alter column amount set default 1"},
		{"function_default", "alter table " + table + " alter column amount set default extract(epoch from now())"},
		{"missing_default", "alter table " + table + " alter column amount drop default"},
		{"required_extra", "alter table " + table + " add column required text not null"},
		{"generated", "alter table " + table + " add column computed numeric generated always as (amount+1) stored"},
		{"identity", "alter table " + table + " add column generated_id int generated always as identity"},
		{"unique", "create unique index unique_title on " + table + " (title)"},
		{"constraint_owned", "alter table " + table + " add constraint unique_title unique(title)"},
		{"deferrable", "alter table " + table + " add constraint unique_title unique(title) deferrable initially deferred"},
		{"check", "alter table " + table + " add constraint title_not_empty check (title <> '')"},
		{"unvalidated_check", "alter table " + table + " add constraint title_not_empty check (title <> '') not valid"},
		{"foreign_key", "alter table " + table + " add constraint reference_note foreign key(id) references " + f.schema + ".reference_notes(id) on delete cascade"},
		{"trigger", "create trigger changed before update on " + table + " for each row execute function " + f.schema + ".catalog_trigger()"},
		{"disabled_trigger", "create trigger changed before update on " + table + " for each row execute function " + f.schema + ".catalog_trigger(); alter table " + table + " disable trigger changed"},
		{"policy", "create policy visible on " + table + " using (id>0)"},
		{"rls", "alter table " + table + " enable row level security"},
		{"force_rls", "alter table " + table + " force row level security"},
		{"owner", "alter table " + table + " owner to " + f.worker},
		{"index_expression", "drop index " + f.schema + ".title_search; create index title_search on " + table + " (upper(title)) where amount>=0"},
		{"index_predicate", "drop index " + f.schema + ".title_search; create index title_search on " + table + " (lower(title)) where amount>0"},
		{"index_collation", "drop index " + f.schema + ".title_search; create index title_search on " + table + ` (lower(title) collate pg_catalog."POSIX") where amount>=0`},
		{"index_opclass", "drop index " + f.schema + ".title_search; create index title_search on " + table + " (lower(title) text_pattern_ops) where amount>=0"},
		{"index_order", "drop index " + f.schema + ".title_search; create index title_search on " + table + " (lower(title) desc nulls last) where amount>=0"},
		{"index_include", "drop index " + f.schema + ".title_search; create index title_search on " + table + " (lower(title)) include(id) where amount>=0"},
		{"partitioned", "drop table " + table + "; create table " + table + ` (id integer primary key, title text collate pg_catalog."C" not null, amount numeric default 0, constraint amount_positive check (amount>=0)) partition by range(id)`},
	}
	var server int
	if err := f.conn.QueryRow(f.ctx, "select current_setting('server_version_num')::int").Scan(&server); err != nil {
		t.Fatal(err)
	}
	if server >= 150000 {
		cases = append(cases, struct{ name, sql string }{"nulls_not_distinct", "create unique index unique_title on " + table + " (title) nulls not distinct"})
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f.exec(t, "begin")
			defer f.exec(t, "rollback")
			f.exec(t, tc.sql)
			if actual := catalogEvidence(t, f, f.conn, table); actual == baseline {
				t.Fatalf("catalog evidence omitted %s: %s", tc.name, actual)
			}
		})
	}
	// Renormalizing an expression and recreating its catalog row must not make a
	// false difference merely because it has a new OID or differently spaced SQL.
	f.exec(t, "begin")
	f.exec(t, "alter table "+table+" drop constraint amount_positive, add constraint amount_positive check (((amount OPERATOR(pg_catalog.>=) CAST(0 AS numeric))))")
	if actual := catalogEvidence(t, f, f.conn, table); actual != baseline {
		t.Fatalf("equivalent catalog definition changed evidence:\nbaseline=%s\nactual=%s", baseline, actual)
	}
	f.exec(t, "rollback")
}

func catalogObjectEvidence(t *testing.T, f *databaseFixture, table, component, name string) map[string]any {
	t.Helper()
	var evidence map[string]json.RawMessage
	if err := json.Unmarshal([]byte(catalogEvidence(t, f, f.conn, table)), &evidence); err != nil {
		t.Fatal(err)
	}
	var objects []map[string]any
	if err := json.Unmarshal(evidence[component], &objects); err != nil {
		t.Fatal(err)
	}
	for _, object := range objects {
		if object["name"] == name {
			return object
		}
	}
	t.Fatalf("catalog component %s has no %s: %+v", component, name, objects)
	return nil
}

// INV-CATALOG-EVIDENCE; TR-CATALOG-COMPARE.
func TestPostgresCatalogIdentityDistinguishesIndividualProperties(t *testing.T) {
	f := newDatabaseFixture(t)
	f.exec(t, "set search_path = ''")
	table := f.schema + ".catalog_identity"
	f.exec(t, "create table "+table+` (id int, title text collate pg_catalog."C")`)
	f.exec(t, "create function "+f.schema+".identity_trigger() returns trigger language plpgsql as 'begin return NEW; end'")
	cases := []struct {
		name, component, property, first, change string
	}{
		{"constraint_owned", "indexes", "constraint_owned",
			"create unique index probe on " + table + " (title)",
			"alter table " + table + " add constraint probe unique using index probe"},
		{"deferrable", "indexes", "immediate",
			"alter table " + table + " add constraint probe unique(title)",
			"alter table " + table + " drop constraint probe, add constraint probe unique(title) deferrable"},
		{"initially_deferred", "constraints", "deferred",
			"alter table " + table + " add constraint probe unique(title) deferrable initially immediate",
			"alter table " + table + " drop constraint probe, add constraint probe unique(title) deferrable initially deferred"},
		{"check_validated", "constraints", "validated",
			"alter table " + table + " add constraint probe check(id>0) not valid",
			"alter table " + table + " validate constraint probe"},
		{"trigger_enabled", "triggers", "enabled",
			"create trigger probe before update on " + table + " for each row execute function " + f.schema + ".identity_trigger()",
			"alter table " + table + " disable trigger probe"},
		{"policy_expression", "policies", "using",
			"create policy probe on " + table + " using (id>0)",
			"alter policy probe on " + table + " using (id>=0)"},
		{"identity_mode", "columns", "identity",
			"alter table " + table + " add column probe int generated always as identity",
			"alter table " + table + " alter column probe set generated by default"},
		{"generated_expression", "columns", "default",
			"alter table " + table + " add column probe int generated always as (id+1) stored",
			"alter table " + table + " drop column probe, add column probe int generated always as (id+2) stored"},
		{"index_order", "indexes", "options",
			"create index probe on " + table + " (title asc nulls last)",
			"drop index " + f.schema + ".probe; create index probe on " + table + " (title desc nulls first)"},
		{"index_opclass", "indexes", "opclasses",
			"create index probe on " + table + " (title)",
			"drop index " + f.schema + ".probe; create index probe on " + table + " (title text_pattern_ops)"},
		{"index_collation", "indexes", "collations",
			"create index probe on " + table + " (title)",
			"drop index " + f.schema + ".probe; create index probe on " + table + ` (title collate pg_catalog."POSIX")`},
		{"index_expression", "indexes", "expression",
			"create index probe on " + table + " (lower(title))",
			"drop index " + f.schema + ".probe; create index probe on " + table + " (upper(title))"},
		{"index_predicate", "indexes", "predicate",
			"create index probe on " + table + " (title) where id>0",
			"drop index " + f.schema + ".probe; create index probe on " + table + " (title) where id>=0"},
	}
	var server int
	if err := f.conn.QueryRow(f.ctx, "select current_setting('server_version_num')::int").Scan(&server); err != nil {
		t.Fatal(err)
	}
	if server >= 150000 {
		cases = append(cases, struct{ name, component, property, first, change string }{
			"nulls_not_distinct", "indexes", "nulls_not_distinct",
			"create unique index probe on " + table + " (title)",
			"drop index " + f.schema + ".probe; create unique index probe on " + table + " (title) nulls not distinct"})
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f.exec(t, "begin")
			defer f.exec(t, "rollback")
			f.exec(t, tc.first)
			before := catalogObjectEvidence(t, f, table, tc.component, "probe")
			f.exec(t, tc.change)
			after := catalogObjectEvidence(t, f, table, tc.component, "probe")
			if reflect.DeepEqual(before[tc.property], after[tc.property]) {
				t.Fatalf("catalog identity omitted %s.%s: %+v", tc.component, tc.property, before)
			}
			delete(before, tc.property)
			delete(after, tc.property)
			if !reflect.DeepEqual(before, after) {
				t.Fatalf("property witness is not isolated to %s: before=%+v after=%+v", tc.property, before, after)
			}
		})
	}
}

// INV-CATALOG-EXTRA-INDEX; TR-CATALOG-COMPARE.
func TestPostgresNonuniqueIndexesCanRejectOtherwiseValidRows(t *testing.T) {
	for _, tc := range []struct {
		name, table, value, index, code string
	}{
		{"expression", "value numeric", "0", "((1/value))", "22012"},
		{"predicate", "value numeric", "0", "(value) where 1/value>0", "22012"},
		{"wide_plain_key", "value text", "(select string_agg(md5(i::text),'') from generate_series(1,1000) i)", "(value)", "54000"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newDatabaseFixture(t)
			table := f.schema + ".index_rejection"
			f.exec(t, "create table "+table+" (id int primary key,"+tc.table+")")
			insert := "insert into " + table + " (id,value) values (1," + tc.value + ")"
			f.exec(t, insert)
			f.exec(t, "delete from "+table)
			f.exec(t, "create index unexpected_index on "+table+" "+tc.index)
			var unique bool
			if err := f.conn.QueryRow(f.ctx, "select indisunique from pg_index where indexrelid=$1::regclass", f.schema+".unexpected_index").Scan(&unique); err != nil || unique {
				t.Fatalf("fixture must be nonunique: %t %v", unique, err)
			}
			_, err := f.conn.Exec(f.ctx, insert)
			var pgerr *pgconn.PgError
			if !errors.As(err, &pgerr) || pgerr.Code != tc.code {
				t.Fatalf("nonunique %s index did not reject the previously valid insert with %s: %v", tc.name, tc.code, err)
			}
			var count int
			if err := f.conn.QueryRow(f.ctx, "select count(*) from "+table).Scan(&count); err != nil || count != 0 {
				t.Fatalf("rejected indexed write published rows: %d %v", count, err)
			}
		})
	}
}
