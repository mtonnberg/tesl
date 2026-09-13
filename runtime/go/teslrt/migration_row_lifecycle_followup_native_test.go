//go:build tesl_migration_test

package teslrt

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgRowWorkerDrainsInFlightRenewalAfterBatchCommit(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual generated Worker apps required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	pgCallRowAccessApp(t, f.ctx, v1, "POST", "/one", 200)
	pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-backfill-after-dml", hit: 1}})[0]
	defer pause.resume()
	stop, done := pgStartSettledWorker(t, f, root, "v2", "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	select {
	case <-pause.arrived:
	case err := <-done:
		t.Fatalf("worker before CAS: %v", err)
	case <-time.After(15 * time.Second):
		t.Fatal("missing CAS pause")
	}
	// Keep the legitimate lease shared lock after the batch commits, so the
	// in-flight renewal cannot finish before the normal-completion cleanup runs.
	hold, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = hold.Rollback(f.ctx) }()
	if _, err := hold.Exec(f.ctx, "select name from notes.tesl_schema_leases where name='row:Note:2:0' for share"); err != nil {
		t.Fatal(err)
	}
	blocked := func() bool {
		t.Helper()
		var found bool
		if err := f.worker.QueryRow(f.ctx, `select exists(select 1 from pg_stat_activity where datname=current_database() and wait_event_type='Lock' and query like '%tesl_renew_row_shard%' and application_name=(select holder from notes.tesl_schema_leases where name='row:Note:2:0'))`).Scan(&found); err != nil {
			t.Fatal(err)
		}
		return found
	}
	deadline := time.Now().Add(12 * time.Second)
	for !blocked() {
		if time.Now().After(deadline) {
			t.Fatal("renewal never blocked behind lease")
		}
		time.Sleep(20 * time.Millisecond)
	}
	pause.resume()
	deadline = time.Now().Add(5 * time.Second)
	for {
		var marker int
		if err := request.QueryRow(f.ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil {
			t.Fatal(err)
		}
		if marker == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("batch failed to commit before renewal drain")
		}
		time.Sleep(10 * time.Millisecond)
	}
	select {
	case err := <-done:
		t.Fatalf("normal completion canceled reusable renewal connection: %v", err)
	case <-time.After(time.Second):
	}
	if !blocked() {
		t.Fatal("normal completion canceled in-flight renewal instead of draining")
	}
	if err := hold.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(10 * time.Second)
	for {
		select {
		case err := <-done:
			t.Fatalf("worker did not reuse healthy coordinator: %v", err)
		default:
		}
		var provisional bool
		if err := request.QueryRow(f.ctx, "select state='provisional' from notes.tesl_schema_backfill_shards where lease_name='row:Note:2:0'").Scan(&provisional); err != nil {
			t.Fatal(err)
		}
		if provisional {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("worker did not continue after renewal drain")
		}
		time.Sleep(20 * time.Millisecond)
	}
	stop()
}

func TestPgRowRetirementRequiresEntireFinalShardInventory(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual generated Contract apps required")
	}
	f, _ := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "contract", true)
	pgForwardNativeRun(t, f, root, "v2", "status", true)
	// Remove the complete observed inventory, leaving immutable retirement and
	// finality receipts untouched. A counts map populated only by rows misses it.
	if _, err := f.installer.Exec(f.ctx, "delete from notes.tesl_schema_backfill_shards;delete from notes.tesl_schema_leases"); err != nil {
		t.Fatal(err)
	}
	output, err := pgForwardNativeCommand(f, root, "v2", "status").CombinedOutput()
	if err == nil || !strings.Contains(string(output), "row work inventory is incomplete") {
		t.Fatal("complete final shard deletion bypassed exact reader", err, string(output))
	}
}
