package teslrt

import (
	"testing"

	"github.com/jackc/pgx/v5"
)

// This tests the closed trigger generator/catalog matcher directly. It grants
// no compiled plan or migration execution authority; the full native fixture
// separately exercises authentic compiler-emitted V1 and V2 manifests.
func TestPgRowForwardInvalidationCatalogAndMarker(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
	entity := pgRowPhysicalEntity{identity: "Notes", table: "notes", generation: 2, insertGeneration: 1}
	window := pgRowPhysicalWindow{entity: "Notes", previousGeneration: 1, targetGeneration: 2, requiresFinalGeneration: 1, invalidation: []string{"title"}}
	spec := pgRowInvalidationFor(f.namespace, &entity, &window)
	if err := pgExpansionTransaction(f.ctx, f.worker, func(tx pgx.Tx) error { return pgExecuteRowInvalidation(f.ctx, tx, f.namespace, f.roles, spec) }); err != nil {
		t.Fatal(err)
	}
	verify := func() error {
		return pgControlSnapshotMode(f.ctx, request, pgx.ReadOnly, func(tx pgx.Tx) error {
			observed, err := pgReadMigrationTable(f.ctx, tx, f.namespace, "notes")
			if err != nil {
				return err
			}
			if err := pgVerifyRowInvalidation(f.ctx, tx, f.namespace, f.roles, observed, spec); err != nil {
				return err
			}
			return nil
		})
	}
	if err := verify(); err != nil {
		t.Fatal(err)
	}
	if _, err := request.Exec(f.ctx, `insert into notes_app.notes(id,title,_tesl_v) values(1,'first',2)`); err != nil {
		t.Fatal(err)
	}
	marker := func(want int) {
		t.Helper()
		var got int
		if err := request.QueryRow(f.ctx, `select _tesl_v from notes_app.notes where id=1`).Scan(&got); err != nil || got != want {
			t.Fatalf("marker=%d want=%d err=%v", got, want, err)
		}
	}
	marker(1)
	if err := pgExpansionTransaction(f.ctx, request, func(tx pgx.Tx) error {
		if _, err := tx.Exec(f.ctx, "select pg_catalog.set_config($1,'2',true)", pgRowWriterSetting(f.namespace, entity.identity)); err != nil {
			return err
		}
		_, err := tx.Exec(f.ctx, `update notes_app.notes set title='new',_tesl_v=2 where id=1`)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	marker(2)
	if _, err := request.Exec(f.ctx, `update notes_app.notes set title='late old' where id=1`); err != nil {
		t.Fatal(err)
	}
	marker(1)
	// A redundant source assignment does not turn an already materialized row back.
	if _, err := request.Exec(f.ctx, `update notes_app.notes set _tesl_v=2 where id=1;update notes_app.notes set title=title where id=1`); err != nil {
		t.Fatal(err)
	}
	marker(2)
	if _, err := f.worker.Exec(f.ctx, "alter function "+pgx.Identifier{f.namespace, spec.name}.Sanitize()+"() cost 101"); err != nil {
		t.Fatal(err)
	}
	if err := verify(); err == nil {
		t.Fatal("changed function cost accepted")
	}
}
