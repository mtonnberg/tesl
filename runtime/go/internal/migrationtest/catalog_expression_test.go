package migrationtest

import (
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

type catalogExpression struct {
	Text, Collation string
}

// canonicalCatalogExpression asks this server to parse and deparse an expected
// expression in the same column/type/collation context as the live table. The
// temporary object and any changes to the connection settings are rolled back.
// This is an independent SQL oracle, not the production catalog verifier.
func canonicalCatalogExpression(t *testing.T, f *databaseFixture, kind, expression, collation string) catalogExpression {
	t.Helper()
	tx, err := f.conn.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(f.ctx) }()
	if _, err = tx.Exec(f.ctx, "set local search_path = ''; set local standard_conforming_strings = on"); err != nil {
		t.Fatal(err)
	}
	definition := `id int, amount numeric, title text collate ` + collation
	var query string
	switch kind {
	case "check":
		definition += ", constraint expected_check check (" + expression + ")"
		query = "select pg_get_expr(conbin,conrelid) from pg_constraint where conrelid='pg_temp.expected_catalog'::regclass and conname='expected_check'"
	case "default":
		definition += ", result text default " + expression
		query = "select pg_get_expr(adbin,adrelid) from pg_attrdef where adrelid='pg_temp.expected_catalog'::regclass"
	case "generated":
		definition += ", result text generated always as (" + expression + ") stored"
		query = "select pg_get_expr(adbin,adrelid) from pg_attrdef where adrelid='pg_temp.expected_catalog'::regclass"
	case "index":
		query = "select pg_get_expr(indexprs,indrelid) from pg_index where indexrelid='pg_temp.expected_index'::regclass"
	case "predicate":
		query = "select pg_get_expr(indpred,indrelid) from pg_index where indexrelid='pg_temp.expected_index'::regclass"
	default:
		t.Fatalf("unknown expression kind %q", kind)
	}
	if _, err = tx.Exec(f.ctx, "create temporary table expected_catalog ("+definition+")"); err != nil {
		t.Fatal(err)
	}
	if kind == "index" || kind == "predicate" {
		index := "create index expected_index on pg_temp.expected_catalog "
		if kind == "index" {
			index += "((" + expression + "))"
		} else {
			index += "(id) where " + expression
		}
		if _, err = tx.Exec(f.ctx, index); err != nil {
			t.Fatal(err)
		}
	}
	var result catalogExpression
	if err = tx.QueryRow(f.ctx, query).Scan(&result.Text); err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(f.ctx, "select attcollation::regcollation::text from pg_attribute where attrelid='pg_temp.expected_catalog'::regclass and attname='title'").Scan(&result.Collation); err != nil {
		t.Fatal(err)
	}
	return result
}

// INV-CATALOG-EXPRESSION; TR-CATALOG-COMPARE.
func TestPostgresCatalogExpressionsUseOneServerAndColumnContext(t *testing.T) {
	f := newDatabaseFixture(t)
	for _, tc := range []struct {
		kind, expected, equivalent, changed string
	}{
		{"check", "amount >= 0", "(((amount OPERATOR(pg_catalog.>=) CAST(0 AS numeric))))", "amount > 0"},
		{"default", "'example'::text", "CAST(('example') AS pg_catalog.text)", "'different'::text"},
		{"generated", "lower(title)", "pg_catalog.LOWER(((title)))", "upper(title)"},
		{"index", "lower(title)", "pg_catalog.lower((title))", "upper(title)"},
		{"predicate", "amount >= 0", "((amount) OPERATOR(pg_catalog.>=) (0::numeric))", "amount >= 1"},
	} {
		t.Run(tc.kind, func(t *testing.T) {
			expected := canonicalCatalogExpression(t, f, tc.kind, tc.expected, `pg_catalog."C"`)
			equivalent := canonicalCatalogExpression(t, f, tc.kind, tc.equivalent, `pg_catalog."C"`)
			changed := canonicalCatalogExpression(t, f, tc.kind, tc.changed, `pg_catalog."C"`)
			if expected != equivalent || expected == changed {
				t.Fatalf("server comparison: expected=%+v equivalent=%+v changed=%+v", expected, equivalent, changed)
			}
		})
	}
	// Identical deparsed text does not prove identical column semantics. Column
	// collation is a separate catalog input and the expected table must carry it.
	c := canonicalCatalogExpression(t, f, "check", "title > 'a'", `pg_catalog."C"`)
	p := canonicalCatalogExpression(t, f, "check", "title > 'a'", `pg_catalog."POSIX"`)
	if c.Text != p.Text || c.Collation == p.Collation {
		t.Fatalf("deparsed text hid column collation: C=%+v POSIX=%+v", c, p)
	}
	var leaked bool
	if err := f.conn.QueryRow(f.ctx, "select to_regclass('pg_temp.expected_catalog') is not null or to_regclass('pg_temp.expected_index') is not null").Scan(&leaked); err != nil || leaked {
		t.Fatalf("comparison leaked temporary objects: %t %v", leaked, err)
	}
}

// INV-CATALOG-DEFAULT; TR-CATALOG-COMPARE.
func TestPostgresLiteralCastDefaultCanExecuteUserCode(t *testing.T) {
	f := newDatabaseFixture(t)
	// PostgreSQL deparses this volatile cast with ordinary :: syntax. A text
	// recognizer accepting an arbitrary literal under casts would call it benign,
	// even though omitting this nullable extra column executes a user function.
	f.exec(t, "create sequence "+f.schema+".cast_calls")
	f.exec(t, "create type "+f.schema+".cast_value as (counter bigint)")
	f.exec(t, fmt.Sprintf(`create function %s.cast_from_integer(integer) returns %s.cast_value language sql volatile as
		' select row(nextval(''%s.cast_calls''))::%s.cast_value '`, f.schema, f.schema, f.schema, f.schema))
	f.exec(t, fmt.Sprintf("create cast (integer as %s.cast_value) with function %s.cast_from_integer(integer)", f.schema, f.schema))
	f.exec(t, fmt.Sprintf("create table %s.cast_defaults(id int primary key, extra %s.cast_value default (0::%s.cast_value))", f.schema, f.schema, f.schema))
	var deparsed string
	f.exec(t, "set search_path = ''")
	if err := f.conn.QueryRow(f.ctx, "select pg_get_expr(adbin,adrelid) from pg_attrdef where adrelid=$1::regclass", f.schema+".cast_defaults").Scan(&deparsed); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(deparsed, "cast_from_integer") || !strings.Contains(deparsed, "::") {
		t.Fatalf("fixture did not expose a cast-only deparse: %s", deparsed)
	}
	if literalCatalogDefault(deparsed) {
		t.Fatalf("side-effecting cast classified as benign: %s", deparsed)
	}
	f.exec(t, "insert into "+f.schema+".cast_defaults(id) values (1),(2)")
	rows, err := f.conn.Query(f.ctx, "select (extra).counter from "+f.schema+".cast_defaults order by id")
	if err != nil {
		t.Fatal(err)
	}
	values, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil || len(values) != 2 || values[0] != 1 || values[1] != 2 {
		t.Fatalf("cast side-effect witness: %v %v (deparse %q)", values, err, deparsed)
	}
}

// INV-CATALOG-DEFAULT; TR-CATALOG-COMPARE.
func TestPostgresDefaultClassificationUsesStoredExpressions(t *testing.T) {
	f := newDatabaseFixture(t)
	f.exec(t, "set search_path = ''; set standard_conforming_strings = on")
	f.exec(t, "create sequence "+f.schema+".default_calls")
	f.exec(t, "create function "+f.schema+".default_value() returns text language sql volatile as 'select ''value''::text'")
	f.exec(t, "create domain "+f.schema+".default_domain as text check (value <> 'forbidden')")
	for _, tc := range []struct {
		name, typ, expression string
		literal               bool
	}{
		{"integer", "integer", "0", true},
		{"negative", "integer", "-1", true},
		{"numeric", "numeric", "-1200.5", true},
		{"boolean", "boolean", "true", true},
		{"null", "text", "NULL", true},
		{"empty", "text", "''::text", true},
		{"quote", "text", "'quote''end'::text", true},
		{"backslash", "text", `E'back\\slash'`, true},
		{"json", "jsonb", "'{}'::jsonb", true},
		{"date", "date", "'2020-01-01'::date", true},
		{"bytea", "bytea", `'\x00'::bytea`, true},
		{"now", "timestamptz", "now()", false},
		{"sequence", "bigint", "nextval('" + f.schema + ".default_calls')", false},
		{"uuid", "uuid", "gen_random_uuid()", false},
		{"immutable_call", "text", "lower('X')", false},
		{"operator", "integer", "0 + 1", false},
		{"user_function", "text", f.schema + ".default_value()", false},
		{"user_domain", f.schema + ".default_domain", "'x'", false},
		{"time_cast", "timestamptz", "('now'::text)::timestamptz", false},
		{"possibly_failing_cast", "smallint", "1000000::smallint", false},
		{"typmod_failure", "varchar(2)", "'too long'", false},
		{"typmod_success", "varchar(2)", "'ok'", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tx, err := f.conn.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(f.ctx) }()
			if _, err = tx.Exec(f.ctx, "create temporary table classified_default (id int, extra "+tc.typ+" default "+tc.expression+")"); err != nil {
				t.Fatal(err)
			}
			var deparsed string
			var typeNamespace, typeName, typeKind string
			var required, generated, identity bool
			if err = tx.QueryRow(f.ctx, `select coalesce(pg_get_expr(d.adbin,d.adrelid),'NULL'), a.attnotnull, a.attgenerated<>'', a.attidentity<>'',
				n.nspname, format_type(a.atttypid,null), typ.typtype::text
				from pg_attribute a join pg_type typ on typ.oid=a.atttypid join pg_namespace n on n.oid=typ.typnamespace
				left join pg_attrdef d on (d.adrelid,d.adnum)=(a.attrelid,a.attnum)
				where a.attrelid='pg_temp.classified_default'::regclass and a.attname='extra'`).Scan(&deparsed, &required, &generated, &identity, &typeNamespace, &typeName, &typeKind); err != nil {
				t.Fatal(err)
			}
			benign := !required && !generated && !identity && typeKind == "b" && typeNamespace == "pg_catalog" && constantCatalogType(typeName) && literalCatalogDefault(deparsed)
			if benign {
				// This is the temporary comparison table, never a live application
				// table. Only recognized constants in supported scalar types may be
				// evaluated; checking their typmod can still reject an invalid value.
				if _, err = tx.Exec(f.ctx, "savepoint constant_fit"); err != nil {
					t.Fatal(err)
				}
				_, err = tx.Exec(f.ctx, "insert into pg_temp.classified_default(id) values (1),(2)")
				benign = err == nil
				if _, err = tx.Exec(f.ctx, "rollback to savepoint constant_fit"); err != nil {
					t.Fatal(err)
				}
			}
			if benign != tc.literal {
				t.Fatalf("stored default %q: benign=%t, want %t (type=%s/%s/%s notnull=%t generated=%t identity=%t)", deparsed, benign, tc.literal, typeNamespace, typeName, typeKind, required, generated, identity)
			}
			// Pinned built-ins have no dependency row. Their absence must never be
			// used to infer that a default has no calls or side effects.
			if tc.name == "now" || tc.name == "user_function" {
				function := "pg_catalog.now()"
				if tc.name == "user_function" {
					function = f.schema + ".default_value()"
				}
				var dependency bool
				err = tx.QueryRow(f.ctx, `select exists(select 1 from pg_depend dep join pg_attrdef d on dep.objid=d.oid
					where dep.classid='pg_attrdef'::regclass and d.adrelid='pg_temp.classified_default'::regclass
					and dep.refclassid='pg_proc'::regclass and dep.refobjid=$1::regprocedure)`, function).Scan(&dependency)
				if err != nil || dependency != (tc.name == "user_function") {
					t.Fatalf("dependency witness for %s: %t %v", tc.name, dependency, err)
				}
			}
		})
	}
	var called bool
	if err := f.conn.QueryRow(f.ctx, "select is_called from "+f.schema+".default_calls").Scan(&called); err != nil || called {
		t.Fatalf("classification evaluated a computing default: %t %v", called, err)
	}
}
