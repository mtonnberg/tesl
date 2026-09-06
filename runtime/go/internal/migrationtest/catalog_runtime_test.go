package migrationtest

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"tesl.dev/runtime/go/teslrt"
)

func runtimeCatalogExpected() []teslrt.PgMigrationCatalogTable {
	return []teslrt.PgMigrationCatalogTable{{Name: "catalog_live", Columns: []teslrt.PgMigrationCatalogColumn{
		{Name: "amount", Type: "numeric", Default: &teslrt.PgMigrationCatalogConstant{Kind: "int", Value: "0"}},
		{Name: "id", Type: "text", PrimaryKey: true},
		{Name: "optional", Type: "text", Nullable: true},
		{Name: "title", Type: "text"},
	}, Indexes: []teslrt.PgMigrationCatalogIndex{
		{Name: "declared_title", Columns: []string{"title"}, Unique: true},
		{Name: "declared_amount", Columns: []string{"amount"}},
	}}}
}

func runtimeCatalogTable(t *testing.T, f *databaseFixture) (string, string) {
	t.Helper()
	table := f.schema + ".catalog_live"
	f.exec(t, "drop table if exists "+table+" cascade")
	f.exec(t, "create table "+table+" (title text not null, id text primary key, optional text, amount numeric not null default 0)")
	f.exec(t, "create unique index actual_title on "+table+" (title)")
	f.exec(t, "create index actual_amount on "+table+" (amount)")
	f.exec(t, "insert into "+table+" (id,title) values ('one','first'),('two','second')")
	var owner string
	if err := f.conn.QueryRow(f.ctx, "select current_user").Scan(&owner); err != nil {
		t.Fatal(err)
	}
	return table, owner
}

func runtimeCatalogInspect(t *testing.T, f *databaseFixture, owner string) teslrt.PgMigrationCatalogReport {
	t.Helper()
	beforeSearchPath := ""
	if err := f.conn.QueryRow(f.ctx, "show search_path").Scan(&beforeSearchPath); err != nil {
		t.Fatal(err)
	}
	report, err := teslrt.InspectPgMigrationCatalog(f.ctx, f.conn, f.schema, owner, runtimeCatalogExpected())
	if err != nil {
		t.Fatalf("runtime catalog inspection: %v\n%s", err, f.dump())
	}
	var searchPath string
	var temporary int
	if err := f.conn.QueryRow(f.ctx, "show search_path").Scan(&searchPath); err != nil {
		t.Fatal(err)
	}
	if err := f.conn.QueryRow(f.ctx, `select count(*) from pg_class where relnamespace=pg_my_temp_schema() and
 (relname like 'tesl_mig_probe_%' or relname like 'tesl_constant_%')`).Scan(&temporary); err != nil {
		t.Fatal(err)
	}
	if f.conn.PgConn().TxStatus() != 'I' || searchPath != beforeSearchPath || temporary != 0 {
		t.Fatalf("inspection leaked transaction/settings/temporary objects: %c %q %d", f.conn.PgConn().TxStatus(), searchPath, temporary)
	}
	return report
}

// INV-CATALOG-EVIDENCE, INV-CATALOG-EXPRESSION; TR-CATALOG-COMPARE.
func TestRuntimeCatalogMatchesSemanticShapesWithoutTouchingRows(t *testing.T) {
	f := newDatabaseFixture(t)
	table, owner := runtimeCatalogTable(t, f)
	initial := runtimeCatalogInspect(t, f, owner)
	if len(initial.Drift) != 0 || len(initial.Missing) != 0 || len(initial.Benign) != 0 || len(initial.Fingerprint) != 64 {
		t.Fatalf("matching catalog refused: %+v", initial)
	}
	if repeated := runtimeCatalogInspect(t, f, owner); repeated.Fingerprint != initial.Fingerprint {
		t.Fatal("catalog fingerprint changed without a catalog change")
	}
	// Expected and actual names/column ordinals differ. Equivalent indexes still
	// match, and this server normalizes both spelling variants of the default.
	f.exec(t, "alter table "+table+" alter column amount set default (((0)))")
	normalized := runtimeCatalogInspect(t, f, owner)
	if len(normalized.Drift) != 0 || normalized.Fingerprint != initial.Fingerprint {
		t.Fatalf("server-equivalent default differs: %+v", normalized)
	}
	var count int
	if err := f.conn.QueryRow(f.ctx, "select count(*) from "+table).Scan(&count); err != nil || count != 2 {
		t.Fatalf("inspection changed rows: %d %v", count, err)
	}
}

// INV-CATALOG-EVIDENCE, INV-CATALOG-EXTRA-INDEX; TR-CATALOG-COMPARE.
func TestRuntimeCatalogRefusesBehaviorChangingObjects(t *testing.T) {
	f := newDatabaseFixture(t)
	f.exec(t, "create function "+f.schema+".catalog_passthrough() returns trigger language plpgsql as 'begin return new; end'")
	for _, tc := range []struct{ name, sql string }{
		{"type", "alter table %s alter column amount type bigint"},
		{"typmod", "alter table %s alter column amount type numeric(6,2)"},
		{"nullable", "alter table %s alter column title drop not null"},
		{"collation", `alter table %s alter column title type text collate pg_catalog."C"`},
		{"default", "alter table %s alter column amount set default 9"},
		{"missing_default", "alter table %s alter column amount drop default"},
		{"check", "alter table %s add constraint content check (title <> '') not valid"},
		{"foreign_key", "alter table %s add constraint same_row foreign key (id) references " + f.schema + ".catalog_live(id)"},
		{"exclusion", "alter table %s add constraint titles_exclude exclude using btree (title with =)"},
		{"extra_index", "create index undeclared_index on %s (title)"},
		{"index_expression", "drop index " + f.schema + ".actual_title; create unique index actual_title on %s (lower(title))"},
		{"index_order", "drop index " + f.schema + ".actual_title; create unique index actual_title on %s (title desc nulls first)"},
		{"index_collation", `drop index ` + f.schema + `.actual_title; create unique index actual_title on %s (title collate pg_catalog."C")`},
		{"index_opclass", "drop index " + f.schema + ".actual_title; create unique index actual_title on %s (title text_pattern_ops)"},
		{"index_include", "drop index " + f.schema + ".actual_title; create unique index actual_title on %s (title) include (id)"},
		{"index_predicate", "drop index " + f.schema + ".actual_title; create unique index actual_title on %s (title) where amount>0"},
		{"constraint_owned", "drop index " + f.schema + ".actual_title; alter table %s add constraint actual_title unique (title) deferrable initially deferred"},
		{"owner", "alter table %s owner to " + f.worker},
		{"rls", "alter table %s enable row level security"},
		{"force_rls", "alter table %s force row level security"},
		{"policy", "create policy contents on %s using (true)"},
		{"trigger", "create trigger change before update on %s for each row execute function " + f.schema + ".catalog_passthrough()"},
		{"disabled_trigger", "create trigger change before update on %s for each row execute function " + f.schema + ".catalog_passthrough(); alter table " + f.schema + ".catalog_live disable trigger change"},
		{"rule", "create rule suppress_insert as on insert to %s do instead nothing"},
		{"unlogged", "alter table %s set unlogged"},
		{"generated", "alter table %s add column generated_value text generated always as (upper(title)) stored"},
		{"identity", "alter table %s add column automatic_id bigint generated always as identity"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			table, owner := runtimeCatalogTable(t, f)
			f.exec(t, fmt.Sprintf(tc.sql, table))
			report := runtimeCatalogInspect(t, f, owner)
			if len(report.Drift) == 0 {
				t.Fatalf("behavioral drift accepted: %s: %+v", tc.name, report)
			}
		})
	}
}

// INV-CATALOG-DEFAULT; TR-CATALOG-COMPARE.
func TestRuntimeCatalogExtraDefaultsNeverEvaluateComputingExpressions(t *testing.T) {
	f := newDatabaseFixture(t)
	f.exec(t, "create sequence "+f.schema+".catalog_calls")
	f.exec(t, "create domain "+f.schema+".catalog_domain as text check (value <> 'forbidden')")
	f.exec(t, "create type "+f.schema+".catalog_cast as (value bigint)")
	f.exec(t, fmt.Sprintf(`create function %s.catalog_convert(integer) returns %s.catalog_cast language sql volatile as
 'select row(nextval(''%s.catalog_calls''))::%s.catalog_cast'`, f.schema, f.schema, f.schema, f.schema))
	f.exec(t, fmt.Sprintf("create cast (integer as %s.catalog_cast) with function %s.catalog_convert(integer)", f.schema, f.schema))
	for _, tc := range []struct {
		name, definition string
		benign           bool
	}{
		{"nullable", "text", true},
		{"required", "text not null", false},
		{"required_constant", "text not null default 'constant'", true},
		{"text_constant", "text default 'quote''end'", true},
		{"backslash", `text default E'back\\slash'`, true},
		{"null", "text default NULL", true},
		{"required_null", "text not null default NULL", false},
		{"numeric", "numeric default -1200.5", true},
		{"numeric_integer_cast", "numeric default -123", true},
		{"numeric_bigint_cast", "numeric default -9007199254740993", true},
		{"integer", "integer default 42", true},
		{"jsonb", "jsonb default '{}'::jsonb", true},
		{"date", "date default '2020-01-01'::date", true},
		{"typmod_ok", "varchar(2) default 'ok'", true},
		{"typmod_bad", "varchar(2) default 'too long'", false},
		{"sequence", "bigint default nextval('" + f.schema + ".catalog_calls')", false},
		{"operator", "integer default 0 + 1", false},
		{"immutable_call", "text default lower('X')", false},
		{"time_cast", "timestamptz default ('now'::text)::timestamptz", false},
		{"domain", f.schema + ".catalog_domain", false},
		{"volatile_cast", f.schema + ".catalog_cast default (0)::" + f.schema + ".catalog_cast", false},
		{"array", "integer[]", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			table, owner := runtimeCatalogTable(t, f)
			// Keep existing rows while installing defaults that could fail on
			// omission: ADD without a default, then SET DEFAULT, affects no row.
			parts := strings.SplitN(tc.definition, " default ", 2)
			typ := strings.TrimSuffix(parts[0], " not null")
			f.exec(t, "alter table "+table+" add column extra "+typ)
			if strings.HasSuffix(parts[0], " not null") {
				f.exec(t, "update "+table+" set extra='seed'")
				f.exec(t, "alter table "+table+" alter column extra set not null")
			}
			if len(parts) == 2 {
				f.exec(t, "alter table "+table+" alter column extra set default "+parts[1])
			}
			f.exec(t, "select setval('"+f.schema+".catalog_calls',1,false)")
			report := runtimeCatalogInspect(t, f, owner)
			if (len(report.Drift) == 0) != tc.benign || (len(report.Benign) == 1) != tc.benign {
				t.Fatalf("extra %s classification: %+v", tc.name, report)
			}
			var called bool
			if err := f.conn.QueryRow(f.ctx, "select is_called from "+f.schema+".catalog_calls").Scan(&called); err != nil || called {
				t.Fatalf("computing default ran: %t %v", called, err)
			}
		})
	}
}

// INV-CATALOG-EVIDENCE; TR-CATALOG-COMPARE.
func TestRuntimeCatalogPreservesCallerTransactionAndCancellation(t *testing.T) {
	f := newDatabaseFixture(t)
	_, owner := runtimeCatalogTable(t, f)
	tx, err := f.conn.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = teslrt.InspectPgMigrationCatalog(f.ctx, f.conn, f.schema, owner, runtimeCatalogExpected()); err == nil {
		t.Fatal("borrowed caller transaction")
	}
	if f.conn.PgConn().TxStatus() != 'T' {
		t.Fatal("changed caller transaction")
	}
	if err = tx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(f.ctx)
	cancel()
	if _, err = teslrt.InspectPgMigrationCatalog(ctx, f.conn, f.schema, owner, runtimeCatalogExpected()); err == nil {
		t.Fatal("ignored canceled context")
	}
	if f.conn.IsClosed() || f.conn.PgConn().TxStatus() != 'I' {
		t.Fatal("pre-canceled observation changed the borrowed connection")
	}
}

// INV-CATALOG-EVIDENCE; TR-CATALOG-COMPARE.
func TestRuntimeCatalogReportsMissingStorageWithoutRecreatingIt(t *testing.T) {
	f := newDatabaseFixture(t)
	for _, tc := range []struct{ name, statement, object string }{
		{"table", "drop table %s", "catalog_live"},
		{"column", "alter table %s drop column optional", "optional"},
		{"index", "drop index " + f.schema + ".actual_amount", "declared_amount"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			table, owner := runtimeCatalogTable(t, f)
			statement := tc.statement
			if strings.Contains(statement, "%s") {
				statement = fmt.Sprintf(statement, table)
			}
			f.exec(t, statement)
			report := runtimeCatalogInspect(t, f, owner)
			if len(report.Missing) != 1 || report.Missing[0].Object != tc.object {
				t.Fatalf("wrong missing-storage evidence: %+v", report)
			}
			again := runtimeCatalogInspect(t, f, owner)
			if again.Fingerprint != report.Fingerprint || len(again.Missing) != 1 {
				t.Fatal("inspection recreated missing storage")
			}
		})
	}
}

// INV-CATALOG-EVIDENCE, INV-INDEX-READY; TR-CATALOG-COMPARE.
func TestRuntimeCatalogRejectsInvalidConcurrentIndex(t *testing.T) {
	f := newDatabaseFixture(t)
	table, owner := runtimeCatalogTable(t, f)
	f.exec(t, "drop index "+f.schema+".actual_title")
	f.exec(t, "insert into "+table+" (id,title) values ('three','first')")
	if _, err := f.conn.Exec(f.ctx, "create unique index concurrently actual_title on "+table+" (title)"); err == nil {
		t.Fatal("duplicate fixture unexpectedly indexed")
	}
	report := runtimeCatalogInspect(t, f, owner)
	found := false
	for _, issue := range report.Drift {
		if issue.Object == "actual_title" && strings.Contains(issue.Reason, "valid, ready and live") {
			found = true
		}
	}
	if !found {
		t.Fatalf("invalid semantic match accepted: %+v", report)
	}
}

// INV-CATALOG-EVIDENCE; TR-CATALOG-COMPARE.
func TestRuntimeCatalogQuotesIdentifiersAndRefusesUntrustedTypes(t *testing.T) {
	f := newDatabaseFixture(t)
	_, owner := runtimeCatalogTable(t, f)
	name := `catalog"; select 1; --`
	key := `key"value`
	qualified := pgx.Identifier{f.schema, name}.Sanitize()
	f.exec(t, "create table "+qualified+" ("+pgx.Identifier{key}.Sanitize()+" text primary key)")
	expected := []teslrt.PgMigrationCatalogTable{{Name: name, Columns: []teslrt.PgMigrationCatalogColumn{{Name: key, Type: "text", PrimaryKey: true}}}}
	report, err := teslrt.InspectPgMigrationCatalog(f.ctx, f.conn, f.schema, owner, expected)
	if err != nil || len(report.Drift) != 0 || len(report.Missing) != 0 {
		t.Fatalf("quoted identifiers: %+v %v", report, err)
	}
	if len(expected[0].Columns) != 1 {
		t.Fatal("catalog inspection mutated the expected column contract")
	}
	expected[0].Columns[0].Type = "text); drop schema public cascade; --"
	if _, err = teslrt.InspectPgMigrationCatalog(f.ctx, f.conn, f.schema, owner, expected); err == nil {
		t.Fatal("untrusted type text reached PostgreSQL")
	}
	var exists bool
	if err = f.conn.QueryRow(f.ctx, "select to_regclass($1) is not null", qualified).Scan(&exists); err != nil || !exists {
		t.Fatal("comparison modified quoted live table")
	}
}

// INV-CATALOG-EVIDENCE, INV-CATALOG-EXPRESSION; TR-CATALOG-COMPARE.
func TestRuntimeCatalogFingerprintIgnoresEquivalentPhysicalIdentity(t *testing.T) {
	f := newDatabaseFixture(t)
	table, owner := runtimeCatalogTable(t, f)
	before := runtimeCatalogInspect(t, f, owner)
	f.exec(t, "alter index "+f.schema+".actual_title rename to renamed_title")
	f.exec(t, "alter table "+table+" rename constraint catalog_live_pkey to renamed_primary")
	if renamed := runtimeCatalogInspect(t, f, owner); renamed.Fingerprint != before.Fingerprint || len(renamed.Drift) != 0 {
		t.Fatalf("equivalent names changed identity: %+v", renamed)
	}
	// Recreate the same semantic shape with different physical column ordinals,
	// new catalog OIDs, reversed index creation order and another primary name.
	f.exec(t, "drop table "+table)
	f.exec(t, "create table "+table+" (id text constraint new_primary primary key, amount numeric not null default 0, title text not null, optional text)")
	f.exec(t, "create index reordered_amount on "+table+" (amount)")
	f.exec(t, "create unique index reordered_title on "+table+" (title)")
	after := runtimeCatalogInspect(t, f, owner)
	if after.Fingerprint != before.Fingerprint || len(after.Drift) != 0 || len(after.Missing) != 0 {
		t.Fatalf("physical layout changed semantic identity: before=%s after=%+v", before.Fingerprint, after)
	}
	f.exec(t, "alter table "+table+" alter column amount set default 1")
	if changed := runtimeCatalogInspect(t, f, owner); changed.Fingerprint == before.Fingerprint || len(changed.Drift) == 0 {
		t.Fatal("semantic default change disappeared during normalization")
	}
}

// INV-CATALOG-EVIDENCE; TR-CATALOG-COMPARE.
func TestRuntimeCatalogRefusesPartitionAndInheritance(t *testing.T) {
	f := newDatabaseFixture(t)
	for _, shape := range []string{"partitioned", "inherits", "inherited_by"} {
		t.Run(shape, func(t *testing.T) {
			table, owner := runtimeCatalogTable(t, f)
			f.exec(t, "drop table if exists "+f.schema+".catalog_relative cascade")
			switch shape {
			case "partitioned":
				f.exec(t, "drop table "+table)
				f.exec(t, "create table "+table+" (id text primary key, amount numeric not null default 0, title text not null, optional text) partition by hash(id)")
			case "inherits":
				f.exec(t, "create table "+f.schema+".catalog_relative (optional text)")
				f.exec(t, "alter table "+table+" inherit "+f.schema+".catalog_relative")
			case "inherited_by":
				f.exec(t, "create table "+f.schema+".catalog_relative () inherits ("+table+")")
			}
			report := runtimeCatalogInspect(t, f, owner)
			if len(report.Drift) == 0 || !strings.Contains(report.Drift[0].Reason, "partitioning or inheritance") {
				t.Fatalf("nonordinary entity accepted: %+v", report)
			}
		})
	}
}

// INV-CATALOG-DEFAULT, INV-CATALOG-EXPRESSION; TR-CATALOG-COMPARE.
func TestRuntimeCatalogCompilerLiteralsMatchServerDefaults(t *testing.T) {
	f := newDatabaseFixture(t)
	table, owner := runtimeCatalogTable(t, f)
	for _, tc := range []struct{ name, typ, kind, value, sql string }{
		{"negative_integer", "numeric", "int", "-123", "-123"},
		{"large_integer", "numeric", "int", "9223372036854775808123456789", "9223372036854775808123456789"},
		{"true", "bool", "bool", "true", "true"},
		{"false", "bool", "bool", "false", "false"},
		{"negative_zero", "float8", "float64", "8000000000000000", "'-0'::float8"},
		{"one_and_half", "float8", "float64", "3ff8000000000000", "'1.5'::float8"},
		{"smallest_positive", "float8", "float64", "0000000000000001", "'5e-324'::float8"},
		{"quoted_unicode", "text", "string", "quote' å🙂 \\ end", `E'quote'' å🙂 \\ end'::text`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f.exec(t, "alter table "+table+" add column literal "+tc.typ+" not null default "+tc.sql)
			expected := runtimeCatalogExpected()
			expected[0].Columns = append(expected[0].Columns, teslrt.PgMigrationCatalogColumn{
				Name: "literal", Type: tc.typ, Default: &teslrt.PgMigrationCatalogConstant{Kind: tc.kind, Value: tc.value},
			})
			report, err := teslrt.InspectPgMigrationCatalog(f.ctx, f.conn, f.schema, owner, expected)
			if err != nil || len(report.Drift) != 0 || len(report.Missing) != 0 || len(report.Benign) != 0 {
				t.Fatalf("compiler literal differs: %+v %v", report, err)
			}
			f.exec(t, "alter table "+table+" drop column literal")
		})
	}
}

// INV-CATALOG-DEFAULT, INV-CATALOG-EXPRESSION; TR-CATALOG-COMPARE.
func TestRuntimeCatalogPreservesPreexistingTemporaryObjects(t *testing.T) {
	f := newDatabaseFixture(t)
	table, owner := runtimeCatalogTable(t, f)
	f.exec(t, "create temporary table tesl_constant_5 (secret text)")
	f.exec(t, "insert into tesl_constant_5 values ('caller-owned')")
	f.exec(t, "alter table "+table+" add column extra text default 'safe'")
	report, err := teslrt.InspectPgMigrationCatalog(f.ctx, f.conn, f.schema, owner, runtimeCatalogExpected())
	if err != nil || len(report.Drift) != 0 || len(report.Benign) != 1 {
		t.Fatalf("extra-column probe collided with caller state: %+v %v", report, err)
	}
	var value string
	if err = f.conn.QueryRow(f.ctx, "select secret from tesl_constant_5").Scan(&value); err != nil || value != "caller-owned" {
		t.Fatalf("probe changed caller's temporary table: %q %v", value, err)
	}
}

// INV-CATALOG-DEFAULT, INV-CATALOG-EXPRESSION; TR-CATALOG-COMPARE.
func TestRuntimeCatalogCanonicalizesAndRestoresRenderingSettings(t *testing.T) {
	f := newDatabaseFixture(t)
	table, owner := runtimeCatalogTable(t, f)
	f.exec(t, "alter table "+table+` add column day date default '2020-02-03',
 add column instant timestamptz default '2020-02-03 04:05:06+00',
 add column duration interval default '2 days 03:04:05', add column raw bytea default '\x00ff'`)
	before := runtimeCatalogInspect(t, f, owner)
	if len(before.Drift) != 0 || len(before.Benign) != 4 {
		t.Fatalf("supported scalar defaults refused: %+v", before)
	}
	f.exec(t, `set DateStyle='SQL, DMY'; set IntervalStyle='sql_standard'; set TimeZone='Asia/Tokyo';
set standard_conforming_strings=off; set extra_float_digits=-3; set bytea_output='escape'`)
	settings := func() string {
		t.Helper()
		var value string
		if err := f.conn.QueryRow(f.ctx, `select string_agg(name||'='||setting, ',' order by name) from pg_settings
where name in ('DateStyle','IntervalStyle','TimeZone','standard_conforming_strings','extra_float_digits','bytea_output')`).Scan(&value); err != nil {
			t.Fatal(err)
		}
		return value
	}
	callerSettings := settings()
	after := runtimeCatalogInspect(t, f, owner)
	if len(after.Drift) != 0 || after.Fingerprint != before.Fingerprint || settings() != callerSettings {
		t.Fatalf("session rendering changed identity or leaked settings: before=%s after=%+v", before.Fingerprint, after)
	}
}
