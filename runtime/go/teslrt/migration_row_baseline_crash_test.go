//go:build tesl_migration_test

package teslrt

import (
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestPgRowBaselineInstallerBackendDeathPublishesAllOrNothing(t *testing.T) {
	for _, boundary := range []string{"row-baseline-table-tesl_row_baseline", "row-baseline-table-tesl_row_versions", "row-baseline-table-tesl_row_entities", "row-baseline-inventory", "control-before-commit", "control-after-commit"} {
		t.Run(boundary, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			db := pgRowBaselineFixture(t, f)
			pgQueueCandidateCrash(t, f, boundary, func(conn *pgx.Conn) error {
				_, err := InstallPgCompiledRowBaseline(f.ctx, conn, db, f.roles)
				return err
			})
			committed := boundary == "control-after-commit"
			var exists bool
			if err := f.installer.QueryRow(f.ctx, `select exists(select 1 from pg_catalog.pg_namespace where nspname='notes_app')`).Scan(&exists); err != nil || exists != committed {
				t.Fatal("partial installation", exists, err)
			}
			var uuid string
			if committed {
				if err := f.installer.QueryRow(f.ctx, `select database_uuid::text from notes_app.tesl_schema_meta`).Scan(&uuid); err != nil {
					t.Fatal(err)
				}
			}
			state, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles)
			if err != nil {
				t.Fatal(err)
			}
			if committed && uuid != state.DatabaseUUID {
				t.Fatal("retry replaced committed identity")
			}
			b, err := pgCompiledRowBaseline(db)
			if err != nil {
				t.Fatal(err)
			}
			if err := pgRowBaselineRead(t, f, request, b); err != nil {
				t.Fatal(err)
			}
			if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
				t.Fatal("retry could not finish physical baseline", err)
			}
		})
	}
}
func TestPgRowBaselineWorkerBackendDeathKeepsMarkerAndProgressAtomic(t *testing.T) {
	for _, boundary := range []string{"expansion-before-commit", "expansion-after-commit", "row-baseline-after-ddl", "row-baseline-before-publication"} {
		t.Run(boundary, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			db := pgRowBaselineFixture(t, f)
			installed, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles)
			if err != nil {
				t.Fatal(err)
			}
			// The helper's connection and terminating peer both use this same Worker
			// principal; no installer credential executes worker DDL.
			workerFixture := *f
			workerFixture.installer = f.worker
			pgQueueCandidateCrash(t, &workerFixture, boundary, func(conn *pgx.Conn) error {
				_, err := ExecutePgCompiledRowBaseline(f.ctx, conn, db, f.roles)
				return err
			})
			var tables, markers, objects, current int
			if err := f.installer.QueryRow(f.ctx, `select (select count(*) from pg_catalog.pg_tables where schemaname='notes_app' and tablename='notes'),(select count(*) from information_schema.columns where table_schema='notes_app' and table_name='notes' and column_name='_tesl_v' and udt_name='int2' and is_nullable='NO'),(select count(*) from notes_app.tesl_schema_expansion_objects),current from notes_app.tesl_schema_state`).Scan(&tables, &markers, &objects, &current); err != nil {
				t.Fatal(err)
			}
			if tables != markers || tables != objects || current != 0 {
				t.Fatal("DDL marker/progress split or premature publication", tables, markers, objects, current)
			}
			b, err := pgCompiledRowBaseline(db)
			if err != nil {
				t.Fatal(err)
			}
			if err := pgRowBaselineRead(t, f, request, b); err != nil {
				t.Fatal("crash left unverifiable prefix", err)
			}
			state, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles)
			if err != nil || state.Current != 1 || state.DatabaseUUID != installed.DatabaseUUID {
				t.Fatal("retry changed identity or failed", state, err)
			}
		})
	}
}
func TestPgRowBaselinePartialCompilerABIIsLatchedButCompletedProvenanceIsRetained(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	wf := *f
	wf.installer = f.worker
	pgQueueCandidateCrash(t, &wf, "expansion-after-commit", func(conn *pgx.Conn) error {
		_, err := ExecutePgCompiledRowBaseline(f.ctx, conn, db, f.roles)
		return err
	})
	b, err := pgCompiledRowBaseline(db)
	if err != nil {
		t.Fatal(err)
	}
	changed := *b
	changed.history.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("e", 64)
	status, err := pgRowSchemaStatus(f.ctx, f.worker, &changed, f.roles)
	if err != nil || len(status.Expansions) != 1 || status.Expansions[0].SourceCompilerABI != b.history.SourceCompilerABI || status.SourceCompilerABI != changed.history.SourceCompilerABI {
		t.Fatal("pending status lost executing versus observing ABI", status, err)
	}
	if _, err := pgExecuteRowBaseline(f.ctx, f.worker, &changed, f.roles); err == nil || !strings.Contains(err.Error(), "compiler ABI") {
		t.Fatal("partial work changed compiler", err)
	}
	if _, err := pgExecuteRowBaseline(f.ctx, f.worker, b, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := pgExecuteRowBaseline(f.ctx, f.worker, &changed, f.roles); err != nil {
		t.Fatal("completed compatible baseline pinned processing ABI", err)
	}
	status, err = pgRowSchemaStatus(f.ctx, f.worker, &changed, f.roles)
	if err != nil || len(status.Expansions) != 1 || status.Expansions[0].SourceCompilerABI != b.history.SourceCompilerABI || status.SourceCompilerABI != changed.history.SourceCompilerABI || len(status.Expansions[0].Steps) != 3 {
		t.Fatal("completed status lost executing versus observing ABI", status, err)
	}
	var abi string
	if err := f.worker.QueryRow(f.ctx, `select compiler_abi from notes_app.tesl_row_versions`).Scan(&abi); err != nil || abi != b.history.SourceCompilerABI {
		t.Fatal("changed baseline creator provenance", abi, err)
	}
}
