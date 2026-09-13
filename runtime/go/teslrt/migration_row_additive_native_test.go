//go:build tesl_migration_test

package teslrt

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// These programs contain the compiler-emitted cmd/app. Configuration is evaluated
// by Tesl; this harness supplies ordinary environment values and schema CLI flags.
func pgRowAdditiveCommand(f *pgControlTestFixture, root, version string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(f.ctx, filepath.Join(root, version, "app"), args...)
	ddl := f.worker.Config().ConnString()
	if len(args) > 1 && args[1] == "install" {
		ddl = f.installer.Config().ConnString()
	}
	config := f.worker.Config()
	cmd.Env = append(os.Environ(), "GORACE=atexit_sleep_ms=0", "TESL_MIGRATION_TEST_SOCKET=",
		"ROW_DATABASE="+config.Database, "ROW_LOGIN="+f.roles.Request, "ROW_OWNER="+f.roles.Owner,
		"ROW_WORKER="+f.roles.Worker, "ROW_REQUEST="+f.roles.Request, "ROW_DDL="+ddl,
		"ROW_HOST="+config.Host, "ROW_DB_PORT="+strconv.Itoa(int(config.Port)))
	return cmd
}
func pgRowAdditiveProcess(t *testing.T, cmd *exec.Cmd) (*pgRowAppOutput, func()) {
	t.Helper()
	output := &pgRowAppOutput{}
	cmd.Stdout = output
	cmd.Stderr = output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait(); close(done) }()
	stopped := false
	stop := func() {
		if stopped {
			return
		}
		stopped = true
		_ = cmd.Process.Signal(os.Interrupt)
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("ordinary main stopped with %v: %s", err, output.String())
			}
		case <-time.After(10 * time.Second):
			_ = cmd.Process.Kill()
			<-done
			t.Error("ordinary main did not stop")
		}
	}
	t.Cleanup(func() {
		if t.Failed() {
			t.Log(output.String())
		}
		stop()
	})
	return output, stop
}
func pgRowAdditiveWorker(t *testing.T, f *pgControlTestFixture, root, version string) func() {
	t.Helper()
	output, stop := pgRowAdditiveProcess(t, pgRowAdditiveCommand(f, root, version, "--schema", "worker", "--json"))
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(output.String(), `"kind":"schema-worker-ready"`) {
			return stop
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("ordinary schema worker did not become ready: %s", output.String())
	return stop
}
func pgRowAdditiveApp(t *testing.T, f *pgControlTestFixture, root, version string) string {
	return pgRowAdditiveAppWith(t, f, root, version)
}
func pgRowAdditiveAppWith(t *testing.T, f *pgControlTestFixture, root, version string, extra ...string) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	_, port, _ := net.SplitHostPort(address)
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	cmd := pgRowAdditiveCommand(f, root, version)
	cmd.Env = append(append(cmd.Env, "ROW_PORT="+port), extra...)
	output, _ := pgRowAdditiveProcess(t, cmd)
	url := "http://" + address
	client := &http.Client{Timeout: time.Second}
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		response, err := client.Get(url + "/health")
		if err == nil && response != nil {
			_ = response.Body.Close()
			if response.StatusCode == 200 {
				return url
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("ordinary Main did not serve: %s", output.String())
	return ""
}
func TestPgRowAdditivePrefixOrdinaryMain(t *testing.T) {
	root := os.Getenv("TESL_ROW_ADDITIVE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated additive prefix programs required")
	}
	f, _ := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	install := pgRowAdditiveCommand(f, root, "v1", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json")
	if out, err := install.CombinedOutput(); err != nil {
		t.Fatalf("ordinary install: %v %s", err, out)
	}
	stopV1 := pgRowAdditiveWorker(t, f, root, "v1")
	stopV1()
	v1 := pgRowAdditiveApp(t, f, root, "v1")
	call := func(base, method, path string) string { return pgCallRowAccessApp(t, ctx, base, method, path, 200) }
	call(v1, "POST", "/one")
	stopV2 := pgRowAdditiveWorker(t, f, root, "v2")
	var current, floor, priority, marker, processing, shards, receipts int
	var memoNull bool
	err := f.worker.QueryRow(ctx, `select s.current,s.compat_floor,n.priority,n._tesl_v,n.memo is null,
 (select count(*) from notes.tesl_row_processing),(select count(*) from notes.tesl_schema_backfill_shards),
 (select count(*) from notes.tesl_schema_versions where version=2)
 from notes.tesl_schema_state s,notes.notes n where n.id='one'`).Scan(&current, &floor, &priority, &marker, &memoNull, &processing, &shards, &receipts)
	if err != nil || current != 2 || floor != 1 || priority != 9 || marker != 1 || !memoNull || processing != 0 || shards != 0 || receipts != 1 {
		t.Fatalf("durable additive state current=%d floor=%d priority=%d marker=%d null=%v processing=%d shards=%d receipts=%d: %v", current, floor, priority, marker, memoNull, processing, shards, receipts, err)
	}
	v2 := pgRowAdditiveApp(t, f, root, "v2")
	body := call(v2, "GET", "/all")
	if !strings.Contains(body, `"priority":9`) {
		t.Fatal("additive reader lost checked default", body)
	}
	call(v1, "POST", "/two")
	call(v1, "GET", "/all")
	stopV2()
	if out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "worker", "--json").CombinedOutput(); err == nil || !strings.Contains(string(out), "close additive epoch first") {
		t.Fatalf("transform did not require explicit epoch closure: %v %s", err, out)
	}
	var pending int
	if err := f.worker.QueryRow(ctx, "select count(*) from notes.tesl_row_physical where version=3").Scan(&pending); err != nil || pending != 0 {
		t.Fatal("refused transform published a manifest", pending, err)
	}
	preview, err := pgRowAdditiveCommand(f, root, "v2", "--schema", "close-epoch", "--through", "V2", "--dry-run", "--json").CombinedOutput()
	if err != nil || !strings.Contains(string(preview), `"version":1`) || !strings.Contains(string(preview), `"recentInstances":[{`) {
		t.Fatalf("epoch preview lost idle live V1: %v %s", err, preview)
	}
	if out, err := pgRowAdditiveCommand(f, root, "v2", "--schema", "close-epoch", "--through", "V2", "--json").CombinedOutput(); err == nil || !strings.Contains(string(out), "recent retiring instances") {
		t.Fatalf("epoch closed over live V1 without force: %v %s", err, out)
	}
	out, err := pgRowAdditiveCommand(f, root, "v2", "--schema", "close-epoch", "--through", "V2", "--force", "--json").CombinedOutput()
	if err != nil || !strings.Contains(string(out), `"kind":"schema-epoch-closed"`) {
		t.Fatalf("explicit forced epoch closure: %v %s", err, out)
	}
	pgCallRowAccessApp(t, ctx, v1, "GET", "/all", 503)
	call(v2, "GET", "/all")
	stopV3 := pgRowAdditiveWorker(t, f, root, "v3")
	deadline := time.Now().Add(15 * time.Second)
	for {
		var count int
		err := f.worker.QueryRow(ctx, "select count(*) from notes.notes where _tesl_v=2 and priority=9 and owner='writer' and count=7").Scan(&count)
		if err == nil && count == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("transform did not preserve additive values", count, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	v3 := pgRowAdditiveApp(t, f, root, "v3")
	body = call(v3, "GET", "/all")
	if strings.Count(body, `"count":7`) != 2 {
		t.Fatal("V3 ordinary HTTP result differs", body)
	}
	pgCallRowAccessApp(t, ctx, v1, "GET", "/all", 503)
	var admitted int
	err = f.worker.QueryRow(ctx, "select notes.tesl_admit(1)").Scan(&admitted)
	if err == nil || !strings.Contains(err.Error(), "is retired") {
		t.Fatal("V1 refusal did not match explicit retirement floor", err)
	}
	call(v2, "GET", "/all")
	stopV3()
	t.Logf("authentic ordinary Main V1→additive V2→transform V3: %s", body)
}

func pgRowAdditiveInstalled(t *testing.T) (string, *pgControlTestFixture) {
	t.Helper()
	root := os.Getenv("TESL_ROW_ADDITIVE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated additive programs required")
	}
	f, _ := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	cmd := pgRowAdditiveCommand(f, root, "v1", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ordinary install: %v %s", err, out)
	}
	stop := pgRowAdditiveWorker(t, f, root, "v1")
	stop()
	return root, f
}
func TestPgRowAdditiveDefaultAndEpochDrift(t *testing.T) {
	root, f := pgRowAdditiveInstalled(t)
	stop := pgRowAdditiveWorker(t, f, root, "v2")
	stop()
	status := func(t *testing.T, want string) {
		t.Helper()
		out, err := pgRowAdditiveCommand(f, root, "v2", "--schema", "status", "--json").CombinedOutput()
		if want == "" {
			if err != nil {
				t.Fatalf("clean ordinary status: %v %s", err, out)
			}
		} else if err == nil || !strings.Contains(string(out), want) {
			t.Fatalf("wrong drift refusal: want %q got %v %s", want, err, out)
		}
	}
	status(t, "")
	for _, tc := range []struct{ name, mutate, restore, want string }{
		{"default", "alter table notes.notes alter column priority set default 8", "alter table notes.notes alter column priority set default 9", "row baseline table"},
		{"epoch", "update notes.tesl_row_physical set epoch_preserving=false where version=2", "update notes.tesl_row_physical set epoch_preserving=true where version=2", "physical epoch mode differs"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := f.installer.Exec(f.ctx, tc.mutate); err != nil {
				t.Fatal(err)
			}
			defer func() {
				if _, err := f.installer.Exec(f.ctx, tc.restore); err != nil {
					t.Error(err)
				}
			}()
			status(t, tc.want)
		})
	}
	status(t, "")
}
func TestPgRowAdditiveCrashPrefixes(t *testing.T) {
	for _, tc := range []struct {
		boundary          string
		columns, receipts int
	}{
		{"row-forward-after-manifest", 0, 0},
		{"row-forward-after-intent", 0, 0},
		{"row-forward-after-ddl", 0, 0},
		{"row-forward-after-receipt", 1, 1},
	} {
		t.Run(tc.boundary, func(t *testing.T) {
			root, f := pgRowAdditiveInstalled(t)
			v1 := pgRowAdditiveApp(t, f, root, "v1")
			pgCallRowAccessApp(t, f.ctx, v1, "POST", "/one", 200)
			pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{tc.boundary, 1}})
			defer pauses[0].resume()
			cmd := pgRowAdditiveCommand(f, root, "v2", "--schema", "worker", "--json")
			cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			var output pgRowAppOutput
			cmd.Stdout = &output
			cmd.Stderr = &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait(); close(done) }()
			t.Cleanup(func() { _ = cmd.Process.Kill(); <-done })
			select {
			case <-pauses[0].arrived:
			case err := <-done:
				t.Fatalf("worker before crash boundary: %v %s", err, output.String())
			case <-time.After(15 * time.Second):
				t.Fatal("worker did not reach additive crash boundary", output.String())
			}
			if err := cmd.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("killed worker succeeded")
				}
			case <-time.After(10 * time.Second):
				t.Fatal("killed worker did not exit")
			}
			pauses[0].resume()
			// Both DDL and its receipt are read from another connection after the child
			// process has died. A returned in-memory prefix cannot satisfy this assertion.
			var current, columns, receipts, processing int
			err := f.worker.QueryRow(f.ctx, `select current,
   (select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name in ('priority','memo')),
   (select count(*) from notes.tesl_schema_expansion_objects where version=2),
   (select count(*) from notes.tesl_row_processing) from notes.tesl_schema_state`).Scan(&current, &columns, &receipts, &processing)
			if err != nil || current != 1 || columns != tc.columns || receipts != tc.receipts || processing != 0 {
				t.Fatalf("crash prefix current=%d columns=%d receipts=%d processing=%d: %v", current, columns, receipts, processing, err)
			}
			pgCallRowAccessApp(t, f.ctx, v1, "GET", "/all", 200)
			stop := pgRowAdditiveWorker(t, f, root, "v2")
			stop()
			var priority, marker int
			var missing bool
			if err := f.worker.QueryRow(f.ctx, "select priority,memo is null,_tesl_v from notes.notes where id='one'").Scan(&priority, &missing, &marker); err != nil || priority != 9 || !missing || marker != 1 {
				t.Fatal("resumed additive lost exact default/null/generation", priority, missing, marker, err)
			}
		})
	}
}

func TestPgRowAdditiveHeartbeatIndependentPoolAndRecovery(t *testing.T) {
	root, f := pgRowAdditiveInstalled(t)
	pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"writer-fence", 1}})[0]
	defer pause.resume()
	app := pgRowAdditiveAppWith(t, f, root, "v1", "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	var initial time.Time
	if err := f.worker.QueryRow(f.ctx, "select max(last_seen) from notes.tesl_schema_instances where version=1").Scan(&initial); err != nil {
		t.Fatal(err)
	}
	finished := make(chan error, 1)
	go func() {
		request, err := http.NewRequestWithContext(f.ctx, "POST", app+"/one", nil)
		if err == nil {
			var response *http.Response
			response, err = http.DefaultClient.Do(request)
			if err == nil {
				_ = response.Body.Close()
				if response.StatusCode != 200 {
					err = fmt.Errorf("held request status %d", response.StatusCode)
				}
			}
		}
		finished <- err
	}()
	select {
	case <-pause.arrived:
	case <-time.After(10 * time.Second):
		t.Fatal("pool-size-one request did not reach held transaction")
	}

	deadline := time.Now().Add(10 * time.Second)
	for {
		var renewed time.Time
		err := f.worker.QueryRow(f.ctx, "select max(last_seen) from notes.tesl_schema_instances where version=1").Scan(&renewed)
		if err == nil && renewed.After(initial) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("held application pool starved independent heartbeat", err)
		}
		time.Sleep(25 * time.Millisecond)
	}
	pause.resume()
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("held request did not complete")
	}
	// Existing application connection remains usable. Only the dedicated monitor
	// is terminated; login denial prevents its reconnect until explicitly restored.
	if _, err := f.installer.Exec(f.ctx, "alter role "+quoteIdentifier(f.roles.Request)+" nologin"); err != nil {
		t.Fatal(err)
	}
	restore := func() {
		if _, err := f.installer.Exec(f.ctx, "alter role "+quoteIdentifier(f.roles.Request)+" login"); err != nil {
			t.Error(err)
		}
	}
	defer restore()
	if _, err := f.installer.Exec(f.ctx, "select pg_catalog.pg_terminate_backend(a.pid) from pg_catalog.pg_stat_activity a join notes.tesl_schema_instances i on i.instance=a.application_name where i.version=1 and a.usename=$1", f.roles.Request); err != nil {
		t.Fatal(err)
	}
	status := func() int {
		request, err := http.NewRequestWithContext(f.ctx, "GET", app+"/all", nil)
		if err != nil {
			t.Fatal(err)
		}
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = response.Body.Close() }()
		return response.StatusCode
	}
	deadline = time.Now().Add(10 * time.Second)
	for status() != 503 {
		if time.Now().After(deadline) {
			t.Fatal("failed heartbeat did not refuse application admission")
		}
		time.Sleep(50 * time.Millisecond)
	}
	restore()
	deadline = time.Now().Add(12 * time.Second)
	for status() != 200 {
		if time.Now().After(deadline) {
			t.Fatal("successful heartbeat reconnect did not recover admission")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func pgRowEpochNativeCommand(t *testing.T, cmd *exec.Cmd) (*pgRowAppOutput, <-chan error) {
	t.Helper()
	out := &pgRowAppOutput{}
	cmd.Stdout = out
	cmd.Stderr = out
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
			t.Error("epoch command cleanup timed out")
		}
	})
	return out, done
}
func TestPgRowAdditiveEpochForcedDrainDeadline(t *testing.T) {
	root, f := pgRowAdditiveInstalled(t)
	stop := pgRowAdditiveWorker(t, f, root, "v2")
	stop()
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"writer-fence", 1}, {"row-epoch-compatibility-busy", 1}})
	defer func() {
		for _, p := range pauses {
			p.resume()
		}
	}()
	socket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	old := pgRowAdditiveAppWith(t, f, root, "v1", socket)
	current := pgRowAdditiveApp(t, f, root, "v2")
	requestDone := make(chan error, 1)
	go func() {
		req, _ := http.NewRequestWithContext(f.ctx, "POST", old+"/one", nil)
		response, err := http.DefaultClient.Do(req)
		if err == nil {
			_ = response.Body.Close()
			if response.StatusCode != 200 {
				err = fmt.Errorf("retiring write returned %d", response.StatusCode)
			}
		}
		requestDone <- err
	}()
	select {
	case <-pauses[0].arrived:
	case err := <-requestDone:
		t.Fatal("old transaction did not pause", err)
	case <-time.After(10 * time.Second):
		t.Fatal("old transaction did not reach writer fence")
	}
	cmd := pgRowAdditiveCommand(f, root, "v2", "--schema", "close-epoch", "--through", "V2", "--force", "--json")
	cmd.Env = append(cmd.Env, socket, "TESL_PG_POOL_LEASE_TIMEOUT_MS=1500")
	output, done := pgRowEpochNativeCommand(t, cmd)
	select {
	case <-pauses[1].arrived:
	case err := <-done:
		t.Fatal("closure did not reach busy retiring fence", err, output.String())
	case <-time.After(10 * time.Second):
		t.Fatal("closure never tried held transaction")
	}
	// The busy path has released every acquired key; the surviving version's
	// ordinary request and monitor must remain available throughout the wait.
	pgCallRowAccessApp(t, f.ctx, current, "GET", "/all", 200)
	pauses[1].resume()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(output.String(), "deadline") {
			t.Fatal("forced closure bypassed held transaction or its deadline", err, output.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("forced closure ignored bounded drain")
	}
	var floor, epochs int
	if err := f.worker.QueryRow(f.ctx, "select compat_floor,(select count(*) from notes.tesl_row_epochs) from notes.tesl_schema_state").Scan(&floor, &epochs); err != nil || floor != 1 || epochs != 0 {
		t.Fatal("failed drain published retirement", floor, epochs, err)
	}
	pauses[0].resume()
	select {
	case err := <-requestDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("original write failed to resume")
	}
	out, err := pgRowAdditiveCommand(f, root, "v2", "--schema", "close-epoch", "--through", "V2", "--force", "--json").CombinedOutput()
	if err != nil {
		t.Fatal("fresh closure after drain", err, string(out))
	}
	pgCallRowAccessApp(t, f.ctx, old, "GET", "/all", 503)
	pgCallRowAccessApp(t, f.ctx, current, "GET", "/all", 200)
}

func TestPgRowAdditiveEpochAtomicPublicationAndInventory(t *testing.T) {
	for _, boundary := range []string{"row-epoch-before-publication", "row-epoch-after-publication", "row-epoch-after-commit"} {
		t.Run(boundary, func(t *testing.T) {
			root, f := pgRowAdditiveInstalled(t)
			stop := pgRowAdditiveWorker(t, f, root, "v2")
			stop()
			pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{boundary, 1}})[0]
			defer pause.resume()
			cmd := pgRowAdditiveCommand(f, root, "v2", "--schema", "close-epoch", "--through", "V2", "--json")
			cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			output, done := pgRowEpochNativeCommand(t, cmd)
			select {
			case <-pause.arrived:
			case err := <-done:
				t.Fatal("close before crash gate", err, output.String())
			case <-time.After(10 * time.Second):
				t.Fatal("close did not reach crash gate", output.String())
			}
			if err := cmd.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("killed close command succeeded")
				}
			case <-time.After(5 * time.Second):
				t.Fatal("killed close command did not exit")
			}
			pause.resume()
			var floor, minimum, epochs, terminal, processing int
			err := f.worker.QueryRow(f.ctx, `select compat_floor,min_version,(select count(*) from notes.tesl_row_epochs),(select count(*) from notes.tesl_schema_versions where version=2 and step<>'expanded'),(select count(*) from notes.tesl_row_processing) from notes.tesl_schema_state`).Scan(&floor, &minimum, &epochs, &terminal, &processing)
			committed := boundary == "row-epoch-after-commit"
			wantFloor, wantEpoch, wantTerminal := 1, 0, 0
			if committed {
				wantFloor, wantEpoch, wantTerminal = 2, 1, 3
			}
			if err != nil || floor != wantFloor || minimum != wantFloor || epochs != wantEpoch || terminal != wantTerminal || processing != 0 {
				t.Fatal("non-atomic epoch publication", floor, minimum, epochs, terminal, processing, err)
			}
			if out, err := pgRowAdditiveCommand(f, root, "v2", "--schema", "close-epoch", "--through", "V2", "--json").CombinedOutput(); err != nil {
				t.Fatal("retry did not preserve exact committed closure", err, string(out))
			}
			for _, probe := range []struct{ name, save, damage, restore, want string }{
				{"entire epoch receipt absent", "create temp table saved_epoch as table notes.tesl_row_epochs", "delete from notes.tesl_row_epochs", "insert into notes.tesl_row_epochs select * from saved_epoch; drop table saved_epoch", "additive"},
				{"terminal slots absent", "create temp table saved_terminal as select * from notes.tesl_schema_versions where version=2 and step<>'expanded'", "delete from notes.tesl_schema_versions where version=2 and step<>'expanded'", "insert into notes.tesl_schema_versions select * from saved_terminal; drop table saved_terminal", "epoch"},
			} {
				t.Run(probe.name, func(t *testing.T) {
					if _, err := f.installer.Exec(f.ctx, probe.save); err != nil {
						t.Fatal(err)
					}
					if _, err := f.installer.Exec(f.ctx, probe.damage); err != nil {
						t.Fatal(err)
					}
					defer func() {
						if _, err := f.installer.Exec(f.ctx, probe.restore); err != nil {
							t.Error(err)
						}
					}()
					out, err := pgRowAdditiveCommand(f, root, "v2", "--schema", "status", "--json").CombinedOutput()
					if err == nil || !strings.Contains(string(out), probe.want) {
						t.Fatal("missing exact epoch inventory accepted", err, string(out))
					}
				})
			}
		})
	}
}

func TestPgRowAdditiveLongEpochAndChainedClosure(t *testing.T) {
	for _, chained := range []bool{false, true} {
		name := "one-shot-V4"
		if chained {
			name = "close-V2-then-close-V4"
		}
		t.Run(name, func(t *testing.T) {
			root, f := pgRowAdditiveInstalled(t)
			old := pgRowAdditiveApp(t, f, root, "v1")
			pgCallRowAccessApp(t, f.ctx, old, "POST", "/one", 200)
			stop := pgRowAdditiveWorker(t, f, root, "v2")
			stop()
			closeEpoch := func(binary, target string) {
				out, err := pgRowAdditiveCommand(f, root, binary, "--schema", "close-epoch", "--through", target, "--force", "--json").CombinedOutput()
				if err != nil {
					t.Fatal("close additive epoch", target, err, string(out))
				}
			}
			if chained {
				closeEpoch("v2", "V2")
				pgCallRowAccessApp(t, f.ctx, old, "GET", "/all", 503)
			}
			second := pgRowAdditiveApp(t, f, root, "v2")
			for _, binary := range []string{"a3", "a4"} {
				stop = pgRowAdditiveWorker(t, f, root, binary)
				stop()
			}
			pgCallRowAccessApp(t, f.ctx, second, "GET", "/all", 200)
			if !chained {
				pgCallRowAccessApp(t, f.ctx, old, "GET", "/all", 200)
			}
			fourth := pgRowAdditiveApp(t, f, root, "a4")
			body := pgCallRowAccessApp(t, f.ctx, fourth, "GET", "/all", 200)
			for _, field := range []string{`"priority":9`, `"stage":3`, `"extra":4`} {
				if !strings.Contains(body, field) {
					t.Fatal("later additive defaults lost", body)
				}
			}
			closeEpoch("a4", "V4")
			var minimum, floor, epochs, slots, processing, generation int
			err := f.worker.QueryRow(f.ctx, `select s.min_version,s.compat_floor,(select count(*) from notes.tesl_row_epochs),(select count(*) from notes.tesl_schema_versions where version between 2 and 4 and step<>'expanded'),(select count(*) from notes.tesl_row_processing),n._tesl_v from notes.tesl_schema_state s,notes.notes n where n.id='one'`).Scan(&minimum, &floor, &epochs, &slots, &processing, &generation)
			wantEpochs := 1
			if chained {
				wantEpochs = 2
			}
			if err != nil || minimum != 4 || floor != 4 || epochs != wantEpochs || slots != 9 || processing != 0 || generation != 1 {
				t.Fatal("long epoch durable state differs", minimum, floor, epochs, slots, processing, generation, err)
			}
			pgCallRowAccessApp(t, f.ctx, second, "GET", "/all", 503)
			pgCallRowAccessApp(t, f.ctx, fourth, "GET", "/all", 200)
			for _, probe := range []struct{ name, save, damage, restore string }{
				{"latest complete epoch missing", "create temp table saved_chain as select * from notes.tesl_row_epochs where through_version=4", "delete from notes.tesl_row_epochs where through_version=4", "insert into notes.tesl_row_epochs select * from saved_chain; drop table saved_chain"},
				{"middle terminal slot missing", "create temp table saved_slot as select * from notes.tesl_schema_versions where version=3 and step='contracting'", "delete from notes.tesl_schema_versions where version=3 and step='contracting'", "insert into notes.tesl_schema_versions select * from saved_slot; drop table saved_slot"},
			} {
				t.Run(probe.name, func(t *testing.T) {
					if _, err := f.installer.Exec(f.ctx, probe.save); err != nil {
						t.Fatal(err)
					}
					if _, err := f.installer.Exec(f.ctx, probe.damage); err != nil {
						t.Fatal(err)
					}
					defer func() {
						if _, err := f.installer.Exec(f.ctx, probe.restore); err != nil {
							t.Error(err)
						}
					}()
					out, err := pgRowAdditiveCommand(f, root, "a4", "--schema", "status", "--json").CombinedOutput()
					if err == nil || (!strings.Contains(string(out), "epoch") && !strings.Contains(string(out), "additive")) {
						t.Fatal("incomplete long epoch admitted", err, string(out))
					}
				})
			}
			if chained {
				if _, err := f.installer.Exec(f.ctx, "update notes.tesl_row_epochs set old_min=1 where through_version=4"); err != nil {
					t.Fatal(err)
				}
				out, err := pgRowAdditiveCommand(f, root, "a4", "--schema", "status", "--json").CombinedOutput()
				if _, restoreErr := f.installer.Exec(f.ctx, "update notes.tesl_row_epochs set old_min=2 where through_version=4"); restoreErr != nil {
					t.Fatal(restoreErr)
				}
				if err == nil || !strings.Contains(string(out), "epoch receipt differs") {
					t.Fatal("wrong predecessor floor admitted", err, string(out))
				}
			}
			if out, err := pgRowAdditiveCommand(f, root, "a4", "--schema", "status", "--json").CombinedOutput(); err != nil {
				t.Fatal("restored complete epoch refused", err, string(out))
			}
		})
	}
}
