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
	"strings"
	"testing"
	"time"
)

func TestPgRowAccessActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_ACCESS_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated full apps required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
	run("v2missing", "bindings")
	run("v1", "install")
	run("v1", "worker")
	start := func(version string, extra ...string) string {
		return pgStartRowAccessApp(t, f, root, version, extra...)
	}
	call := func(base, method, path string, status int) string {
		return pgCallRowAccessApp(t, f.ctx, base, method, path, status)
	}

	v1 := start("v1")
	run("v2", "worker")
	// Seed through the still-running old app after the empty worker pass. This
	// preserves the lazy-read and first-write rollback witnesses independently
	// of the worker's provisional backfill, exercised by the Contract fixture.
	call(v1, "POST", "/one", 200)
	call(v1, "POST", "/two", 200)
	v2 := start("v2")
	call(v2, "PUT", "/conflict", 500)
	var processing, oldRows int
	if err := request.QueryRow(f.ctx, "select count(*) from notes.tesl_row_processing").Scan(&processing); err != nil || processing != 0 {
		t.Fatal("failed first bulk write committed ABI latch", processing, err)
	}
	if err := request.QueryRow(f.ctx, "select count(*) from notes.notes where _tesl_v=1 and title in ('one','two')").Scan(&oldRows); err != nil || oldRows != 2 {
		t.Fatal("second SQL write failure retained partial first write", oldRows, err)
	}
	renamed := start("v2query")
	if body := call(renamed, "GET", "/all", 200); !strings.Contains(body, `"id":"one"`) || !strings.Contains(body, `"id":"two"`) {
		t.Fatal("Rename predicate must use retained old column for marker1 rows", body)
	}
	if body := call(v2, "GET", "/one", 200); !strings.Contains(body, "one") {
		t.Fatal(body)
	}
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"count":7`) || !strings.Contains(body, `"owner":"writer"`) {
		t.Fatal("actual lazy callback", body)
	}
	call(v2, "POST", "/three", 200)
	var marker, count int
	var author, owner, title string
	if err := request.QueryRow(f.ctx, "select _tesl_v,count,author,owner from notes.notes where id='three'").Scan(&marker, &count, &author, &owner); err != nil || marker != 2 || count != 9 || author != "writer" || owner != author {
		t.Fatal("actual handler insert", marker, count, author, owner, err)
	}
	call(v2, "PUT", "/all", 200)
	var rows int
	if err := request.QueryRow(f.ctx, "select count(*) from notes.notes where memo='all-edited' and _tesl_v=2").Scan(&rows); err != nil || rows != 3 {
		t.Fatal("multi-row update", rows, err)
	}
	call(v1, "PUT", "/one", 200)
	if err := request.QueryRow(f.ctx, "select _tesl_v,title from notes.notes where id='one'").Scan(&marker, &title); err != nil || marker != 1 || title != "edited" {
		t.Fatal("late old handler invalidation", marker, title, err)
	}
	if body := call(v2, "GET", "/one", 200); !strings.Contains(body, "edited") {
		t.Fatal("old write not visible", body)
	}
	call(v2, "PUT", "/one", 200)
	if err := request.QueryRow(f.ctx, "select _tesl_v,count,title from notes.notes where id='one'").Scan(&marker, &count, &title); err != nil || marker != 2 || count != 7 || title != "edited" {
		t.Fatal("handler locked RMW", marker, count, title, err)
	}
	timeoutApp := start("v2", "TESL_PG_POOL_LEASE_TIMEOUT_MS=400")
	locked, err := request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := locked.Exec(f.ctx, "select id from notes.notes where id='one' for update"); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	call(timeoutApp, "PUT", "/one", 503)
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Fatal("typed migration query ignored lease timeout", elapsed)
	}
	if err := locked.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	call(v2, "PUT", "/one", 200)
	call(v2, "PUT", "/returning", 200)
	call(v2, "PUT", "/missing-returning", 500)
	unchanged := call(v2, "GET", "/all", 200)
	call(v2, "PUT", "/ambiguous-returning", 500)
	if after := call(v2, "GET", "/all", 200); after != unchanged {
		t.Fatal("ambiguous returning update wrote before establishing cardinality", unchanged, after)
	}

	call(v2, "PUT", "/returning", 200)

	debug := pgForwardNativeRun(t, f, root, "v2debug", "debug", true)
	if !strings.Contains(string(debug), `\"_tesl_v\"`) || !strings.Contains(string(debug), `\"memo\"`) || !strings.Contains(string(debug), `"row-count":1`) || !strings.Contains(string(debug), `"operation":"update"`) {
		t.Fatalf("missing actual physical debug SQL capture: %s", debug)
	}
	var captures []*DebugSQLCapture
	if err := json.Unmarshal(debug, &captures); err != nil || len(captures) != 2 || captures[0] == nil || captures[1] == nil {
		t.Fatal("invalid native capture", err, string(debug))
	}
	read, write := captures[0], captures[1]
	if read.Operation != "select" || read.RowCount != 1 || len(read.Params) != 1 || read.Params[0].Display != "one" || write.Operation != "update" || write.RowCount != 1 || len(write.Params) != 8 || write.Params[2].Display != "one-edited" || write.Params[5].Display != "2" || write.Params[6].Display != "one" || write.Params[7].Display != "one" {
		t.Fatal("physical capture lost projection, params or row counts", string(debug))
	}
	before := call(v2, "GET", "/all", 200)
	call(v2, "PUT", "/conflict", 500)
	after := call(v2, "GET", "/all", 200)
	if before != after {
		t.Fatal("SQL unique violation failed to roll back complete update", before, after)
	}
	events := pgForwardNativeRun(t, f, root, "v2", "effects", true)
	if !strings.Contains(string(events), `["set-multi","where-multi","set-zero","where-zero"]`) {
		t.Fatalf("SET/WHERE effects must run once, in order, even for zero matches: %s", events)
	}
	call(v2, "PUT", "/one", 200)
	pauses := pgPauseExpansionBoundaries(t, []pgExpansionBoundary{{"row-rmw-after-fetch", 1}, {"row-rmw-after-fetch", 2}, {"row-rmw-after-fetch", 3}})
	arrived, resume := pauses[0].arrived, pauses[0].resume
	cursorApp := start("v2", "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"), "TESL_PG_POOL_LEASE_TIMEOUT_MS=10000")
	completed := make(chan error, 1)
	go func() {
		req, _ := http.NewRequestWithContext(f.ctx, "PUT", cursorApp+"/all", nil)
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode != 200 {
				err = fmt.Errorf("cursor update status %d", resp.StatusCode)
			}
		}
		completed <- err
	}()
	select {
	case <-arrived:
	case err := <-completed:
		t.Fatalf("cursor update did not pause: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("cursor did not reach first fetched batch")
	}
	call(v1, "POST", "/four", 200)
	resume()
	for _, pause := range pauses[1:] {
		select {
		case <-pause.arrived:
			pause.resume()
		case err := <-completed:
			t.Fatalf("cursor did not honor batch1 across all rows: %v", err)
		case <-time.After(10 * time.Second):
			t.Fatal("cursor did not reach next bounded batch")
		}
	}
	select {
	case err := <-completed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("cursor update did not finish")
	}
	if err := request.QueryRow(f.ctx, "select memo,_tesl_v from notes.notes where id='four'").Scan(&title, &marker); err != nil || title != "base" || marker != 1 {
		t.Fatal("cursor admitted a row inserted after its statement snapshot", title, marker, err)
	}
	call(v2, "PUT", "/one", 200)

	// A rejected source row aborts the complete update, including rows decoded
	// before it. The actual Tesl callback supplies Reject; no native substitution.
	call(v1, "POST", "/reject", 200)
	call(v2, "PUT", "/all", 500)
	if err := request.QueryRow(f.ctx, "select memo from notes.notes where id='one'").Scan(&title); err != nil || title != "one-edited" {
		t.Fatal("Reject did not roll back all rows", title, err)
	}
	t.Log("actual V1/V2 Main + unchanged HTTP handlers: lazy read, insert, multi-row update, late old write and Reject rollback passed")
}

func pgStartRowAccessApp(t *testing.T, f *pgControlTestFixture, root, version string, extra ...string) string {
	t.Helper()
	url, _ := pgStartRowAccessObservedApp(t, f, root, version, extra...)
	return url
}
func pgStartRowAccessObservedApp(t *testing.T, f *pgControlTestFixture, root, version string, extra ...string) (string, *pgRowAppOutput) {
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
	cmd := pgForwardNativeCommand(f, root, version, "serve")
	cmd.Env = append(cmd.Env, "ROW_PORT="+port, "TESL_PG_POOL_LEASE_TIMEOUT_MS=10000", "TESL_RMW_BATCH=1")
	cmd.Env = append(cmd.Env, extra...)
	var output pgRowAppOutput
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait(); close(done) }()
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("%s server output: %s", version, output.String())
		}
		_ = cmd.Process.Signal(os.Interrupt)
		select {
		case <-done:
		case <-time.After(20 * time.Second):
			_ = cmd.Process.Kill()
			<-done
		}
	})
	url := "http://" + address
	client := &http.Client{Timeout: time.Second}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		response, err := client.Get(url + "/health")
		if err == nil {
			_ = response.Body.Close()
			if response.StatusCode == 200 {
				return url, &output
			}
		}
		select {
		case err := <-done:
			t.Fatalf("actual %s Main failed: %v\n%s", version, err, output.String())
		default:
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("actual %s Main did not serve: %s", version, output.String())
	return "", &output
}

func pgCallRowAccessApp(t *testing.T, ctx context.Context, base, method, path string, status int) string {
	t.Helper()
	t.Logf("%s %s %s expected%d", base, method, path, status)
	req, _ := http.NewRequestWithContext(ctx, method, base+path, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != status {
		t.Fatalf("%s %s: expected %d got %d %s", method, path, status, resp.StatusCode, body)
	}
	return string(body)
}
