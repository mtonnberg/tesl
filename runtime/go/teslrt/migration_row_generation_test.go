package teslrt

import (
	"context"
	"math"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestMigrationRowGenerationDescriptor(t *testing.T) {
	sources := []string{"payload", "author"}
	rule, err := pgNewRowGenerationInvalidation("notes_app", "notes", 3, 4, sources)
	if err != nil {
		t.Fatal(err)
	}
	before, err := rule.statements()
	if err != nil {
		t.Fatal(err)
	}
	sources[0] = "changed"
	ordered, err := pgNewRowGenerationInvalidation("notes_app", "notes", 3, 4, []string{"author", "payload"})
	if err != nil {
		t.Fatal(err)
	}
	after, err := ordered.statements()
	if err != nil || !reflect.DeepEqual(before, after) || rule.digest() != ordered.digest() {
		t.Fatalf("caller mutation or field ordering changes a checked descriptor: %v", err)
	}
	for _, tc := range []struct {
		name, namespace, table string
		previous, target       int
		sources                []string
	}{
		{"missing-namespace", "", "notes", 3, 4, []string{"a"}},
		{"invalid-table", "notes_app", "bad\x00", 3, 4, []string{"a"}},
		{"long-table", "notes_app", strings.Repeat("x", 64), 3, 4, []string{"a"}},
		{"initial-zero", "notes_app", "notes", 0, 1, []string{"a"}},
		{"skip-generation", "notes_app", "notes", 3, 5, []string{"a"}},
		{"no-transition", "notes_app", "notes", 3, 3, []string{"a"}},
		{"smallint-overflow", "notes_app", "notes", 32767, 32768, []string{"a"}},
		{"integer-wraparound", "notes_app", "notes", math.MaxInt, math.MinInt, []string{"a"}},
		{"no-sources", "notes_app", "notes", 3, 4, nil},
		{"marker-is-not-a-source", "notes_app", "notes", 3, 4, []string{"_tesl_v"}},
		{"duplicate-source", "notes_app", "notes", 3, 4, []string{"a", "a"}},
		{"invalid-source", "notes_app", "notes", 3, 4, []string{"bad\x00"}},
		{"too-many-sources", "notes_app", "notes", 3, 4, make([]string, 1600)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := pgNewRowGenerationInvalidation(tc.namespace, tc.table, tc.previous, tc.target, tc.sources); err == nil {
				t.Fatal("accepted an invalid invalidation descriptor")
			}
		})
	}
	if sql, err := (pgRowGenerationInvalidation{}).statements(); err == nil || sql != nil {
		t.Fatal("zero descriptor emitted executable SQL")
	}
	for _, tc := range []struct {
		namespace, table string
		previous, target int
		sources          []string
		sameWriter       bool
	}{
		{"notes_app", "notes", 4, 5, []string{"author", "payload"}, true},
		{"notes_app", "notes", 3, 4, []string{"author"}, true},
		{"other_app", "notes", 3, 4, []string{"author", "payload"}, false},
		{"notes_app", "other", 3, 4, []string{"author", "payload"}, false},
	} {
		other, err := pgNewRowGenerationInvalidation(tc.namespace, tc.table, tc.previous, tc.target, tc.sources)
		if err != nil || other.digest() == rule.digest() || (other.writerSetting() == rule.writerSetting()) != tc.sameWriter {
			t.Fatalf("descriptor or writer identity conflates different contracts: %+v %v", tc, err)
		}
	}
}

func pgInstallRowGenerationTestRule(t *testing.T, f *pgControlTestFixture, table string, previous, target int, sources []string) pgRowGenerationInvalidation {
	t.Helper()
	rule, err := pgNewRowGenerationInvalidation(f.namespace, table, previous, target, sources)
	if err != nil {
		t.Fatal(err)
	}
	statements, err := rule.statements()
	if err != nil {
		t.Fatal(err)
	}
	tx, err := f.worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	for _, statement := range statements {
		if _, err := tx.Exec(f.ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	return rule
}

func TestPgMigrationRowGenerationOldAndNewWriters(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.call(t, `create table notes_app.notes(id text primary key,author text,owner text,payload jsonb not null,
 unrelated boolean not null default false,_tesl_v smallint not null default 3)`)
	rule := pgInstallRowGenerationTestRule(t, f, "notes", 3, 4, []string{"author", "payload"})
	// NULL is a valid fully migrated value, independent of the marker. An old
	// insert still receives the predecessor generation, even after expansion.
	f.call(t, `insert into notes_app.notes(id,author,owner,payload,_tesl_v) values('row',null,null,'{"a":1,"b":2}',4)`)
	f.call(t, `insert into notes_app.notes(id,payload) values('old-insert','{}')`)
	check := func(id string, expected int) {
		t.Helper()
		var generation int
		if err := f.worker.QueryRow(f.ctx, "select _tesl_v from notes_app.notes where id=$1", id).Scan(&generation); err != nil || generation != expected {
			t.Fatalf("%s generation=%d expected=%d: %v", id, generation, expected, err)
		}
	}
	check("old-insert", 3)
	f.call(t, `update notes_app.notes set unrelated=true,author=null,payload='{"b":2,"a":1}' where id='row'`)
	check("row", 4) // SQL JSONB equality and NULL equality, not source spelling.
	f.call(t, `update notes_app.notes set author='changed' where id='row'`)
	check("row", 3)
	f.call(t, `update notes_app.notes set _tesl_v=2,author=null where id='row'`)
	check("row", 2) // Lower NEW stamps are never raised by a later trigger.
	for _, writer := range []string{"3", "4", "5"} {
		tx, err := f.worker.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(f.ctx, "select pg_catalog.set_config($1,$2,true)", rule.writerSetting(), writer); err != nil {
			t.Fatal(err)
		}
		// Simulate a complete materialization. The trigger's only authority is
		// invalidation; proving this writer produced all fields is the emitter's job.
		if _, err := tx.Exec(f.ctx, `update notes_app.notes set author=$1,owner=$1,payload='{}',_tesl_v=4 where id='row'`, writer); err != nil {
			t.Fatal(err)
		}
		if err := tx.Commit(f.ctx); err != nil {
			t.Fatal(err)
		}
		expected := 4
		if writer == "3" {
			expected = 3
		}
		check("row", expected)
		// The same physical connection is reused by an old writer immediately.
		f.call(t, `update notes_app.notes set payload='{"old":true}' where id='row'`)
		check("row", 3)
	}
	// A rollback also clears the writer setting. Malformed values refuse the
	// statement rather than suppressing invalidation or changing stored bytes.
	tx, err := f.worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, "select pg_catalog.set_config($1,'4',true)", rule.writerSetting()); err != nil {
		t.Fatal(err)
	}
	if err := tx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	f.call(t, `update notes_app.notes set _tesl_v=4 where id='row'`)
	f.call(t, `update notes_app.notes set author=null where id='row'`)
	check("row", 3)
	tx, err = f.worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, "select pg_catalog.set_config($1,'garbage',true)", rule.writerSetting()); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, `update notes_app.notes set author='not-committed' where id='row'`); err == nil {
		t.Fatal("malformed writer generation bypassed invalidation")
	}
	if err := tx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	var author *string
	if err := f.worker.QueryRow(f.ctx, "select author from notes_app.notes where id='row'").Scan(&author); err != nil || author != nil {
		t.Fatalf("failed statement changed source bytes: %v %v", author, err)
	}
}

func TestPgMigrationRowGenerationCoexistingTriggers(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.call(t, `create table notes_app.notes(id text primary key,source text not null,_tesl_v smallint not null default 2)`)
	rules := []pgRowGenerationInvalidation{
		pgInstallRowGenerationTestRule(t, f, "notes", 2, 3, []string{"source"}),
		pgInstallRowGenerationTestRule(t, f, "notes", 3, 4, []string{"source"}),
	}
	if rules[0].writerSetting() != rules[1].writerSetting() {
		t.Fatal("coexisting triggers do not share the entity writer generation")
	}
	f.call(t, "insert into notes_app.notes values('row','start',4)")
	// Exercise both PostgreSQL trigger name orders: lowering OLD rather than NEW
	// would silently raise the earlier transition's marker in one of them.
	for _, reverse := range []bool{false, true} {
		if reverse {
			f.call(t, "alter trigger "+pgx.Identifier{rules[0].functionName()}.Sanitize()+" on notes_app.notes rename to z_last")
			f.call(t, "alter trigger "+pgx.Identifier{rules[1].functionName()}.Sanitize()+" on notes_app.notes rename to a_first")
		} else {
			f.call(t, "alter trigger "+pgx.Identifier{rules[0].functionName()}.Sanitize()+" on notes_app.notes rename to a_first")
			f.call(t, "alter trigger "+pgx.Identifier{rules[1].functionName()}.Sanitize()+" on notes_app.notes rename to z_last")
		}
		for _, tc := range []struct {
			writer string
			want   int
		}{{"", 2}, {"2", 2}, {"3", 3}, {"4", 4}, {"5", 4}} {
			tx, err := f.worker.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := tx.Exec(f.ctx, "select pg_catalog.set_config($1,$2,true)", rules[0].writerSetting(), tc.writer); err != nil {
				t.Fatal(err)
			}
			var generation int
			err = tx.QueryRow(f.ctx, "update notes_app.notes set source=source||'x',_tesl_v=4 returning _tesl_v").Scan(&generation)
			if rollbackErr := tx.Rollback(f.ctx); rollbackErr != nil {
				t.Fatal(rollbackErr)
			}
			if err != nil || generation != tc.want {
				t.Fatalf("coexisting triggers reverse=%t writer=%q result=%d want=%d: %v", reverse, tc.writer, generation, tc.want, err)
			}
		}
		if !reverse {
			f.call(t, "alter trigger a_first on notes_app.notes rename to "+pgx.Identifier{rules[0].functionName()}.Sanitize())
			f.call(t, "alter trigger z_last on notes_app.notes rename to "+pgx.Identifier{rules[1].functionName()}.Sanitize())
		}
	}
}

func TestPgMigrationRowGenerationQuotedNames(t *testing.T) {
	f := pgNewControlTest(t)
	f.namespace = "notes '$tesl_row$\"\\雪"
	f.install(t, 1)
	table, source := "table '$tesl_row$\"\\", "source '$tesl_row$\"\\"
	qualified := pgx.Identifier{f.namespace, table}.Sanitize()
	column := pgx.Identifier{source}.Sanitize()
	f.call(t, "create table "+qualified+"(id text primary key,"+column+" text,_tesl_v smallint not null default 1)")
	// Generated DDL must be safe with either PostgreSQL string-literal mode.
	f.call(t, "set standard_conforming_strings=off")
	pgInstallRowGenerationTestRule(t, f, table, 1, 2, []string{source})
	f.call(t, "set standard_conforming_strings=on")
	f.call(t, "insert into "+qualified+" values('row','before',2)")
	var generation int
	if err := f.worker.QueryRow(f.ctx, "update "+qualified+" set "+column+"=$1 returning _tesl_v", "after").Scan(&generation); err != nil || generation != 1 {
		t.Fatalf("quoted source did not invalidate exact entity: %d %v", generation, err)
	}
}

func TestPgMigrationRowGenerationVerifiesActualTrigger(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.call(t, "create table notes_app.notes(id text primary key,source text,_tesl_v smallint not null default 1)")
	rule := pgInstallRowGenerationTestRule(t, f, "notes", 1, 2, []string{"source"})
	observe := func(t *testing.T, tx pgx.Tx, table string) pgCatalogTrigger {
		t.Helper()
		if err := pgControlSession(f.ctx, tx); err != nil {
			t.Fatal(err)
		}
		actual, err := pgReadMigrationTable(f.ctx, tx, f.namespace, table)
		if err != nil || actual == nil || len(actual.TriggerDefinitions) != 1 {
			t.Fatalf("missing exact trigger observation: %+v %v", actual, err)
		}
		return actual.TriggerDefinitions[0]
	}
	reader := pgCatalogTestReader(t, f)
	pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
		actual := observe(t, tx, "notes")
		if err := rule.checkTrigger(actual, f.roles.Worker); err != nil {
			t.Fatalf("generated trigger fails independent read-only verification: %v\n%+v", err, actual)
		}
		other, err := pgNewRowGenerationInvalidation(f.namespace, "other", 1, 2, []string{"source"})
		if err != nil || other.checkTrigger(actual, f.roles.Worker) == nil {
			t.Fatal("descriptor accepted another table's trigger")
		}
		if err := rule.checkTrigger(actual, f.roles.Owner); err == nil {
			t.Fatal("descriptor accepted another function owner")
		}
	})
	function := pgx.Identifier{f.namespace, rule.functionName()}.Sanitize() + "()"
	trigger := pgx.Identifier{rule.functionName()}.Sanitize()
	for _, tc := range []struct {
		name, sql string
	}{
		{"disabled", "alter table notes_app.notes disable trigger " + trigger},
		{"always", "alter table notes_app.notes enable always trigger " + trigger},
		{"replica-only", "alter table notes_app.notes enable replica trigger " + trigger},
		{"changed-body", "create or replace function " + function + " returns trigger language plpgsql as 'begin return old; end;'"},
		{"changed-security", "alter function " + function + " security definer"},
		{"changed-strictness", "alter function " + function + " strict"},
		{"changed-volatility", "alter function " + function + " immutable"},
		{"changed-parallelism", "alter function " + function + " parallel safe"},
		{"changed-cost", "alter function " + function + " cost 1"},
		{"changed-configuration", "alter function " + function + " set search_path=public"},
		{"changed-owner", "alter function " + function + " owner to " + pgx.Identifier{f.roles.Owner}.Sanitize()},
		{"public-execution", "grant execute on function " + function + " to public"},
		{"extra-grantee", "grant execute on function " + function + " to " + pgx.Identifier{reader.Config().User}.Sanitize()},
		{"wrong-event", "drop trigger " + trigger + " on notes_app.notes; create trigger " + trigger + " before insert on notes_app.notes for each row execute function " + function},
		{"wrong-timing", "drop trigger " + trigger + " on notes_app.notes; create trigger " + trigger + " after update on notes_app.notes for each row execute function " + function},
		{"column-filter", "drop trigger " + trigger + " on notes_app.notes; create trigger " + trigger + " before update of source on notes_app.notes for each row execute function " + function},
		{"when-condition", "drop trigger " + trigger + " on notes_app.notes; create trigger " + trigger + " before update on notes_app.notes for each row when (old.source is distinct from new.source) execute function " + function},
		{"trigger-arguments", "drop trigger " + trigger + " on notes_app.notes; create trigger " + trigger + " before update on notes_app.notes for each row execute function " + strings.TrimSuffix(function, "()") + "('extra')"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tx, err := f.installer.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			if _, err := tx.Exec(f.ctx, tc.sql); err != nil {
				t.Fatal(err)
			}
			if err := rule.checkTrigger(observe(t, tx, "notes"), f.roles.Worker); err == nil {
				t.Fatal("accepted changed trigger/function under its original name")
			}
		})
	}
	// A lookalike function on another table still cannot satisfy the first
	// table's registration, even when its name, code and all flags are identical.
	f.call(t, "create table notes_app.other(id text primary key,source text,_tesl_v smallint not null default 1)")
	f.call(t, "create trigger "+trigger+" before update on notes_app.other for each row execute function "+function)
	pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
		if err := rule.checkTrigger(observe(t, tx, "other"), f.roles.Worker); err == nil {
			t.Fatal("identical trigger on a different relation was accepted")
		}
	})
}
