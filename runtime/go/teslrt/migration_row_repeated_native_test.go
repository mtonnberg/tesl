//go:build tesl_migration_test

package teslrt

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPgRowRepeatedActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_REPEATED_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated original V1/V2/V3 applications required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 110*time.Second)
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
	stop, done := pgStartSettledWorker(t, f, root, "v2")
	waitGeneration := func(generation, count int) {
		t.Helper()
		deadline := time.Now().Add(15 * time.Second)
		for {
			var actual int
			err := request.QueryRow(f.ctx, "select count(*) from notes.notes where _tesl_v=$1", generation).Scan(&actual)
			if err == nil && actual == count {
				return
			}
			select {
			case e := <-done:
				t.Fatalf("worker exited before durable generation %d: %v", generation, e)
			default:
			}
			if time.Now().After(deadline) {
				t.Fatalf("generation %d count %d want %d: %v", generation, actual, count, err)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	waitGeneration(2, 1)
	stop()
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	refused := pgForwardNativeRun(t, f, root, "v3", "worker", false)
	if !strings.Contains(string(refused), "tesl: row manifest predecessor identity differs") {
		t.Fatalf("V3 refused for an unrelated reason: %s", refused)
	}
	var columns, floor int
	if err := request.QueryRow(f.ctx, "select (select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name in ('assignee','priority')),compat_floor from notes.tesl_schema_state").Scan(&columns, &floor); err != nil || columns != 0 || floor != 1 {
		t.Fatal("refused V3 published new storage or floor", columns, floor, err)
	}
	call(v2, "GET", "/all", 200)
	run("v2", "contract")
	call(v1, "PUT", "/one", 503)
	call(v2, "POST", "/two", 200)
	publication := pgRepeatedDrain(t, f, root, v2, "worker", "row-forward-before-compatibility-barrier", "row-forward-compatibility-busy")
	publication.ready(t)
	done = publication.done
	waitGeneration(3, 2)
	publication.stop()
	v3 := pgStartRowAccessApp(t, f, root, "v3")
	body := call(v3, "GET", "/all", 200)
	if !strings.Contains(body, `"priority":8`) || !strings.Contains(body, `"priority":10`) {
		t.Fatal("V3 callback did not preserve distinct predecessor values", body)
	}
	run("v2", "locked-observe")
	body = call(v2, "GET", "/all", 200)
	if !strings.Contains(body, `"id":"one"`) || !strings.Contains(body, `"owner":"writer"`) {
		t.Fatal("retained V2 did not decode exact preserved generation3 projection", body)
	}
	func() {
		if _, err := f.installer.Exec(f.ctx, "update notes.notes set _tesl_v=37 where id='one'"); err != nil {
			t.Fatal(err)
		}
		defer func() {
			if _, err := f.installer.Exec(f.ctx, "update notes.notes set _tesl_v=3 where id='one'"); err != nil {
				t.Error(err)
			}
		}()
		call(v2, "GET", "/all", 500)
	}()
	call(v3, "POST", "/three", 200)
	body = call(v2, "GET", "/all", 200)
	if !strings.Contains(body, `"id":"three"`) {
		t.Fatal("retained V2 missed new generation3 row", body)
	}
	call(v2, "PUT", "/one", 200)
	var marker int
	if err := request.QueryRow(f.ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil || marker != 2 {
		t.Fatal("retained V2 write did not invalidate only its next window", marker, err)
	}
	if got := call(v3, "GET", "/one", 200); !strings.Contains(got, "edited") {
		t.Fatal("V3 lazy conversion lost retained writer", got)
	}
	call(v3, "PUT", "/all", 200)
	call(v2, "GET", "/all", 200)
	contract := pgRepeatedDrain(t, f, root, v3, "contract", "row-contract-before-compatibility-barrier", "row-contract-compatibility-busy")
	select {
	case err := <-contract.done:
		if err != nil {
			t.Fatal("V3 Contract failed", err, contract.output.String())
		}
	case <-time.After(30 * time.Second):
		t.Fatal("V3 Contract did not complete", contract.output.String())
	}
	var oldColumn bool
	if err := request.QueryRow(f.ctx, "select exists(select 1 from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='owner')").Scan(&oldColumn); err != nil || oldColumn {
		t.Fatal("V3 Contract did not remove retired V2 projection", oldColumn, err)
	}
	call(v2, "GET", "/all", 503)
	call(v3, "POST", "/four", 200)
	call(v3, "PUT", "/all", 200)
	if body := call(v3, "GET", "/all", 200); !strings.Contains(body, `"id":"four"`) {
		t.Fatal("same V3 did not serve settled current storage", body)
	}
	t.Log("unchanged original V2 and new V3 handlers serve across both actual windows and Contracts with all admitted versions drained")
}

type pgRepeatedProcess struct {
	output pgRowAppOutput
	done   chan error
	stop   func()
}

func pgLaunchRepeatedProcess(t *testing.T, cmd *exec.Cmd) *pgRepeatedProcess {
	t.Helper()
	p := &pgRepeatedProcess{done: make(chan error, 1)}
	cmd.Stdout = &p.output
	cmd.Stderr = &p.output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() { p.done <- cmd.Wait(); close(p.done) }()
	p.stop = sync.OnceFunc(func() {
		_ = cmd.Process.Signal(os.Interrupt)
		select {
		case err := <-p.done:
			if err != nil {
				t.Errorf("repeated process shutdown: %v %s", err, p.output.String())
			}
		case <-time.After(15 * time.Second):
			_ = cmd.Process.Kill()
			<-p.done
			t.Error("repeated process did not stop")
		}
	})
	t.Cleanup(p.stop)
	return p
}

func (p *pgRepeatedProcess) ready(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !strings.Contains(p.output.String(), "schema-worker-ready") {
		select {
		case err := <-p.done:
			t.Fatalf("worker before readiness: %v %s", err, p.output.String())
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("worker readiness timeout", p.output.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Start an original V2 read before the newer operation can publish its floor or
// generation. Neither operation can drop the old SQL projection while it owns
// compatibility access; independent current handlers remain available.
func pgRepeatedDrain(t *testing.T, f *pgControlTestFixture, root, active, mode, before, busy string) *pgRepeatedProcess {
	t.Helper()
	boundary := "row-query-before-select"
	method, path := "GET", "/all"
	if mode == "worker" {
		boundary = "row-rmw-before-declare"
		method, path = "PUT", "/transaction"
	}
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{boundary, 1}, {before, 1}, {busy, 1}})
	defer func() {
		for _, pause := range pauses {
			pause.resume()
		}
	}()
	socket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	start := func() *pgRepeatedProcess {
		cmd := pgForwardNativeCommand(f, root, "v3", mode)
		cmd.Env = append(cmd.Env, socket, "TESL_BACKFILL_BATCH=1")
		return pgLaunchRepeatedProcess(t, cmd)
	}
	var process *pgRepeatedProcess
	waitBarrier := func() {
		select {
		case <-pauses[1].arrived:
		case err := <-process.done:
			t.Fatalf("operation missed before-drain boundary: %v %s", err, process.output.String())
		case <-time.After(15 * time.Second):
			t.Fatal("before-drain boundary missing", process.output.String())
		}
	}
	if mode == "worker" {
		// ADD COLUMN needs a short table lock. Finish expansion DDL before the
		// caller opens its multi-statement transaction; isolate publication drain.
		process = start()
		waitBarrier()
	}
	old, oldOutput := pgStartRowAccessObservedApp(t, f, root, "v2", socket)
	pending := make(chan error, 1)
	expected := 200
	if mode == "contract" {
		expected = 503
	} // Retirement precedes the compatibility drain.
	go func() {
		req, err := http.NewRequestWithContext(f.ctx, method, old+path, nil)
		if err == nil {
			var response *http.Response
			response, err = http.DefaultClient.Do(req)
			if err == nil {
				_, err = io.Copy(io.Discard, response.Body)
				_ = response.Body.Close()
				if err == nil && response.StatusCode != expected {
					err = fmt.Errorf("paused original read status %d want %d", response.StatusCode, expected)
				}
			}
		}
		pending <- err
	}()
	select {
	case <-pauses[0].arrived:
	case err := <-pending:
		t.Fatalf("old read did not pause: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("old read boundary missing")
	}
	if process == nil {
		process = start()
		waitBarrier()
	}
	pauses[1].resume()
	for _, i := range []int{2} {
		select {
		case <-pauses[i].arrived:
			pauses[i].resume()
		case err := <-process.done:
			t.Fatalf("new operation missed drain: %v %s", err, process.output.String())
		case <-time.After(15 * time.Second):
			t.Fatal("new operation did not report drain", process.output.String())
		}
	}
	for i := 0; i < 3; i++ {
		pgCallRowAccessApp(t, f.ctx, active, "GET", "/all", 200)
	}
	if mode == "contract" {
		var present bool
		if err := f.worker.QueryRow(f.ctx, "select exists(select 1 from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='owner')").Scan(&present); err != nil || !present {
			t.Fatal("V3 Contract dropped old V2 projection before draining", present, err)
		}
	}
	select {
	case err := <-pending:
		t.Fatalf("paused statement escaped before release: %v", err)
	default:
	}
	pauses[0].resume()
	select {
	case err := <-pending:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("original statement did not complete after release")
	}
	if mode == "worker" {
		if strings.Count(oldOutput.String(), "access-transaction {phase=between-statements}") != 1 {
			t.Fatal("publication drain replayed caller transaction effect", oldOutput.String())
		}
		var memo string
		if err := f.worker.QueryRow(f.ctx, "select memo from notes.notes where id='one'").Scan(&memo); err != nil || memo != "base-transaction" {
			t.Fatal("caller transaction did not preserve read then write exactly once", memo, err)
		}
	}
	return process
}
