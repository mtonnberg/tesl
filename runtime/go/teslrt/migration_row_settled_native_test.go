//go:build tesl_migration_test

package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPgRowSettledActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated applications with checked Contract required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
	call := func(base, method, path string, status int) string {
		return pgCallRowAccessApp(t, f.ctx, base, method, path, status)
	}
	run("v1", "install")
	run("v1", "worker")
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	call(v1, "POST", "/one", 200)
	call(v1, "POST", "/two", 200)
	stopWorker, workerDone := pgStartSettledWorker(t, f, root, "v2")
	deadline := time.Now().Add(10 * time.Second)
	for {
		select {
		case err := <-workerDone:
			t.Fatalf("worker exited before durable provisional completion: %v", err)
		default:
		}
		var converted int
		var provisional bool
		err := f.worker.QueryRow(f.ctx, "select (select count(*) from notes.notes where _tesl_v=2),exists(select 1 from notes.tesl_schema_backfill_shards where state='provisional')").Scan(&converted, &provisional)
		if err == nil && converted == 2 && provisional {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("worker did not provisionally backfill actual V1 rows", converted, provisional, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	stopWorker()
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"row-rmw-before-declare", 1}, {"row-contract-before-compatibility-barrier", 1}, {"row-contract-compatibility-busy", 1}, {"row-contract-after-floor", 1}, {"row-worker-after-prepare", 1}})
	socket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	v2, serverOutput := pgStartRowAccessObservedApp(t, f, root, "v2", socket)
	renamed := pgStartRowAccessApp(t, f, root, "v2query")
	call(v2, "POST", "/three", 200)
	call(v1, "PUT", "/one", 200)
	stopRacingWorker, racingWorkerDone := pgStartSettledWorker(t, f, root, "v2", socket)
	// Release test gates before process cleanup, including failed assertions.
	t.Cleanup(func() {
		for _, pause := range pauses {
			pause.resume()
		}
	})
	select {
	case <-pauses[4].arrived:
	case err := <-racingWorkerDone:
		t.Fatalf("worker exited before prepare/retirement race: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("worker did not reach prepare boundary")
	}
	pending := make(chan error, 1)
	go func() {
		req, _ := http.NewRequestWithContext(f.ctx, "PUT", v2+"/effects", nil)
		response, err := http.DefaultClient.Do(req)
		if err == nil {
			_ = response.Body.Close()
			if response.StatusCode != 200 {
				err = fmt.Errorf("paused update status %d", response.StatusCode)
			}
		}
		pending <- err
	}()
	select {
	case <-pauses[0].arrived:
	case err := <-pending:
		t.Fatalf("original window update did not pause: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("window update never reached captured-argument boundary")
	}
	contract := pgForwardNativeCommand(f, root, "v2", "contract")
	contract.Env = append(contract.Env, socket)
	var output pgRowAppOutput
	contract.Stdout = &output
	contract.Stderr = &output
	if err := contract.Start(); err != nil {
		t.Fatal(err)
	}
	completed := make(chan error, 1)
	go func() { completed <- contract.Wait(); close(completed) }()
	t.Cleanup(func() { _ = contract.Process.Kill(); <-completed })
	select {
	case <-pauses[1].arrived:
		pauses[1].resume()
	case err := <-completed:
		t.Fatalf("contract did not reach compatibility barrier: %v %s", err, output.String())
	case <-time.After(10 * time.Second):
		t.Fatal("contract did not reach compatibility barrier")
	}
	select {
	case <-pauses[2].arrived:
		pauses[2].resume()
	case err := <-completed:
		t.Fatalf("contract did not wait for original transaction: %v %s", err, output.String())
	case <-time.After(10 * time.Second):
		t.Fatal("contract did not report its busy compatibility barrier")
	}
	// A try-lock coordinator must not queue an exclusive waiter that blocks other
	// admitted requests while the paused original transaction owns shared access.
	for i := 0; i < 3; i++ {
		call(renamed, "GET", "/all", 200)
	}
	select {
	case err := <-completed:
		t.Fatalf("contract crossed an active window transaction: %v %s", err, output.String())
	default:
	}
	pauses[0].resume()
	select {
	case err := <-pending:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("original window transaction did not finish")
	}

	if strings.Count(serverOutput.String(), "access-operand {phase=set-multi}") != 1 || strings.Count(serverOutput.String(), "access-operand {phase=where-multi}") != 1 {
		t.Fatal("contract wait re-evaluated captured statement operands", serverOutput.String())
	}
	select {
	case <-pauses[3].arrived:
	case err := <-completed:
		t.Fatalf("contract missed floor-before-DDL boundary: %v %s", err, output.String())
	case <-time.After(10 * time.Second):
		t.Fatal("contract did not publish floor")
	}
	// The retired required column still exists but its checked preparation now
	// permits settled INSERTs before the first destructive object operation.
	var retiredNullable string
	if err := request.QueryRow(f.ctx, "select is_nullable from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='author'").Scan(&retiredNullable); err != nil || retiredNullable != "YES" {
		t.Fatal("floor preceded checked retired-column preparation", retiredNullable, err)
	}
	call(v2, "POST", "/four", 200)
	var oldValue *string
	var insertedGeneration int
	if err := request.QueryRow(f.ctx, "select author,_tesl_v from notes.notes where id='four'").Scan(&oldValue, &insertedGeneration); err != nil || oldValue != nil || insertedGeneration != 2 {
		t.Fatal("settled INSERT used retired alias or wrong generation", oldValue, insertedGeneration, err)
	}
	call(v2, "PUT", "/one", 200)
	if body := call(renamed, "GET", "/all", 200); !strings.Contains(body, `"id":"four"`) {
		t.Fatal("settled predicate omitted newly inserted row", body)
	}
	pauses[3].resume()
	select {
	case err := <-completed:
		if err != nil {
			t.Fatalf("contract failed: %v %s", err, output.String())
		}
	case <-time.After(20 * time.Second):
		t.Fatalf("contract did not complete: %s", output.String())
	}
	pauses[4].resume()
	select {
	case err := <-racingWorkerDone:
		t.Fatalf("worker prepare/retire/claim race killed active process: %v", err)
	case <-time.After(250 * time.Millisecond):
	}
	stopRacingWorker()
	var oldColumns int
	if err := request.QueryRow(f.ctx, "select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='author'").Scan(&oldColumns); err != nil || oldColumns != 0 {
		t.Fatal("contract did not remove exact old physical column", oldColumns, err)
	}
	var nullable string
	if err := request.QueryRow(f.ctx, "select is_nullable from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='count'").Scan(&nullable); err != nil || nullable != "NO" {
		t.Fatal("contract did not tighten current field", nullable, err)
	}
	// These are the very same server URLs/processes, with source and loose
	// metadata removed before startup. No registration or control state is patched.
	call(v2, "POST", "/five", 200)
	call(v2, "PUT", "/one", 200)
	if body := call(renamed, "GET", "/all", 200); !strings.Contains(body, `"id":"five"`) || !strings.Contains(body, `"owner":"writer"`) {
		t.Fatal("settled Rename projection omitted current rows", body)
	}
	var title, memo string
	if err := request.QueryRow(f.ctx, "select title,memo from notes.notes where id='one'").Scan(&title, &memo); err != nil || title != "edited" || memo != "one-edited" {
		t.Fatal("settled typed update failed", title, memo, err)
	}
	call(v1, "PUT", "/one", 503)
	t.Log("same V2 applications served across actual finality/contract, kept unrelated requests live while barrier busy, and used settled read/write projections after exact drops")
}

// Keep the actual worker process alive past readiness; readiness itself only
// promises admission/expansion, not completion of provisional backfill.
func pgStartSettledWorker(t *testing.T, f *pgControlTestFixture, root, version string, extra ...string) (func(), <-chan error) {
	t.Helper()
	cmd := pgForwardNativeCommand(f, root, version, "worker")
	cmd.Env = append(cmd.Env, "TESL_BACKFILL_BATCH=1")
	cmd.Env = append(cmd.Env, extra...)
	var output pgRowAppOutput
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait(); close(done) }()
	var once sync.Once
	stop := func() {
		once.Do(func() {
			_ = cmd.Process.Signal(os.Interrupt)
			select {
			case err := <-done:
				if err != nil {
					t.Errorf("worker shutdown: %v %s", err, output.String())
				}
			case <-time.After(15 * time.Second):
				_ = cmd.Process.Kill()
				<-done
				t.Errorf("worker did not stop: %s", output.String())
			}
		})
	}
	t.Cleanup(stop)
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(output.String(), "schema-worker-ready") {
			return stop, done
		}
		select {
		case err := <-done:
			t.Fatalf("worker readiness: %v %s", err, output.String())
		default:
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("worker readiness timeout: %s", output.String())
	return stop, done
}

// Multiple processes must reach their independent boundaries while another one
// is paused. The older expansion helper deliberately handles only one at a time.
func pgPauseConcurrentRowBoundaries(t *testing.T, boundaries []pgExpansionBoundary) []pgExpansionBoundaryPause {
	t.Helper()
	dir := t.TempDir()
	socket := filepath.Join(dir, "control.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	pauses := make([]pgExpansionBoundaryPause, len(boundaries))
	arrivals := make([]chan struct{}, len(boundaries))
	releases := make([]chan struct{}, len(boundaries))
	for i := range boundaries {
		arrivals[i] = make(chan struct{}, 1)
		releases[i] = make(chan struct{})
		pauses[i] = pgExpansionBoundaryPause{arrivals[i], sync.OnceFunc(func() { close(releases[i]) })}
	}
	var mutex sync.Mutex
	seen := map[string]int{}
	var clients sync.WaitGroup
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			clients.Add(1)
			go func() {
				defer clients.Done()
				defer func() { _ = conn.Close() }()
				_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
				var event struct{ Name string }
				if err := json.NewDecoder(io.LimitReader(conn, 4096)).Decode(&event); err != nil {
					return
				}
				mutex.Lock()
				seen[event.Name]++
				hit := seen[event.Name]
				mutex.Unlock()
				for i, boundary := range boundaries {
					if boundary.name == event.Name && boundary.hit == hit {
						arrivals[i] <- struct{}{}
						<-releases[i]
					}
				}
				_, _ = io.WriteString(conn, "continue\n")
			}()
		}
	}()
	t.Cleanup(func() {
		for _, pause := range pauses {
			pause.resume()
		}
		_ = listener.Close()
		<-stopped
		clients.Wait()
	})
	t.Setenv("TESL_MIGRATION_TEST_SOCKET", socket)
	t.Setenv("TESL_MIGRATION_TEST_ACTOR", "expansion")
	return pauses
}
