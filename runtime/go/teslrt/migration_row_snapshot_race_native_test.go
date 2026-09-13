//go:build tesl_migration_test

package teslrt

import (
	"os"
	"testing"
	"time"
)

func pgAwaitRowSnapshotBoundary(t *testing.T, pause pgExpansionBoundaryPause, done <-chan error) {
	t.Helper()
	select {
	case <-pause.arrived:
	case err := <-done:
		t.Fatalf("Worker exited before snapshot boundary: %v", err)
	case <-time.After(15 * time.Second):
		t.Fatal("Worker did not reach snapshot boundary")
	}
}

func TestPgRowClaimRetriesCommittedRenewalSnapshot(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated V1/V2 Contract applications required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	pgCallRowAccessApp(t, f.ctx, v1, "POST", "/one", 200)

	// The first process owns a real lease but holds no SQL/lease row lock while
	// paused after its source read. Its ordinary renewal goroutine stays active.
	ownerPause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-backfill-after-read", hit: 1}})[0]
	ownerSocket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	stopOwner, ownerDone := pgStartSettledWorker(t, f, root, "v2", ownerSocket)
	t.Cleanup(ownerPause.resume)
	pgAwaitRowSnapshotBoundary(t, ownerPause, ownerDone)

	// Separate process/socket: freeze its snapshot before lease locking, then
	// observe a committed real renewal from the first process on a third connection.
	claimantPauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-worker-before-takeover", hit: 1}, {name: "row-worker-before-takeover", hit: 2}})
	claimantSocket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	stopClaimant, claimantDone := pgStartSettledWorker(t, f, root, "v2", claimantSocket)
	t.Cleanup(func() {
		for _, p := range claimantPauses {
			p.resume()
		}
	})
	pgAwaitRowSnapshotBoundary(t, claimantPauses[0], claimantDone)
	var before, after time.Time
	var holder string
	var token int64
	if err := request.QueryRow(f.ctx, "select expires_at,holder,token from notes.tesl_schema_leases where name='row:Note:2:0'").Scan(&before, &holder, &token); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(9 * time.Second)
	for {
		if err := request.QueryRow(f.ctx, "select expires_at from notes.tesl_schema_leases where name='row:Note:2:0'").Scan(&after); err != nil {
			t.Fatal(err)
		}
		if after.After(before) {
			break
		}
		select {
		case err := <-ownerDone:
			t.Fatalf("owner failed during actual renewal: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("owner did not commit a renewal after claimant snapshot")
		}
		time.Sleep(10 * time.Millisecond)
	}
	claimantPauses[0].resume()
	// SKIP LOCKED alone produces40001 here. A fresh second claim attempt must
	// be reached without publishing a new owner/token or terminating the Worker.
	pgAwaitRowSnapshotBoundary(t, claimantPauses[1], claimantDone)
	var same bool
	if err := request.QueryRow(f.ctx, "select holder=$1 and token=$2 from notes.tesl_schema_leases where name='row:Note:2:0'", holder, token).Scan(&same); err != nil || !same {
		t.Fatal("snapshot retry stole live owner", same, err)
	}
	var marker, processing int
	if err := request.QueryRow(f.ctx, "select _tesl_v,(select count(*) from notes.tesl_row_processing) from notes.notes where id='one'").Scan(&marker, &processing); err != nil || marker != 1 || processing != 0 {
		t.Fatal("claim-only retry published row data", marker, processing, err)
	}
	claimantPauses[1].resume()
	stopClaimant()
	ownerPause.resume()
	deadline = time.Now().Add(10 * time.Second)
	for {
		if err := request.QueryRow(f.ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil {
			t.Fatal(err)
		}
		if marker == 2 {
			break
		}
		select {
		case err := <-ownerDone:
			t.Fatalf("owner failed after renewal contention: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("owner failed to publish after renewal contention")
		}
		time.Sleep(10 * time.Millisecond)
	}
	stopOwner()
	t.Log("actual committed renewal after claimant snapshot retried without changing lease authority or replaying row work")
}

func TestPgRowBackfillRetriesWriteAfterCASSnapshot(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated V1/V2 Contract applications required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	pgCallRowAccessApp(t, f.ctx, v1, "POST", "/one", 200)
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-backfill-before-cas", hit: 1}, {name: "row-backfill-before-cas", hit: 2}})
	socket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	stop, done := pgStartSettledWorker(t, f, root, "v2", socket)
	t.Cleanup(func() {
		for _, p := range pauses {
			p.resume()
		}
	})
	pgAwaitRowSnapshotBoundary(t, pauses[0], done)
	// This update is after the new CAS transaction's RR snapshot, unlike the
	// existing source-read/conversion race. Its original Main/handler commits once.
	pgCallRowAccessApp(t, f.ctx, v1, "PUT", "/one", 200)
	var marker, processing int
	var title, memo string
	if err := request.QueryRow(f.ctx, "select title,memo,_tesl_v from notes.notes where id='one'").Scan(&title, &memo, &marker); err != nil || title != "edited" || memo != "one-edited" || marker != 1 {
		t.Fatal("original V1 write was not committed before CAS", title, memo, marker, err)
	}
	pauses[0].resume()
	pgAwaitRowSnapshotBoundary(t, pauses[1], done)
	var rowsDone int64
	var cursorAbsent bool
	if err := request.QueryRow(f.ctx, "select rows_done,last_pk is null,(select count(*) from notes.tesl_row_processing) from notes.tesl_schema_backfill_shards where lease_name='row:Note:2:0'").Scan(&rowsDone, &cursorAbsent, &processing); err != nil || rowsDone != 0 || !cursorAbsent || processing != 0 {
		t.Fatal("failed snapshot attempt published progress or processing ABI", rowsDone, cursorAbsent, processing, err)
	}
	if err := request.QueryRow(f.ctx, "select title,memo,_tesl_v from notes.notes where id='one'").Scan(&title, &memo, &marker); err != nil || title != "edited" || memo != "one-edited" || marker != 1 {
		t.Fatal("failed CAS overwrote accepted V1 data", title, memo, marker, err)
	}
	pauses[1].resume()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if err := request.QueryRow(f.ctx, "select title,memo,_tesl_v from notes.notes where id='one'").Scan(&title, &memo, &marker); err != nil {
			t.Fatal(err)
		}
		if marker == 2 {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("Worker exited on operational CAS serialization: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("Worker did not retry CAS from fresh source")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if title != "edited" || memo != "one-edited" {
		t.Fatal("fresh conversion lost accepted original handler write", title, memo)
	}
	if err := request.QueryRow(f.ctx, "select rows_done,(select count(*) from notes.tesl_row_processing) from notes.tesl_schema_backfill_shards where lease_name='row:Note:2:0'").Scan(&rowsDone, &processing); err != nil || rowsDone != 1 || processing != 1 {
		t.Fatal("successful retry must publish DML ABI and progress exactly once", rowsDone, processing, err)
	}
	stop()
	t.Log("original V1 write after CAS snapshot survives40001 rollback; fresh internal batch publishes row ABI and cursor exactly once")
}
