package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func pgCatalogTestReader(t *testing.T, f *pgControlTestFixture) *pgx.Conn {
	t.Helper()
	name := f.roles.Worker + "_reader"
	for _, sql := range []string{
		"create role " + quoteIdentifier(name) + " login",
		"revoke temporary on database " + quoteIdentifier(f.installer.Config().Database) + " from public",
		"grant usage on schema " + quoteIdentifier(f.namespace) + " to " + quoteIdentifier(name),
		"grant select on all tables in schema " + quoteIdentifier(f.namespace) + " to " + quoteIdentifier(name),
	} {
		if _, err := f.installer.Exec(f.ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	config := f.installer.Config().Copy()
	config.User = name
	reader, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		_ = reader.Close(ctx)
		_, _ = f.installer.Exec(ctx, "drop owned by "+quoteIdentifier(name)+"; drop role "+quoteIdentifier(name))
	})
	var temporary, create bool
	if err := reader.QueryRow(f.ctx, `select pg_catalog.has_database_privilege(current_user,current_database(),'TEMP'),
 pg_catalog.has_schema_privilege(current_user,$1,'CREATE')`, f.namespace).Scan(&temporary, &create); err != nil || temporary || create {
		t.Fatalf("catalog reader has DDL privileges: temp=%v create=%v err=%v", temporary, create, err)
	}
	return reader
}

func pgReadOnlyCatalogTestTransaction(t *testing.T, f *pgControlTestFixture, reader *pgx.Conn, inspect func(pgx.Tx)) {
	t.Helper()
	tx, err := reader.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if err := pgControlSession(f.ctx, tx); err != nil {
		t.Fatal(err)
	}
	inspect(tx)
	var temporary uint32
	if err := tx.QueryRow(f.ctx, "select pg_catalog.pg_my_temp_schema()").Scan(&temporary); err != nil || temporary != 0 {
		t.Fatalf("read-only inspection created a temporary namespace: %d %v", temporary, err)
	}
}

func pgExpectedCatalogLiteralTable() PgMigrationCatalogTable {
	table := PgMigrationCatalogTable{Name: "literal_shapes", Columns: []PgMigrationCatalogColumn{{Name: "id", Type: "text", PrimaryKey: true}}}
	add := func(typ, kind, value string) {
		table.Columns = append(table.Columns, PgMigrationCatalogColumn{Name: fmt.Sprintf("c%d", len(table.Columns)), Type: typ,
			Default: &PgMigrationCatalogConstant{Kind: kind, Value: value}})
	}
	for _, value := range []string{"0", "1", "-1", "2147483647", "2147483648", "-2147483648", "-2147483649",
		"9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809", strings.Repeat("9", 500)} {
		add("numeric", "int", value)
	}
	for _, bits := range []string{"0000000000000000", "8000000000000000", "0000000000000001", "7fefffffffffffff",
		"3ff8000000000000", "bff8000000000000", "3c6c779a0d0dbfd9"} {
		add("float8", "float64", bits)
	}
	for _, value := range []string{"", "ordinary", "雪🙂'\\", "line\ncarriage\rtab\t", "'::text); select 1; --"} {
		add("text", "string", value)
	}
	add("bool", "bool", "true")
	add("bool", "bool", "false")
	for _, typ := range []string{"numeric", "float8", "text", "bool", "int4", "int8", "jsonb"} {
		name := "type_" + typ
		table.Columns = append(table.Columns, PgMigrationCatalogColumn{Name: name, Type: typ, Nullable: true})
		table.Indexes = append(table.Indexes, PgMigrationCatalogIndex{Name: "by_" + typ, Columns: []string{name}, Unique: typ == "text"})
	}
	table.Indexes = append(table.Indexes, PgMigrationCatalogIndex{Name: "by_compound", Columns: []string{"type_text", "type_int4", "type_jsonb"}})
	return table
}

func TestPgMigrationControlReadOnlyEntityExpectationsMatchServer(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	want := pgExpectedCatalogLiteralTable()
	tx, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if err := pgControlSession(f.ctx, tx); err != nil {
		t.Fatal(err)
	}
	metadata, err := pgReadCatalogExpectations(f.ctx, tx)
	if err != nil {
		t.Fatal(err)
	}
	probe, err := pgCreateMigrationProbe(f.ctx, tx, "independent_expected_probe", want)
	if err != nil {
		t.Fatal(err)
	}
	expected, err := metadata.entity(f.ctx, tx, want, f.roles.Worker)
	if err != nil {
		t.Fatal(err)
	}
	probe.Owner, probe.Persistence = f.roles.Worker, "p"
	if !reflect.DeepEqual(pgCanonicalMigrationTable(probe), pgCanonicalMigrationTable(expected)) {
		actualJSON, _ := json.MarshalIndent(pgCanonicalMigrationTable(probe), "", " ")
		wantedJSON, _ := json.MarshalIndent(pgCanonicalMigrationTable(expected), "", " ")
		t.Fatalf("read-only expectation differs from server DDL\nactual: %s\nexpected: %s", actualJSON, wantedJSON)
	}
	if err := tx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	// Create real owned storage separately, then remove all reader DDL authority.
	columns := make([]string, len(want.Columns))
	for i, c := range want.Columns {
		columns[i], err = pgMigrationColumnSQL(c)
		if err != nil {
			t.Fatal(err)
		}
	}
	f.call(t, "create table "+pgx.Identifier{f.namespace, want.Name}.Sanitize()+" ("+strings.Join(columns, ",")+")")
	for _, index := range want.Indexes {
		keys := make([]string, len(index.Columns))
		for i, key := range index.Columns {
			keys[i] = quoteIdentifier(key)
		}
		unique := ""
		if index.Unique {
			unique = "unique "
		}
		f.call(t, "create "+unique+"index "+quoteIdentifier(index.Name)+" on "+pgx.Identifier{f.namespace, want.Name}.Sanitize()+" ("+strings.Join(keys, ",")+")")
	}
	old, err := InspectPgMigrationCatalog(f.ctx, f.installer, f.namespace, f.roles.Worker, []PgMigrationCatalogTable{want})
	if err != nil || len(old.Drift) != 0 || len(old.Missing) != 0 {
		t.Fatalf("independent catalog check: %+v %v", old, err)
	}
	reader := pgCatalogTestReader(t, f)
	pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
		got, err := pgInspectMigrationCatalogReadOnlyInTx(f.ctx, tx, f.namespace, f.roles.Worker, []PgMigrationCatalogTable{want})
		if err != nil || !reflect.DeepEqual(old, got) {
			t.Fatalf("read-only catalog report differs: %+v want %+v err %v", got, old, err)
		}
	})
}

func TestPgMigrationControlReadOnlyExtraColumnsMatchAssignment(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	cases := []struct {
		name, declaration string
		benign            bool
	}{
		{"nullable", "text", true}, {"required", "text not null", false},
		{"null", "text default null", true}, {"required_null", "text not null default null", false},
		{"varchar_exact", "varchar(3) not null default '雪🙂a'", true},
		{"varchar_long", "varchar(3) not null default '雪🙂ab'", false},
		{"varchar_spaces", "varchar(3) not null default '雪🙂a   '", true},
		{"varchar_tab", "varchar(3) not null default E'abc\\t'", false},
		{"char_long", "char(3) not null default 'abcd'", false},
		{"char_spaces", "char(3) not null default 'abc   '", true},
		{"numeric_fit", "numeric(3,1) not null default 98.95", true},
		{"numeric_round_overflow", "numeric(3,1) not null default 99.95", false},
		{"numeric_negative_scale", "numeric not null default -9223372036854775809", true},
		{"boolean", "bool not null default false", true},
		{"integer", "int4 not null default -2147483648", true},
		{"float", "float8 not null default '-0'::float8", true},
		{"jsonb", "jsonb not null default '{\"tag\":\"Old\"}'::jsonb", true},
		{"date", "date not null default '2020-01-02'::date", true},
		{"timestamp", "timestamptz not null default '2020-01-02T03:04:05Z'::timestamptz", true},
		{"computed", "text default current_user", false},
		{"generated", "int4 generated always as (length(id)) stored", false},
		{"collation", "text collate pg_catalog.\"C\"", false},
	}
	for i, tc := range cases {
		name := fmt.Sprintf("extras_%d", i)
		f.call(t, "create table "+pgx.Identifier{f.namespace, name}.Sanitize()+" (id text primary key, extra "+tc.declaration+")")
	}
	reader := pgCatalogTestReader(t, f)
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			want := []PgMigrationCatalogTable{{Name: fmt.Sprintf("extras_%d", i), Columns: []PgMigrationCatalogColumn{{Name: "id", Type: "text", PrimaryKey: true}}}}
			old, err := InspectPgMigrationCatalog(f.ctx, f.installer, f.namespace, f.roles.Worker, want)
			if err != nil || (len(old.Drift) == 0) != tc.benign || len(old.Missing) != 0 {
				t.Fatalf("assignment-probe baseline: %+v %v", old, err)
			}
			pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
				got, err := pgInspectMigrationCatalogReadOnlyInTx(f.ctx, tx, f.namespace, f.roles.Worker, want)
				if err != nil || !reflect.DeepEqual(old, got) {
					t.Fatalf("read-only extra-column report differs: %+v want %+v err %v", got, old, err)
				}
			})
		})
	}
}

func TestPgMigrationControlReadOnlyCatalogRefusesDriftWithoutEvaluatingDefaults(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.call(t, "create sequence "+pgx.Identifier{f.namespace, "forbidden_default"}.Sanitize())
	want := []PgMigrationCatalogTable{{Name: "rows", Columns: []PgMigrationCatalogColumn{
		{Name: "id", Type: "text", PrimaryKey: true}, {Name: "amount", Type: "numeric", Nullable: true},
	}}}
	f.call(t, "create table "+pgx.Identifier{f.namespace, "rows"}.Sanitize()+" (id text primary key, amount numeric, extra bigint default nextval('"+
		pgx.Identifier{f.namespace, "forbidden_default"}.Sanitize()+"'::regclass))")
	reader := pgCatalogTestReader(t, f)
	for _, sql := range []string{
		"select 1", // Computing extra default is already drift.
		"alter table " + pgx.Identifier{f.namespace, "rows"}.Sanitize() + " alter amount set default 12",
		"alter table " + pgx.Identifier{f.namespace, "rows"}.Sanitize() + " alter amount set not null",
		"create index unrecorded on " + pgx.Identifier{f.namespace, "rows"}.Sanitize() + " (amount)",
	} {
		f.call(t, sql)
		old, err := InspectPgMigrationCatalog(f.ctx, f.installer, f.namespace, f.roles.Worker, want)
		if err != nil || len(old.Drift) == 0 {
			t.Fatalf("drift baseline: %+v %v", old, err)
		}
		pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
			got, err := pgInspectMigrationCatalogReadOnlyInTx(f.ctx, tx, f.namespace, f.roles.Worker, want)
			if err != nil || !reflect.DeepEqual(old, got) {
				t.Fatalf("read-only drift report differs: %+v want %+v err %v", got, old, err)
			}
		})
	}
	var called bool
	if err := f.installer.QueryRow(f.ctx, "select is_called from "+pgx.Identifier{f.namespace, "forbidden_default"}.Sanitize()).Scan(&called); err != nil || called {
		t.Fatalf("catalog inspection evaluated a computing default: %v %v", called, err)
	}
}
