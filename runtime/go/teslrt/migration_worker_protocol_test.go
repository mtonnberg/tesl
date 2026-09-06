//go:build tesl_migration_test

package teslrt

import (
	"bytes"
	"context"
	"errors"
	"testing"
)

func TestPgMigrationWorkerCancellationRollsBackUncommittedDDL(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	db := pgWorkerTestDatabase(t, f, 1)
	db.Config.DDLConnection = f.worker.Config().ConnString()
	RegisterDatabaseIdentity("WorkerFixture.Cancel", db)
	t.Cleanup(func() { databaseIdentities.Delete("WorkerFixture.Cancel") })
	arrived, release := pgPauseExpansionBoundary(t, "expansion-after-ddl", 1)
	ctx, cancel := context.WithCancel(f.ctx)
	defer cancel()
	var output bytes.Buffer
	done := make(chan error, 1)
	go func() {
		done <- pgRunSchemaCommandContext(ctx, pgSchemaCommand{verb: "worker", database: db.migrationHistory.Database, json: true}, &output)
	}()
	select {
	case <-arrived:
	case err := <-done:
		t.Fatalf("worker failed before its DDL transaction: %v", err)
	case <-f.ctx.Done():
		t.Fatal("worker did not reach DDL boundary")
	}
	cancel()
	release()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("worker did not report cancellation: %v", err)
		}
	case <-f.ctx.Done():
		t.Fatal("worker retained its connection/locks after cancellation")
	}
	if output.Len() != 0 || db.bound() != nil {
		t.Fatal("cancelled worker announced readiness or published a request pool")
	}
	var tables, progress int
	if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_tables where schemaname=$1 and tablename='notes'", f.namespace).Scan(&tables); err != nil || tables != 0 {
		t.Fatalf("cancelled worker committed entity DDL: %d %v", tables, err)
	}
	if err := f.installer.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansion_objects").Scan(&progress); err != nil || progress != 0 {
		t.Fatalf("cancelled worker recorded uncommitted object progress: %d %v", progress, err)
	}
	// A same-source retry must acquire both coordination locks and finish the
	// immutable intent left by the cancelled process.
	if state := f.expand(t, 1); state.Current != 1 {
		t.Fatalf("worker retry could not complete: %+v", state)
	}
}
