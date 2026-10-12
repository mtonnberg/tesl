//go:build tesl_migration_test

package teslrt

import (
	"context"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func pgRowDeleteApp(t *testing.T, f *pgControlTestFixture, root, version string, extra ...string) (string, *pgRowAppOutput) {
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
				return url, output
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("delete application did not serve: %s", output.String())
	return "", output
}

func TestPgRowDeleteOriginalApplications(t *testing.T) {
	root := os.Getenv("TESL_ROW_DELETE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated original delete applications required")
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
	v1, _ := pgRowDeleteApp(t, f, root, "v1")
	// Expand while empty, then seed through the original running V1. These
	// marker-1 rows have never run the conversion callback or pinned its ABI.
	pgRowAdditiveWorker(t, f, root, "v2")()
	v2, output := pgRowDeleteApp(t, f, root, "v2")
	call := func(app, method, path string, status int) string {
		return pgCallRowAccessApp(t, ctx, app, method, path, status)
	}
	rows := func(want int) {
		t.Helper()
		var got int
		if err := request.QueryRow(ctx, "select count(*) from notes.notes").Scan(&got); err != nil || got != want {
			t.Fatal("durable delete row count", got, want, err)
		}
	}
	processing := func(want int) {
		t.Helper()
		var got int
		if err := request.QueryRow(ctx, "select count(*) from notes.tesl_row_processing").Scan(&got); err != nil || got != want {
			t.Fatal("delete changed processing ABI authority", got, want, err)
		}
	}
	count := func(app, path string, want string) {
		t.Helper()
		if body := strings.TrimSpace(call(app, "POST", path, 200)); body != want {
			t.Fatalf("%s count=%s want=%s", path, body, want)
		}
	}
	call(v1, "POST", "/reject", 200)
	rows(1)
	processing(0)
	call(v2, "DELETE", "/reject", 200)
	rows(0)
	processing(0)
	call(v1, "POST", "/one", 200)
	call(v1, "POST", "/two", 200)
	rows(2)
	count(v2, "/delete-count", "2")
	count(v2, "/delete-count", "0")
	rows(0)
	processing(0)
	// Predicate effects occur once even when the same statement matches no row.
	call(v1, "POST", "/one", 200)
	call(v1, "POST", "/two", 200)
	before := strings.Count(output.String(), "delete-operand")
	count(v2, "/delete-effects", "2")
	count(v2, "/delete-effects", "0")
	deadline := time.Now().Add(5 * time.Second)
	for strings.Count(output.String(), "delete-operand") < before+2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := strings.Count(output.String(), "delete-operand"); got != before+2 {
		t.Fatalf("predicate effect count %d want %d: %s", got, before+2, output.String())
	}
	rows(0)
	processing(0)
	// A newer row can still be deleted through the retained old application.
	call(v2, "POST", "/one", 200)
	processing(1)
	call(v1, "DELETE", "/one", 200)
	rows(0)
	call(v2, "POST", "/one", 200)
	call(v2, "POST", "/two", 200)
	call(v2, "POST", "/delete-rollback", 409)
	rows(2)
	var first int
	if err := request.QueryRow(ctx, "select count(*) from notes.notes where id='one'").Scan(&first); err != nil || first != 1 {
		t.Fatal("caller-owned transaction published delete before failure", first, err)
	}
	// The existing operation deadline applies to a locked physical DELETE too.
	limited, _ := pgRowDeleteApp(t, f, root, "v2", "TESL_MIGRATION_TEST_REQUEST_TIMEOUT_MS=400")
	blocker, err := request.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = blocker.Rollback(context.Background()) }()
	if _, err := blocker.Exec(ctx, "select id from notes.notes where id='one' for update"); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	call(limited, "DELETE", "/one", 503)
	if time.Since(started) > 3*time.Second {
		t.Fatal("delete ignored operation deadline")
	}
	if err := blocker.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	rows(2)
	contract := pgRowAdditiveCommand(f, root, "v2", "--schema", "contract", "V2", "--json")
	if out, err := contract.CombinedOutput(); err != nil {
		t.Fatalf("Contract: %v %s", err, out)
	}
	call(v1, "DELETE", "/one", 503)
	rows(2)
	count(v2, "/delete-count", "2")
	count(v2, "/delete-count", "0")
	rows(0)
	processing(1)
}
