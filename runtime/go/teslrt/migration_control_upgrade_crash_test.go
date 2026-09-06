//go:build tesl_migration_test

package teslrt

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestPgMigrationControlUpgradeCrashIsExactOldOrNewFormat(t *testing.T) {
	for _, boundary := range []string{"control-upgrade-before-objects", "control-upgrade-after-objects", "control-upgrade-before-commit", "control-upgrade-after-commit"} {
		t.Run(boundary, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			f.expand(t, 1)
			f.call(t, "insert into notes_app.notes(id,active) values('retained',true)")
			pgControlTestFormat2(t, f)
			before := pgControlUpgradePreservedRows(t, f)
			arrived, resume := pgPauseExpansionBoundary(t, boundary, 1)
			conn, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
			if err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() {
				_, err := UpgradePgCompiledMigrationControl(f.ctx, conn, pgExpansionTestHistory(f.namespace, 1), f.roles, 3)
				_ = conn.Close(context.Background())
				done <- err
			}()
			select {
			case <-arrived:
			case err := <-done:
				t.Fatalf("upgrade stopped before boundary: %v", err)
			case <-f.ctx.Done():
				t.Fatal("upgrade did not reach boundary")
			}
			var killed bool
			if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_terminate_backend($1)", conn.PgConn().PID()).Scan(&killed); err != nil || !killed {
				t.Fatalf("kill own upgrade backend: %v %v", killed, err)
			}
			resume()
			if err := <-done; err == nil {
				t.Fatal("terminated upgrader returned ordinary success")
			}
			t.Setenv("TESL_MIGRATION_TEST_SOCKET", "")
			state, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
			want := 2
			if boundary == "control-upgrade-after-commit" {
				want = 3
			}
			if err != nil || state.Format != want || pgControlUpgradePreservedRows(t, f) != before {
				t.Fatalf("crash left mixed format or changed history: %+v %v", state, err)
			}
			if _, err := UpgradePgCompiledMigrationControl(f.ctx, f.installer, pgExpansionTestHistory(f.namespace, 1), f.roles, 3); err != nil {
				t.Fatalf("retry could not complete exact upgrade: %v", err)
			}
			if before != pgControlUpgradePreservedRows(t, f) {
				t.Fatal("recovery rewrote retained rows or provenance")
			}
		})
	}
}
