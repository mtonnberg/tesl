//go:build tesl_migration_test

package teslrt

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgRowSettledBulkUpdateRollback(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" || os.Getenv("TESL_REQUIRE_BULK") != "1" {
		t.Skip("actual compiled no-secondary-unique fixture required")
	}
	f, _ := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	if _, err := f.installer.Exec(ctx, `insert into notes.notes(id,author,title,memo)
select 'r'||lpad(i::text,4,'0'),'writer','r'||lpad(i::text,4,'0'),'base' from generate_series(1,300) i`); err != nil {
		t.Fatal(err)
	}
	stopWorker, workerDone := pgStartSettledWorker(t, f, root, "v2", "TESL_BACKFILL_BATCH=500")
	deadline := time.Now().Add(25 * time.Second)
	for {
		var ready bool
		if err := f.worker.QueryRow(ctx, `select (select count(*) from notes.notes where _tesl_v=2)=300
and exists(select 1 from notes.tesl_schema_backfill_shards where state='provisional')`).Scan(&ready); err != nil {
			t.Fatal(err)
		}
		if ready {
			break
		}
		select {
		case err := <-workerDone:
			t.Fatal("worker exited", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("worker did not convert all original rows")
		}
		time.Sleep(20 * time.Millisecond)
	}
	stopWorker()
	pgForwardNativeRun(t, f, root, "v2", "contract", true)
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"row-rmw-after-bulk", 2}})
	t.Cleanup(pauses[0].resume)
	base, output := pgStartRowAccessObservedApp(t, f, root, "v2", "TESL_RMW_BATCH=2000",
		"TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	type response struct {
		status int
		err    error
	}
	done := make(chan response, 1)
	go func() {
		req, err := http.NewRequestWithContext(ctx, http.MethodPut, base+"/bulk-transaction", nil)
		if err != nil {
			done <- response{err: err}
			return
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			done <- response{err: err}
			return
		}
		_, readErr := io.Copy(io.Discard, res.Body)
		closeErr := res.Body.Close()
		if readErr == nil {
			readErr = closeErr
		}
		done <- response{status: res.StatusCode, err: readErr}
	}()
	select {
	case <-pauses[0].arrived:
	case result := <-done:
		t.Fatalf("request never used multiple bulk groups: %+v %s", result, output.String())
	case <-ctx.Done():
		t.Fatal("bulk publication boundary not reached")
	}
	var visible int
	if err := f.installer.QueryRow(ctx, "select count(*) from notes.notes where memo<>'base'").Scan(&visible); err != nil || visible != 0 {
		t.Fatal("uncommitted prefix became visible", visible, err)
	}
	var killed int
	if err := f.installer.QueryRow(ctx, `select count(*) from pg_stat_activity
where datname=current_database() and usename=$1 and state='idle in transaction' and query like 'with input(%'
and pg_terminate_backend(pid)`, f.roles.Request).Scan(&killed); err != nil || killed != 1 {
		t.Fatal("did not kill exact bulk transaction backend", killed, err)
	}
	pauses[0].resume()
	select {
	case result := <-done:
		if result.err != nil || result.status != http.StatusInternalServerError {
			t.Fatalf("expected failed caller-owned transaction: %+v %s", result, output.String())
		}
	case <-ctx.Done():
		t.Fatal("request did not finish after backend death")
	}
	if err := f.installer.QueryRow(ctx, "select count(*) from notes.notes where memo<>'base'").Scan(&visible); err != nil || visible != 0 {
		t.Fatal("single-row write or earlier bulk group escaped rollback", visible, err)
	}
	pgCallRowAccessApp(t, ctx, base, "PUT", "/bulk-transaction", 200)
	var rows []struct {
		ID    string `json:"id"`
		Owner string `json:"owner"`
		Title string `json:"title"`
		Count int    `json:"count"`
		Memo  string `json:"memo"`
	}
	if err := json.Unmarshal([]byte(pgCallRowAccessApp(t, ctx, base, "GET", "/all", 200)), &rows); err != nil || len(rows) != 300 {
		t.Fatal("retry returned wrong row set", len(rows), err)
	}
	for _, row := range rows {
		if row.Owner != "writer" || row.Title != row.ID || row.Count != 7 || row.Memo != "bulk-transaction" {
			t.Fatalf("bulk retry lost stored data: %+v", row)
		}
	}
	pgCallRowAccessApp(t, ctx, base, "PUT", "/effects", 200)
	if strings.Count(output.String(), "access-operand {phase=set-multi}") != 1 || strings.Count(output.String(), "access-operand {phase=where-multi}") != 1 {
		t.Fatal("bulk operation re-evaluated captured operands", output.String())
	}
	pgCallRowAccessApp(t, ctx, base, "PUT", "/ambiguous-returning", 500)
	if err := f.installer.QueryRow(ctx, "select count(*) from notes.notes where memo='ambiguous-should-not-write'").Scan(&visible); err != nil || visible != 0 {
		t.Fatal("ambiguous update published rows", visible, err)
	}
}
