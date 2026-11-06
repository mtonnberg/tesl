package teslrt

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestPgRowHeaderOptimizationNeedsCatalogUpgrade(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	var original pgMigrationControlFunction
	for _, fn := range pgRowControlFunctions(f.namespace) {
		if fn.name == "tesl_stage_guards_ready" {
			original = fn
		}
	}
	if original.name == "" {
		t.Fatal("missing guard readiness definition")
	}
	optimized := original
	header := "(" + quoteIdentifier(f.namespace) + ".tesl_row_physical_source_header(p.contract)->>'format')"
	if strings.Count(original.body, header) != 2 {
		t.Fatal("header call inventory changed")
	}
	optimized.body = strings.Replace(optimized.body, "s jsonb;", "s jsonb; source_format text;", 1)
	optimized.body = strings.Replace(optimized.body, " if found and "+header, " if not found then return; end if;\n source_format:="+header+";\n if source_format", 1)
	optimized.body = strings.Replace(optimized.body, "if not found or "+header, "if source_format", 1)
	tx, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	if err := pgControlSession(f.ctx, tx); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, strings.Replace(pgControlFunctionSQL(f.namespace, f.roles.Owner, optimized), "create function ", "create or replace function ", 1)); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, "select "+quoteIdentifier(f.namespace)+".tesl_stage_guards_ready(1)"); err != nil {
		t.Fatal(err)
	}
	if err := pgControlFunctionCatalog(f.ctx, tx, f.namespace, f.roles, optimized); err != nil {
		t.Fatal(err)
	}
	if err := pgControlFunctionCatalog(f.ctx, tx, f.namespace, f.roles, original); err == nil {
		t.Fatal("old catalog reader accepted changed protected SQL")
	}
}

// SQL publication checks independently of the generated-code authority tests.
// Only this package's test can construct this private admission directly.
func TestPgRowBackfillBulkGuards(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	f.call(t, `create table notes_app.bulk_rows(id text primary key,title text not null,_tesl_v smallint not null);
insert into notes_app.bulk_rows values('a','old',1),('b','old',1)`)
	for _, test := range []struct {
		name string
		want int
		used bool
	}{
		{"both", 2, true}, {"stale-xmin", 1, true}, {"stale-age", 1, true},
		{"wrapped-xid", 1, true}, {"changed-key", 1, true}, {"wrong-generation", 1, true},
		{"duplicate-key", 0, false}, {"unique-index", 0, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			tx, err := f.worker.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(context.Background())
			entity := &pgRowPhysicalEntity{table: "bulk_rows", generation: 2, columns: []pgRowPhysicalColumn{
				{catalog: PgMigrationCatalogColumn{Name: "id", Type: "text", PrimaryKey: true}},
				{catalog: PgMigrationCatalogColumn{Name: "title", Type: "text"}},
			}}
			plan := &pgRowPhysicalPlan{namespace: f.namespace, compiled: &pgCompiledRowHistory{}}
			a := &pgRowTransactionAdmission{tx: tx, database: &Database{}, protocol: &pgMigrationAdmission{}, plan: plan, window: plan, entity: entity,
				write: true, backfill: &pgRowLeaseAdmission{leaseToken: 1}, backfillProcessingLatched: true}
			a.active.Store(true)
			var statements []pgRowBackfillStatement
			for _, key := range []string{"a", "b"} {
				var xmin, xid string
				var at time.Time
				if err := tx.QueryRow(f.ctx, `select xmin::text,pg_current_xact_id()::text,clock_timestamp() from notes_app.bulk_rows where id=$1`, key).Scan(&xmin, &xid, &at); err != nil {
					t.Fatal(err)
				}
				statement, err := pgPrepareBackfillRow(a, pgPhysicalWrite{columns: []string{"id", "title", "_tesl_v"}, values: []any{key, "new", int16(2)}, primary: key}, key, xmin, xid, at, time.Now(), 1)
				if err != nil {
					t.Fatal(err)
				}
				statements = append(statements, statement)
			}
			switch test.name {
			case "stale-xmin":
				statements[0].args[5] = "0"
			case "stale-age":
				statements[0].args[7] = time.Now().Add(-time.Minute)
			case "wrapped-xid":
				statements[0].args[6] = "-2147483648"
			case "changed-key":
				statements[0].args[4] = "different-key"
			case "wrong-generation":
				statements[0].args[8] = int16(3)
			case "duplicate-key":
				statements[1] = statements[0]
			case "unique-index":
				entity.indexes = []PgMigrationCatalogIndex{{Name: "title_unique", Columns: []string{"title"}, Unique: true}}
			}
			count, used, err := pgPublishBackfillBulk(f.ctx, a, statements)
			if err != nil || count != test.want || used != test.used {
				t.Fatalf("count=%d used=%v err=%v", count, used, err)
			}
			var actual int
			if err := tx.QueryRow(f.ctx, `select count(*) from notes_app.bulk_rows where _tesl_v=2 and title='new'`).Scan(&actual); err != nil || actual != test.want {
				t.Fatal("wrong rows published", actual, err)
			}
		})
	}
	t.Log("per-row guards, duplicate-key fallback and unique-index fallback verified")
}

func TestPgRowCatalogBatchMatchesSingleReadsAndSeesDrift(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, spec := range pgRowControlTables() {
		names = append(names, spec.name)
	}
	err := pgControlTransaction(f.ctx, f.worker, false, func(tx pgx.Tx) error {
		started := time.Now()
		batch, err := pgReadMigrationTables(f.ctx, tx, f.namespace, append(names, "absent_table"))
		if err != nil {
			return err
		}
		t.Logf("batch tables=%d elapsed=%s", len(names), time.Since(started))
		if batch["absent_table"] != nil || len(batch) != len(names) {
			t.Fatal("missing table invented")
		}
		started = time.Now()
		for _, name := range names {
			single, err := pgReadMigrationTable(f.ctx, tx, f.namespace, name)
			if err != nil {
				return err
			}
			if !reflect.DeepEqual(single, batch[name]) {
				t.Fatal("catalog differs", name)
			}
		}
		t.Logf("single tables=%d elapsed=%s", len(names), time.Since(started))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	tx, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	if err := pgControlSession(f.ctx, tx); err != nil {
		t.Fatal(err)
	}
	name := "tesl_row_versions"
	if err := pgControlTableACLs(f.ctx, tx, f.namespace, []string{name}, []string{f.roles.Request, f.roles.Worker}); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, "grant update on "+pgx.Identifier{f.namespace, name}.Sanitize()+" to "+quoteIdentifier(f.roles.Request)); err != nil {
		t.Fatal(err)
	}
	if err := pgControlTableACLs(f.ctx, tx, f.namespace, []string{name}, []string{f.roles.Request, f.roles.Worker}); err == nil {
		t.Fatal("batch reused a stale privilege observation")
	}
	before, err := pgReadMigrationTables(f.ctx, tx, f.namespace, []string{name})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, "alter table "+pgx.Identifier{f.namespace, name}.Sanitize()+" add column unexpected text"); err != nil {
		t.Fatal(err)
	}
	after, err := pgReadMigrationTables(f.ctx, tx, f.namespace, []string{name})
	if err != nil || reflect.DeepEqual(before, after) {
		t.Fatal("batch did not observe catalog drift", err)
	}
}
