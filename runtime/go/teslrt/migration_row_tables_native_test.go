//go:build tesl_migration_test

package teslrt

import (
	"os"
	"strings"
	"testing"
	"time"
)

func pgRowTablesInstalled(t *testing.T) (string, *pgControlTestFixture) {
	t.Helper()
	root := os.Getenv("TESL_ROW_TABLES_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated new-table programs required")
	}
	t.Setenv("TESL_ROW_ADDITIVE_PROGRAMS", root)
	return pgRowAdditiveInstalled(t)
}

func TestPgRowTablesBirthAndLaterTransform(t *testing.T) {
	root, f := pgRowTablesInstalled(t)
	old := pgRowAdditiveApp(t, f, root, "v1")
	pgCallRowAccessApp(t, f.ctx, old, "POST", "/one", 200)
	stop := pgRowAdditiveWorker(t, f, root, "v2")
	stop()
	current := pgRowAdditiveApp(t, f, root, "v2")
	pgCallRowAccessApp(t, f.ctx, current, "POST", "/added", 200)
	pgCallRowAccessApp(t, f.ctx, old, "POST", "/two", 200)
	pgCallRowAccessApp(t, f.ctx, old, "GET", "/all", 200)
	var birth, marker, processing, shards, indexes int
	err := f.worker.QueryRow(f.ctx, `select
 (select count(*) from notes.tesl_row_finality f join notes.tesl_row_physical p on p.version=f.version and p.contract_hash=f.physical_hash and p.compiler_abi=f.compiler_abi
  join notes.tesl_schema_expansion_objects o on o.version=f.version and o.operation_hash=f.retirement_hash where f.entity='Added' and f.generation=1 and f.version=2),
 (select _tesl_v from notes.added where id='new'),(select count(*) from notes.tesl_row_processing),
 (select count(*) from notes.tesl_schema_backfill_shards),
 (select count(*) from pg_catalog.pg_indexes where schemaname='notes' and tablename='added' and indexname='added_code_lookup')`).Scan(&birth, &marker, &processing, &shards, &indexes)
	if err != nil || birth != 1 || marker != 1 || processing != 0 || shards != 0 || indexes != 1 {
		t.Fatal("new table lacks exact independent birth evidence", birth, marker, processing, shards, indexes, err)
	}
	// The original reader reconstructs all birth obligations independently;
	// surviving rows cannot relabel the creator, source revision or manifest.
	for _, probe := range []struct{ name, damage, want string }{
		{"complete absence", "delete from notes.tesl_row_finality where entity='Added' and generation=1", "missing per-entity finality receipt"},
		{"creator", "update notes.tesl_row_finality set compiler_abi='tesl-source-abi-v1:'||repeat('0',64) where entity='Added' and generation=1", "per-entity finality differs"},
		{"source version", "update notes.tesl_row_finality set version=1 where entity='Added' and generation=1", "per-entity finality differs"},
		{"physical hash", "update notes.tesl_row_finality set physical_hash=repeat('0',64) where entity='Added' and generation=1", "per-entity finality differs"},
		{"operation hash", "update notes.tesl_row_finality set retirement_hash=repeat('0',64) where entity='Added' and generation=1", "per-entity finality differs"},
	} {
		t.Run(probe.name, func(t *testing.T) {
			if _, err := f.installer.Exec(f.ctx, "create temp table saved_birth as select * from notes.tesl_row_finality where entity='Added' and generation=1"); err != nil {
				t.Fatal(err)
			}
			defer func() {
				if _, err := f.installer.Exec(f.ctx, "delete from notes.tesl_row_finality where entity='Added' and generation=1; insert into notes.tesl_row_finality select * from saved_birth; drop table saved_birth"); err != nil {
					t.Error(err)
				}
			}()
			if _, err := f.installer.Exec(f.ctx, probe.damage); err != nil {
				t.Fatal(err)
			}
			out, err := pgRowAdditiveCommand(f, root, "v1", "--schema", "status", "--json").CombinedOutput()
			if err == nil || !strings.Contains(string(out), probe.want) {
				t.Fatal("original reader accepted altered birth evidence", err, string(out))
			}
		})
	}
	if out, err := pgRowAdditiveCommand(f, root, "v2", "--schema", "close-epoch", "--through", "V2", "--force", "--json").CombinedOutput(); err != nil {
		t.Fatal(err, string(out))
	}
	stop = pgRowAdditiveWorker(t, f, root, "v3")
	deadline := time.Now().Add(15 * time.Second)
	for {
		var converted int
		err := f.worker.QueryRow(f.ctx, "select count(*) from notes.added where _tesl_v=2 and count=11 and code='new-table'").Scan(&converted)
		if err == nil && converted == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("later transform lost new-table row", converted, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	stop()
	third := pgRowAdditiveApp(t, f, root, "v3")
	if body := pgCallRowAccessApp(t, f.ctx, third, "GET", "/added", 200); !strings.Contains(body, `"count":11`) {
		t.Fatal(body)
	}
	if out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "contract", "V3", "--json").CombinedOutput(); err != nil {
		t.Fatal("contract lost birth generation prerequisite", err, string(out))
	}
	pgCallRowAccessApp(t, f.ctx, third, "GET", "/added", 200)
	pgCallRowAccessApp(t, f.ctx, current, "GET", "/added", 503)
}

func TestPgRowTablesPublicationAtomicity(t *testing.T) {
	for _, boundary := range []string{"row-forward-after-ddl", "row-forward-after-receipt", "row-forward-after-expanded", "row-forward-after-births", "row-forward-after-publication-commit"} {
		t.Run(boundary, func(t *testing.T) {
			root, f := pgRowTablesInstalled(t)
			old := pgRowAdditiveApp(t, f, root, "v1")
			pgCallRowAccessApp(t, f.ctx, old, "POST", "/one", 200)
			pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{boundary, 1}})[0]
			defer pause.resume()
			cmd := pgRowAdditiveCommand(f, root, "v2", "--schema", "worker", "--json")
			cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			output, done := pgRowEpochNativeCommand(t, cmd)
			select {
			case <-pause.arrived:
			case err := <-done:
				t.Fatal("new-table worker failed before crash boundary", err, output.String())
			case <-time.After(15 * time.Second):
				t.Fatal("new-table worker did not reach crash boundary", output.String())
			}
			if err := cmd.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("killed worker succeeded")
				}
			case <-time.After(5 * time.Second):
				t.Fatal("killed worker did not exit")
			}
			pause.resume()
			var current, births, expanded, processing, tables int
			err := f.worker.QueryRow(f.ctx, `select current,
    (select count(*) from notes.tesl_row_finality where version=2),
    (select count(*) from notes.tesl_schema_versions where version=2 and step='expanded'),
    (select count(*) from notes.tesl_row_processing),
    (select count(*) from information_schema.tables where table_schema='notes' and table_name='added')
    from notes.tesl_schema_state`).Scan(&current, &births, &expanded, &processing, &tables)
			committed := boundary == "row-forward-after-publication-commit"
			wantCurrent, wantBirth, wantExpanded := 1, 0, 0
			if committed {
				wantCurrent, wantBirth, wantExpanded = 2, 1, 1
			}
			wantTable := 1
			if boundary == "row-forward-after-ddl" {
				wantTable = 0
			}
			if err != nil || current != wantCurrent || births != wantBirth || expanded != wantExpanded || processing != 0 || tables != wantTable {
				t.Fatal("non-atomic table/birth publication", current, births, expanded, processing, tables, err)
			}
			pgCallRowAccessApp(t, f.ctx, old, "GET", "/all", 200)
			stop := pgRowAdditiveWorker(t, f, root, "v2")
			stop()
			currentApp := pgRowAdditiveApp(t, f, root, "v2")
			pgCallRowAccessApp(t, f.ctx, currentApp, "POST", "/added", 200)
		})
	}
}
