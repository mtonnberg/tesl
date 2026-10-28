//go:build tesl_migration_test

package teslrt

import (
	"context"
	"math"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgRowDerivedActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_DERIVED_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated Derived apps required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
	call := func(base, method, path string, status int) string {
		return pgCallRowAccessApp(t, ctx, base, method, path, status)
	}
	run("v1", "install")
	run("v1", "worker")
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	call(v1, "POST", "/one", 200)
	stop, done := pgStartSettledWorker(t, f, root, "v2")
	deadline := time.Now().Add(10 * time.Second)
	for {
		select {
		case err := <-done:
			t.Fatalf("Derived worker exited: %v", err)
		default:
		}
		var count int
		var provisional bool
		err := f.worker.QueryRow(ctx, "select (select count(*) from notes.notes where _tesl_v=2),exists(select 1 from notes.tesl_schema_backfill_shards where state='provisional')").Scan(&count, &provisional)
		if err == nil && count == 1 && provisional {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("Derived worker failed durable materialization", count, provisional, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	stop()
	var author, owner, memo, count, label string
	var enabled, empty bool
	var ratio float64
	if err := request.QueryRow(ctx, "select author,owner,memo,count::text,label,enabled,ratio,extra is null from notes.notes where id='one'").Scan(&author, &owner, &memo, &count, &label, &enabled, &ratio, &empty); err != nil {
		t.Fatal(err)
	}
	if author != "writer" || owner != "writer" || memo != "base" || count != "123456789012345678901234567890" || label != "derived" || !enabled || !empty || math.Float64bits(ratio) != 1<<63 {
		t.Fatal("Derived projection/default encoding mismatch", author, owner, memo, count, label, enabled, ratio, empty)
	}
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"owner":"writer"`) || strings.Contains(body, `"author"`) {
		t.Fatal("new nominal projection", body)
	}
	call(v1, "GET", "/all", 200)
	call(v2, "POST", "/two", 200)
	call(v1, "GET", "/all", 200)
	call(v1, "PUT", "/one", 200)
	var marker int
	if err := request.QueryRow(ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil || marker != 1 {
		t.Fatal("old writer must invalidate Derived generation", marker, err)
	}
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"memo":"edited"`) {
		t.Fatal("Derived lazy read discarded old update", body)
	}
	run("v2", "contract")
	call(v1, "GET", "/all", 503)
	call(v2, "POST", "/three", 200)
	call(v2, "PUT", "/one", 200)
	call(v2, "GET", "/all", 200)
	var oldColumns int
	if err := request.QueryRow(ctx, "select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='author'").Scan(&oldColumns); err != nil || oldColumns != 0 {
		t.Fatal("Derived Contract retained old column", oldColumns, err)
	}
	run("v2", "contract")
}
