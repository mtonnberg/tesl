//go:build tesl_migration_test

package teslrt

import (
	"os"
	"testing"
	"time"
)

func TestPgRowFinalityRenewsOutsideBatchesAndWaitsForOwnCAS(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated V1/V2 Contract apps required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true) // Expand empty, then create old source data.
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	pgCallRowAccessApp(t, f.ctx, v1, "POST", "/one", 200)
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-backfill-after-dml", hit: 1}, {name: "row-finality-after-batch", hit: 1}})
	command := pgForwardNativeCommand(f, root, "v2", "contract")
	command.Env = append(command.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"), "TESL_BACKFILL_BATCH=1")
	var output pgRowAppOutput
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait(); close(done) }()
	t.Cleanup(func() {
		for _, pause := range pauses {
			pause.resume()
		}
		_ = command.Process.Kill()
		<-done
	})
	wait := func(index int) {
		t.Helper()
		select {
		case <-pauses[index].arrived:
		case err := <-done:
			t.Fatalf("Contract exited before boundary%d: %v\n%s", index, err, output.String())
		case <-time.After(30 * time.Second):
			t.Fatalf("Contract missing boundary%d\n%s", index, output.String())
		}
	}
	wait(0)
	// A real CAS holds the protected lease FOR SHARE. Renewal UPDATE must wait
	// for that transaction rather than canceling its otherwise valid 30s budget.
	var marker, processing int
	if err := request.QueryRow(f.ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil || marker != 1 {
		t.Fatal("uncommitted CAS exposed target row", marker, err)
	}
	if err := request.QueryRow(f.ctx, "select count(*) from notes.tesl_row_processing").Scan(&processing); err != nil || processing != 0 {
		t.Fatal("uncommitted CAS exposed processing latch", processing, err)
	}
	select {
	case err := <-done:
		t.Fatalf("own CAS wait canceled worker: %v\n%s", err, output.String())
	case <-time.After(12 * time.Second):
	}
	pauses[0].resume()
	wait(1)
	var before, after time.Time
	readExpiry := func(target *time.Time) {
		t.Helper()
		if err := request.QueryRow(f.ctx, "select expires_at from notes.tesl_schema_leases where name='row:Note:2:0'").Scan(target); err != nil {
			t.Fatal(err)
		}
	}
	readExpiry(&before)
	// No batch or SQL transaction remains open at this boundary. A timer scoped
	// to each fast batch cannot renew here; the whole finalpass scope must do so.
	select {
	case err := <-done:
		t.Fatalf("between-batch renewal stopped: %v\n%s", err, output.String())
	case <-time.After(6 * time.Second):
	}
	readExpiry(&after)
	if !after.After(before.Add(time.Second)) {
		t.Fatal("lease was not renewed between completed batches", before, after)
	}
	if err := request.QueryRow(f.ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil || marker != 2 {
		t.Fatal("completed CAS not durable", marker, err)
	}
	if err := request.QueryRow(f.ctx, "select count(*) from notes.tesl_row_processing").Scan(&processing); err != nil || processing != 1 {
		t.Fatal("completed CAS omitted durable processing latch", processing, err)
	}
	pauses[1].resume()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Contract after real renewal: %v\n%s", err, output.String())
		}
	case <-time.After(30 * time.Second):
		t.Fatal("Contract failed to finish after renewal")
	}
	var current, min, floor int
	if err := request.QueryRow(f.ctx, "select current,min_version,compat_floor from notes.tesl_schema_state").Scan(&current, &min, &floor); err != nil || current != 2 || min != 2 || floor != 2 {
		t.Fatal("Contract finality not durable", current, min, floor, err)
	}
}

func TestPgRowHealthyWorkerClaimSkipsActiveCAS(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated V1/V2 Contract apps required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	pgCallRowAccessApp(t, f.ctx, v1, "POST", "/one", 200)
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-backfill-after-dml", hit: 1}})
	defer pauses[0].resume()
	socket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	stopFirst, firstDone := pgStartSettledWorker(t, f, root, "v2", socket)
	select {
	case <-pauses[0].arrived:
	case err := <-firstDone:
		t.Fatalf("first worker failed before CAS: %v", err)
	case <-time.After(15 * time.Second):
		t.Fatal("first worker missing CAS boundary")
	}
	stopSecond, secondDone := pgStartSettledWorker(t, f, root, "v2", socket)
	select {
	case err := <-secondDone:
		t.Fatalf("healthy competing claim exited instead of reporting busy: %v", err)
	case <-time.After(4 * time.Second):
	}
	var marker int
	if err := request.QueryRow(f.ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil || marker != 1 {
		t.Fatal("competing worker bypassed active CAS", marker, err)
	}
	pauses[0].resume()
	deadline := time.Now().Add(15 * time.Second)
	for {
		if err := request.QueryRow(f.ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil {
			t.Fatal(err)
		}
		if marker == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("healthy worker did not finish after lease contention")
		}
		time.Sleep(20 * time.Millisecond)
	}
	stopSecond()
	stopFirst()
}

func TestPgRowBackfillBackendKillPreservesAtomicProgress(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated V1/V2 Contract apps required")
	}
	for _, boundary := range []string{"row-backfill-after-dml", "row-backfill-after-progress", "row-finality-after-batch"} {
		t.Run(boundary, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.namespace = "notes"
			pgForwardNativeRun(t, f, root, "v1", "install", true)
			pgForwardNativeRun(t, f, root, "v1", "worker", true)
			pgForwardNativeRun(t, f, root, "v2", "worker", true)
			v1 := pgStartRowAccessApp(t, f, root, "v1")
			pgCallRowAccessApp(t, f.ctx, v1, "POST", "/one", 200)
			pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: boundary, hit: 1}})
			command := pgForwardNativeCommand(f, root, "v2", "contract")
			command.Env = append(command.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"), "TESL_BACKFILL_BATCH=1")
			var output pgRowAppOutput
			command.Stdout = &output
			command.Stderr = &output
			if err := command.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- command.Wait(); close(done) }()
			t.Cleanup(func() { pauses[0].resume(); _ = command.Process.Kill(); <-done })
			select {
			case <-pauses[0].arrived:
			case err := <-done:
				t.Fatalf("Contract before kill: %v\n%s", err, output.String())
			case <-time.After(20 * time.Second):
				t.Fatal("missing crash boundary", boundary)
			}
			committed := boundary == "row-finality-after-batch"
			// Identify the exact batch backend through this task's protected holder.
			// Before commit it alone has an open transaction; after commit its last
			// command released the runtime's session lock. The coordinator's last
			// command is the progress reset and the renewal connection is idle.
			state := "idle in transaction"
			query := "%"
			if committed {
				state = "idle"
				query = "select pg_catalog.pg_advisory_unlock%"
			}
			var pid, count int
			if err := f.installer.QueryRow(f.ctx, `select count(*),coalesce(min(a.pid),0) from pg_catalog.pg_stat_activity a
    where a.datname=current_database() and a.application_name=(select holder from notes.tesl_schema_leases where name='row:Note:2:0')
    and a.state=$1 and a.query like $2`, state, query).Scan(&count, &pid); err != nil || count != 1 {
				t.Fatal("exact batch backend selection", count, pid, err)
			}
			var killed bool
			if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_terminate_backend($1)", pid).Scan(&killed); err != nil || !killed {
				t.Fatal("kill exact batch backend", killed, err)
			}
			pauses[0].resume()
			select {
			case err := <-done:
				if err == nil {
					t.Fatalf("backend kill reported Contract success\n%s", output.String())
				}
			case <-time.After(15 * time.Second):
				t.Fatal("killed backend did not stop Contract")
			}
			var marker, processing, rows int
			var cursor *string
			var retired bool
			if err := request.QueryRow(f.ctx, `select (select _tesl_v from notes.notes where id='one'),
    (select count(*) from notes.tesl_row_processing),rows_done,last_pk::text,
    exists(select 1 from notes.tesl_schema_versions where step='retired' and version=2)
    from notes.tesl_schema_backfill_shards where lease_name='row:Note:2:0'`).Scan(&marker, &processing, &rows, &cursor, &retired); err != nil {
				t.Fatal(err)
			}
			if committed {
				if marker != 2 || processing != 1 || rows != 1 || cursor == nil || *cursor != `"one"` || retired {
					t.Fatal("committed row/latch/cursor did not survive backend loss", marker, processing, rows, cursor, retired)
				}
			} else if marker != 1 || processing != 0 || rows != 0 || cursor != nil || retired {
				t.Fatal("failed batch partially committed row/latch/cursor", marker, processing, rows, cursor, retired)
			}
			// The failed process releases its fenced lease; a new exact generated
			// Contract process resumes from durable state and converges without edits.
			pgForwardNativeRun(t, f, root, "v2", "contract", true)
			var floor int
			if err := request.QueryRow(f.ctx, "select compat_floor from notes.tesl_schema_state").Scan(&floor); err != nil || floor != 2 {
				t.Fatal("crash recovery did not converge", floor, err)
			}
		})
	}
}

func TestPgRowStagedNullabilityAllowsWritesAndPublishesExactProof(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated staged Contract apps required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	pgCallRowAccessApp(t, f.ctx, v2, "POST", "/one", 200)
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-contract-ddl-lock-busy", hit: 1}, {name: "row-contract-after-validate-not-null-check", hit: 1}})
	// An independent long reader is allowed to outlive floor publication.
	// Short exclusive DDL attempts must never queue in front of new writes.
	reader, err := request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Rollback(f.ctx) })
	if _, err = reader.Exec(f.ctx, "select id from notes.notes"); err != nil {
		t.Fatal(err)
	}
	command := pgForwardNativeCommand(f, root, "v2", "contract")
	command.Env = append(command.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	var output pgRowAppOutput
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait(); close(done) }()
	t.Cleanup(func() {
		for _, p := range pauses {
			p.resume()
		}
		_ = command.Process.Kill()
		<-done
	})
	wait := func(index int) {
		t.Helper()
		select {
		case <-pauses[index].arrived:
		case err := <-done:
			t.Fatalf("Contract before stage%d: %v\n%s", index, err, output.String())
		case <-time.After(20 * time.Second):
			t.Fatal("missing stage boundary", index, output.String())
		}
	}
	wait(0)
	for range 3 {
		pgCallRowAccessApp(t, f.ctx, v2, "PUT", "/one", 200)
	}
	if err := reader.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	pauses[0].resume()
	wait(1)
	var validation, exclusive bool
	if err := f.installer.QueryRow(f.ctx, `select exists(select 1 from pg_locks where relation='notes.notes'::regclass and granted and mode='ShareUpdateExclusiveLock'),
 exists(select 1 from pg_locks where relation='notes.notes'::regclass and mode='AccessExclusiveLock')`).Scan(&validation, &exclusive); err != nil || !validation || exclusive {
		t.Fatal("validation must hold only its writer-compatible table lock", validation, exclusive, err)
	}
	var unvalidated int
	if err := request.QueryRow(f.ctx, `select count(*) from pg_constraint where conrelid='notes.notes'::regclass and contype='c' and not convalidated`).Scan(&unvalidated); err != nil || unvalidated != 1 {
		t.Fatal("uncommitted validation lost its exact durable predecessor", unvalidated, err)
	}
	pgCallRowAccessApp(t, f.ctx, v2, "POST", "/two", 200)
	pgCallRowAccessApp(t, f.ctx, v2, "PUT", "/one", 200)
	pgCallRowAccessApp(t, f.ctx, v2, "GET", "/all", 200)
	pauses[1].resume()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("staged Contract failed: %v\n%s", err, output.String())
		}
	case <-time.After(20 * time.Second):
		t.Fatal("staged Contract did not finish")
	}
	var checks int
	var required bool
	if err := request.QueryRow(f.ctx, `select (select count(*) from pg_constraint where conrelid='notes.notes'::regclass and contype='c'),
 (select attnotnull from pg_attribute where attrelid='notes.notes'::regclass and attname='count')`).Scan(&checks, &required); err != nil || checks != 0 || !required {
		t.Fatal("exact temporary proof cleanup and required column", checks, required, err)
	}
	pgCallRowAccessApp(t, f.ctx, v2, "POST", "/three", 200)
}

func TestPgRowStagedNullabilityCrashReceiptAtomicity(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual generated staged Contract apps required")
	}
	for _, stage := range []string{"add-not-null-check", "validate-not-null-check", "set-not-null", "drop-not-null-check"} {
		t.Run(stage, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.namespace = "notes"
			pgForwardNativeRun(t, f, root, "v1", "install", true)
			pgForwardNativeRun(t, f, root, "v1", "worker", true)
			pgForwardNativeRun(t, f, root, "v2", "worker", true)
			v2 := pgStartRowAccessApp(t, f, root, "v2")
			pgCallRowAccessApp(t, f.ctx, v2, "POST", "/one", 200)
			pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{name: "row-contract-after-" + stage, hit: 1}})[0]
			command := pgForwardNativeCommand(f, root, "v2", "contract")
			command.Env = append(command.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			var output pgRowAppOutput
			command.Stdout = &output
			command.Stderr = &output
			if err := command.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- command.Wait(); close(done) }()
			t.Cleanup(func() { pause.resume(); _ = command.Process.Kill(); <-done })
			select {
			case <-pause.arrived:
			case err := <-done:
				t.Fatalf("Contract before crash: %v\n%s", err, output.String())
			case <-time.After(20 * time.Second):
				t.Fatal("missing staged crash boundary", stage)
			}
			snapshot := func() string {
				t.Helper()
				var value string
				if err := request.QueryRow(f.ctx, `select jsonb_build_array(
    (select coalesce(jsonb_agg(jsonb_build_array(conname,convalidated,conbin::text) order by conname),'[]') from pg_constraint where conrelid='notes.notes'::regclass and contype='c'),
    (select attnotnull from pg_attribute where attrelid='notes.notes'::regclass and attname='count'),
    (select coalesce(jsonb_agg(jsonb_build_array(ordinal,operation_hash) order by ordinal),'[]') from notes.tesl_row_contract_objects))::text`).Scan(&value); err != nil {
					t.Fatal(err)
				}
				return value
			}
			before := snapshot()
			var count, pid int
			if err := f.installer.QueryRow(f.ctx, `select count(*),coalesce(min(pid),0) from pg_stat_activity where datname=current_database() and state='idle in transaction' and query like 'alter table "notes"."notes"%'`).Scan(&count, &pid); err != nil || count != 1 {
				t.Fatal("exact staged DDL backend", count, pid, err)
			}
			var killed bool
			if err := f.installer.QueryRow(f.ctx, "select pg_terminate_backend($1)", pid).Scan(&killed); err != nil || !killed {
				t.Fatal(killed, err)
			}
			pause.resume()
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("killed DDL reported success")
				}
			case <-time.After(15 * time.Second):
				t.Fatal("killed staged DDL did not exit")
			}
			if after := snapshot(); after != before {
				t.Fatal("DDL and receipt did not roll back as exact predecessor", before, after)
			}
			pgForwardNativeRun(t, f, root, "v2", "contract", true)
			pgCallRowAccessApp(t, f.ctx, v2, "POST", "/two", 200)
		})
	}
}
