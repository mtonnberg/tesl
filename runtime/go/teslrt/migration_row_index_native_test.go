//go:build tesl_migration_test

package teslrt

import (
	"context"
	"github.com/jackc/pgx/v5"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPgRowIndexOrdinaryMain(t *testing.T) {
	root := os.Getenv("TESL_ROW_INDEX_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated original index applications required")
	}
	f, _ := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	install := pgRowAdditiveCommand(f, root, "v1", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json")
	if out, err := install.CombinedOutput(); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
	stop := pgRowAdditiveWorker(t, f, root, "v1")
	stop()
	v1 := pgRowAdditiveApp(t, f, root, "v1")
	call := func(base, method, path string) string { return pgCallRowAccessApp(t, ctx, base, method, path, 200) }
	call(v1, "POST", "/one")
	for _, version := range []string{"v2", "v3"} {
		stop = pgRowAdditiveWorker(t, f, root, version)
		current := pgRowAdditiveApp(t, f, root, version)
		call(current, "GET", "/all")
		call(v1, "PUT", "/edit")
		deadline := time.Now().Add(15 * time.Second)
		for {
			var unfinished int
			err := f.worker.QueryRow(ctx, "select count(*) from notes.tesl_schema_index where state<>'valid'").Scan(&unfinished)
			if err == nil && unfinished == 0 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("index worker did not finish", unfinished, err)
			}
			time.Sleep(20 * time.Millisecond)
		}
		stop()
	}
	var jobs, valid, processing, shards int
	if err := f.worker.QueryRow(ctx, `select (select count(*) from notes.tesl_schema_index),(select count(*) from notes.tesl_schema_index where state='valid'),(select count(*) from notes.tesl_row_processing),(select count(*) from notes.tesl_schema_backfill_shards)`).Scan(&jobs, &valid, &processing, &shards); err != nil || jobs != 2 || valid != 2 || processing != 0 || shards != 0 {
		t.Fatalf("durable index inventory %d/%d ABI=%d shards=%d: %v", jobs, valid, processing, shards, err)
	}
	body := call(v1, "GET", "/all")
	if !strings.Contains(body, `"active":true`) {
		t.Fatal("old writer update missing", body)
	}
}

func TestPgRowIndexCatchupBuildsIntermediateJobs(t *testing.T) {
	root := os.Getenv("TESL_ROW_INDEX_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated original index applications required")
	}
	f, _ := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	install := pgRowAdditiveCommand(f, root, "v1", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json")
	if out, err := install.CombinedOutput(); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
	pgRowAdditiveWorker(t, f, root, "v1")()
	v1 := pgRowAdditiveApp(t, f, root, "v1")
	pgCallRowAccessApp(t, ctx, v1, "POST", "/one", 200)
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"index-before-create", 1}})
	defer pauses[0].resume()
	cmd := pgRowAdditiveCommand(f, root, "v3", "--schema", "worker", "--json")
	cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"), "TESL_SCHEMA_POLL_S=1")
	output, _ := pgRowAdditiveProcess(t, cmd)
	select {
	case <-pauses[0].arrived:
	case <-time.After(15 * time.Second):
		t.Fatal("latest worker did not reach retained index work", output.String())
	}
	if strings.Contains(output.String(), `"kind":"schema-worker-ready"`) {
		t.Fatal("catch-up published readiness before its required index", output.String())
	}
	// Retained V1 remains a valid reader/writer during additive catch-up.
	pgCallRowAccessApp(t, ctx, v1, "PUT", "/edit", 200)
	pauses[0].resume()
	ready, stopReady := context.WithTimeout(ctx, 15*time.Second)
	defer stopReady()
	if !output.WaitContains(ready, `"kind":"schema-worker-ready"`) {
		t.Fatal("latest worker did not finish both retained index jobs", output.String())
	}
	var version, minimum, jobs, valid int
	if err := f.worker.QueryRow(ctx, `select current,min_version,
 (select count(*) from notes.tesl_schema_index),
 (select count(*) from notes.tesl_schema_index where state='valid') from notes.tesl_schema_state`).Scan(&version, &minimum, &jobs, &valid); err != nil || version != 3 || minimum != 1 || jobs != 2 || valid != 2 {
		t.Fatal("catch-up lost an intermediate index or changed admission", version, minimum, jobs, valid, err)
	}
	v3 := pgRowAdditiveApp(t, f, root, "v3")
	pgCallRowAccessApp(t, ctx, v3, "POST", "/two", 200)
	body := pgCallRowAccessApp(t, ctx, v3, "GET", "/all", 200)
	if !strings.Contains(body, `"active":true`) || !strings.Contains(body, `"Something"`) {
		t.Fatal("catch-up lost old writes or latest row shape", body)
	}
}

// Both admission observations use untouched original Main binaries. The native
// blocker and cancellation affect ordinary database work, never control rows.
func TestPgRowIndexPendingFailedAndValidOrdinaryMain(t *testing.T) {
	root := os.Getenv("TESL_ROW_INDEX_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated original index applications required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	install := pgRowAdditiveCommand(f, root, "v1", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json")
	if out, err := install.CombinedOutput(); err != nil {
		t.Fatalf("install: %v %s", err, out)
	}
	pgRowAdditiveWorker(t, f, root, "v1")()
	v1 := pgRowAdditiveApp(t, f, root, "v1")
	call := func(base, method, path string) { pgCallRowAccessApp(t, ctx, base, method, path, 200) }
	call(v1, "POST", "/one")
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"index-before-create", 1}, {"index-before-cleanup", 1}, {"index-before-create", 3}, {"index-before-valid", 2}, {"row-index-readiness-pending", 1}, {"row-index-readiness-pending", 2}})
	socket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	await := func(i int) {
		select {
		case <-pauses[i].arrived:
		case <-time.After(10 * time.Second):
			t.Fatalf("index boundary %d did not arrive", i)
		}
	}
	startWorker := func(version string) (*pgRowAppOutput, func()) {
		cmd := pgRowAdditiveCommand(f, root, version, "--schema", "worker", "--json")
		cmd.Env = append(cmd.Env, socket, "TESL_SCHEMA_POLL_S=1")
		return pgRowAdditiveProcess(t, cmd)
	}
	output, stopV2 := startWorker("v2")
	t.Cleanup(func() {
		for _, p := range pauses {
			p.resume()
		}
	})
	fenceFree := func() bool {
		tx, err := f.worker.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(ctx) }()
		var free bool
		if err := tx.QueryRow(ctx, "select pg_catalog.pg_try_advisory_xact_lock(fence_ns,2) from notes.tesl_schema_meta where id=1").Scan(&free); err != nil {
			t.Fatal(err)
		}
		return free
	}
	await(0)
	if fenceFree() {
		t.Fatal("active index DDL actor lost its version fence")
	}
	if !strings.Contains(output.String(), `"kind":"schema-worker-ready"`) {
		t.Fatal("fixed-width worker was not ready before build", output.String())
	}
	v2 := pgRowAdditiveApp(t, f, root, "v2")
	call(v2, "PUT", "/edit")
	call(v1, "GET", "/all")
	blocker, err := request.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = blocker.Rollback(context.Background()) }()
	if _, err := blocker.Exec(ctx, "lock notes.notes in row exclusive mode"); err != nil {
		t.Fatal(err)
	}
	pauses[0].resume()
	var pid int
	deadline := time.Now().Add(10 * time.Second)
	for {
		err = f.worker.QueryRow(ctx, `select p.pid from pg_catalog.pg_stat_progress_create_index p where p.datid=(select oid from pg_catalog.pg_database where datname=current_database()) and p.phase='waiting for writers before build'`).Scan(&pid)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("concurrent build never waited on actual writer", err, output.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	var canceled bool
	if err := f.worker.QueryRow(ctx, "select pg_catalog.pg_cancel_backend($1)", pid).Scan(&canceled); err != nil || !canceled {
		t.Fatal("cancel actual CIC", canceled, err)
	}
	await(1)
	var state string
	if err := f.worker.QueryRow(ctx, "select state from notes.tesl_schema_index where version=2").Scan(&state); err != nil || state != "failed" {
		t.Fatal("failed build was not durably recorded", state, err)
	}
	call(v1, "PUT", "/edit")
	call(v2, "GET", "/all")
	if err := blocker.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	pauses[1].resume()
	deadline = time.Now().Add(10 * time.Second)
	for {
		err = f.worker.QueryRow(ctx, "select state from notes.tesl_schema_index where version=2").Scan(&state)
		if err == nil && state == "valid" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("failed job did not recover", state, err, output.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	deadline = time.Now().Add(10 * time.Second)
	for !fenceFree() {
		if time.Now().After(deadline) {
			t.Fatal("idle row index actor retained retiring version fence")
		}
		time.Sleep(10 * time.Millisecond)
	}
	var actors int
	if err := f.worker.QueryRow(ctx, "select count(*) from pg_catalog.pg_stat_activity where datname=current_database() and usename=$1 and application_name like 'tesl-exec:%'", f.roles.Worker).Scan(&actors); err != nil || actors < 2 {
		t.Fatal("idle fence witness lost live index worker", actors, err)
	}
	defer stopV2() // The old index worker also observes the later additive job.
	output3, stopV3 := startWorker("v3")
	await(2)
	if strings.Contains(output3.String(), `"kind":"schema-worker-ready"`) {
		t.Fatal("unbounded writer became ready before build", output3.String())
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	_, port, _ := net.SplitHostPort(address)
	_ = listener.Close()
	cmd := pgRowAdditiveCommand(f, root, "v3")
	cmd.Env = append(cmd.Env, "ROW_PORT="+port, socket)
	appOutput, _ := pgRowAdditiveProcess(t, cmd)
	await(4)
	call(v1, "PUT", "/edit")
	call(v2, "GET", "/all")
	pauses[2].resume()
	await(3)
	var physical bool
	err = f.worker.QueryRow(ctx, `select i.indisvalid and i.indisready and i.indislive from pg_catalog.pg_index i join pg_catalog.pg_class c on c.oid=i.indexrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='notes' and c.relname='token_lookup'`).Scan(&physical)
	if err != nil || !physical {
		t.Fatal("second readiness test lacks physical valid index", physical, err)
	}
	pauses[4].resume()
	await(5)
	if strings.Contains(output3.String(), `"kind":"schema-worker-ready"`) {
		t.Fatal("unbounded writer ignored pending protected validity")
	}
	call(v2, "PUT", "/edit")
	pauses[3].resume()
	pauses[5].resume()
	url := "http://" + address
	client := http.Client{Timeout: time.Second}
	deadline = time.Now().Add(10 * time.Second)
	for {
		response, err := client.Get(url + "/health")
		if err == nil {
			_ = response.Body.Close()
			if response.StatusCode == 200 {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("current app did not resume after both validity records", appOutput.String(), output3.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	call(url, "POST", "/two")
	call(v1, "PUT", "/edit")
	call(url, "GET", "/all")
	stopV3()
}

func TestPgRowIndexRegistrationAtomicOrdinarySource(t *testing.T) {
	root := os.Getenv("TESL_ROW_INDEX_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated original index applications required")
	}
	f, _ := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	install := pgRowAdditiveCommand(f, root, "v1", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json")
	if out, err := install.CombinedOutput(); err != nil {
		t.Fatalf("install %v %s", err, out)
	}
	pgRowAdditiveWorker(t, f, root, "v1")()
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"row-index-before-register", 1}, {"row-index-after-register", 1}})
	cmd := pgRowAdditiveCommand(f, root, "v2", "--schema", "worker", "--json")
	cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	var output pgRowAppOutput
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait(); close(done) }()
	t.Cleanup(func() {
		for _, p := range pauses {
			p.resume()
		}
		_ = cmd.Process.Kill()
		<-done
	})
	await := func(i int) {
		select {
		case <-pauses[i].arrived:
		case err := <-done:
			t.Fatalf("registration worker exited %v %s", err, output.String())
		case <-time.After(10 * time.Second):
			t.Fatal("registration did not reach boundary", i, output.String())
		}
	}
	empty := func() {
		var jobs, leases, objects int
		err := f.worker.QueryRow(ctx, `select (select count(*) from notes.tesl_schema_index),(select count(*) from notes.tesl_schema_leases where name like 'index:%'),(select count(*) from notes.tesl_schema_expansion_objects where version=2)`).Scan(&jobs, &leases, &objects)
		if err != nil || jobs != 0 || leases != 0 || objects != 0 {
			t.Fatal("registration escaped rollback", jobs, leases, objects, err)
		}
	}
	await(0)
	for _, wrong := range []bool{true, false} {
		probe := pgRowAdditiveCommand(f, root, "v2")
		probe.Path = filepath.Join(root, "v2", "index-probe")
		probe.Args = []string{probe.Path}
		expected := "test rollback after exact row index registration"
		if wrong {
			probe.Env = append(probe.Env, "ROW_INDEX_WRONG=1")
			expected = "row index registration differs from checked source operation"
		}
		out, err := probe.CombinedOutput()
		empty()
		if err != nil || !strings.Contains(string(out), expected) {
			t.Fatalf("production registration probe wrong=%v %v %s", wrong, err, out)
		}
		empty()
	}
	pauses[0].resume()
	await(1)
	empty()
	var pid int
	if err := f.worker.QueryRow(ctx, `select pid from pg_catalog.pg_stat_activity where datname=current_database() and usename=$1 and state='idle in transaction' and query like '%tesl_register_row_index%'`, f.roles.Worker).Scan(&pid); err != nil {
		t.Fatal("locate registering backend", err)
	}
	var killed bool
	if err := f.worker.QueryRow(ctx, "select pg_catalog.pg_terminate_backend($1)", pid).Scan(&killed); err != nil || !killed {
		t.Fatal("terminate registration backend", killed, err)
	}
	pauses[1].resume()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("killed registration worker claimed success")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("killed registration did not exit")
	}
	empty()
	stop := pgRowAdditiveWorker(t, f, root, "v2")
	defer stop()
	deadline := time.Now().Add(10 * time.Second)
	for {
		var state string
		err := f.worker.QueryRow(ctx, "select state from notes.tesl_schema_index where version=2").Scan(&state)
		if err == nil && state == "valid" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("fresh original worker did not recover registration", state, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestPgRowIndexServicePreservesNonphysicalV1Worker(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	state, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	b, err := pgCompiledRowBaseline(db)
	if err != nil || b.target != nil || b.physical != nil {
		t.Fatal("probe is not original checked nonphysical V1", err)
	}
	conn, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	service, cancel := context.WithCancel(f.ctx)
	defer cancel()
	ready := make(chan struct{}, 1)
	done := make(chan error, 1)
	go func() {
		done <- pgRunRowIndexServices(service, conn, f.worker.Config().Copy(), b, f.roles, state, func(current PgMigrationControlState) error { ready <- struct{}{}; return nil })
		close(done)
	}()
	select {
	case <-ready:
	case err := <-done:
		t.Fatal("nonphysical V1 lost worker readiness", err)
	case <-time.After(10 * time.Second):
		t.Fatal("nonphysical V1 never became ready")
	}
	var free bool
	tx, err := f.worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	err = tx.QueryRow(f.ctx, "select pg_catalog.pg_try_advisory_xact_lock(fence_ns,1) from "+quoteIdentifier(f.namespace)+".tesl_schema_meta where id=1").Scan(&free)
	_ = tx.Rollback(f.ctx)
	if err != nil || !free {
		t.Fatal("original V1 idle service acquired permanent writer fence", free, err)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal("V1 worker shutdown", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("V1 worker did not stop")
	}
	if !conn.IsClosed() {
		t.Fatal("V1 service retained transferred setup connection")
	}
}
