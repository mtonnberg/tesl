//go:build tesl_migration_test

package teslrt

import (
	"os"
	"strings"
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

// Registration uses RepeatableRead just like claim and CAS. A different worker's
// committed progress can invalidate its INSERT ON CONFLICT after the snapshot.
func TestPgRowPrepareRetriesCommittedProgressSnapshot(t *testing.T) {
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
	owner := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-backfill-after-dml", hit: 1}})[0]
	ownerSocket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	stopOwner, ownerDone := pgStartSettledWorker(t, f, root, "v2", ownerSocket)
	t.Cleanup(owner.resume)
	pgAwaitRowSnapshotBoundary(t, owner, ownerDone)
	preparing := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-worker-before-prepare-shards", hit: 1}, {name: "row-worker-before-prepare-shards", hit: 2}})
	prepareSocket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	prepareCommand := pgForwardNativeCommand(f, root, "v2", "worker")
	prepareCommand.Env = append(prepareCommand.Env, "TESL_BACKFILL_BATCH=1", prepareSocket)
	prepareProcess := pgLaunchRepeatedProcess(t, prepareCommand)
	prepareProcess.ready(t)
	stopPreparing, prepareDone := prepareProcess.stop, prepareProcess.done
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("preparing worker output: %s", prepareProcess.output.String())
		}
	})
	t.Cleanup(func() {
		for _, p := range preparing {
			p.resume()
		}
	})
	pgAwaitRowSnapshotBoundary(t, preparing[0], prepareDone)
	owner.resume()
	deadline := time.Now().Add(10 * time.Second)
	var marker, processed, abi int
	for {
		err := request.QueryRow(f.ctx, "select _tesl_v,(select rows_done from notes.tesl_schema_backfill_shards where lease_name='row:Note:2:0'),(select count(*) from notes.tesl_row_processing) from notes.notes where id='one'").Scan(&marker, &processed, &abi)
		if err != nil {
			t.Fatal(err)
		}
		if marker == 2 && processed == 1 && abi == 1 {
			break
		}
		select {
		case err := <-ownerDone:
			t.Fatalf("owner exited before durable progress: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("owner did not commit target row, ABI and progress", marker, processed, abi)
		}
		time.Sleep(10 * time.Millisecond)
	}
	stopOwner()
	preparing[0].resume()
	pgAwaitRowSnapshotBoundary(t, preparing[1], prepareDone)
	// No claim or row callback ran in the failed registration transaction.
	if err := request.QueryRow(f.ctx, "select _tesl_v,(select rows_done from notes.tesl_schema_backfill_shards where lease_name='row:Note:2:0'),(select count(*) from notes.tesl_row_processing) from notes.notes where id='one'").Scan(&marker, &processed, &abi); err != nil || marker != 2 || processed != 1 || abi != 1 {
		t.Fatal("prepare retry changed committed work", marker, processed, abi, err)
	}
	preparing[1].resume()
	select {
	case err := <-prepareDone:
		t.Fatalf("worker failed after fresh registration: %v", err)
	case <-time.After(250 * time.Millisecond):
	}
	stopPreparing()
	t.Log("actual progress committed after prepare snapshot; internal registration retried fresh without repeating row work")
}

func TestPgRowContractPrepareHasOperationDeadline(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated V1/V2 Contract applications required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-worker-before-prepare-shards", hit: 1}})[0]
	defer pause.resume()
	cmd := pgForwardNativeCommand(f, root, "v2", "contract")
	cmd.Env = append(cmd.Env, "TESL_PG_POOL_LEASE_TIMEOUT_MS=1000", "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	var output pgRowAppOutput
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait(); close(done) }()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("contract cleanup did not finish")
		}
	})
	pgAwaitRowSnapshotBoundary(t, pause, done)
	// Contract passes its long-lived service context. This pause begins only
	// after the exact prepare snapshot, so startup costs cannot satisfy the test.
	time.Sleep(1200 * time.Millisecond)
	pause.resume()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(output.String(), "context deadline exceeded") {
			t.Fatal("contract registration did not honor its operation deadline", err, output.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("contract registration stayed live after operation deadline", output.String())
	}
	var current, floor, retired, abi int
	if err := request.QueryRow(f.ctx, "select current,compat_floor,(select count(*) from notes.tesl_schema_versions where version=2 and step='retired'),(select count(*) from notes.tesl_row_processing) from notes.tesl_schema_state").Scan(&current, &floor, &retired, &abi); err != nil || current != 2 || floor != 1 || retired != 0 || abi != 0 {
		t.Fatal("expired prepare published lifecycle or processing authority", current, floor, retired, abi, err)
	}
	t.Log("Contract service context bounded by one prepare operation deadline; no retirement or processing publication")
}
