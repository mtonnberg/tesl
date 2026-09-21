//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgRowProofRemovalActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_PROOF_REMOVAL_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated proof field removal apps required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	run := func(v, mode string) { pgForwardNativeRun(t, f, root, v, mode, true) }
	call := func(base, method, path string, status int) string {
		return pgCallRowAccessApp(t, ctx, base, method, path, status)
	}
	run("v1", "install")
	run("v1", "worker")
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	call(v1, "POST", "/one", 200)
	run("v2", "worker")
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	if body := call(v2, "GET", "/all", 200); strings.Contains(body, `"title"`) {
		t.Fatal("removed field exposed by new app", body)
	}
	call(v2, "PUT", "/touch", 200)
	var title, memo string
	var generation int
	if err := request.QueryRow(ctx, "select title,memo,_tesl_v from notes.notes where id='one'").Scan(&title, &memo, &generation); err != nil || title != "touched" || memo != "touched" || generation != 2 {
		t.Fatal("LegacyWith did not establish exact old field", title, memo, generation, err)
	}
	if body := call(v1, "GET", "/all", 200); !strings.Contains(body, `"title":"touched"`) {
		t.Fatal("old reader lost proven reverse value", body)
	}
	call(v2, "POST", "/two", 200)
	if err := request.QueryRow(ctx, "select title,memo,_tesl_v from notes.notes where id='a-valid'").Scan(&title, &memo, &generation); err != nil || title != "second" || memo != "second" || generation != 2 {
		t.Fatal("new insertion failed to establish old proof", title, memo, generation, err)
	}
	call(v1, "PUT", "/repair", 200)
	if err := request.QueryRow(ctx, "select title,_tesl_v from notes.notes where id='one'").Scan(&title, &generation); err != nil || title != "repaired" || generation != 1 {
		t.Fatal("old write failed to invalidate removed-field projection", title, generation, err)
	}
	call(v2, "GET", "/all", 200)
	snapshot := func() string {
		var s string
		if err := request.QueryRow(ctx, `select jsonb_build_object('rows',(select jsonb_agg(to_jsonb(n) order by id) from notes.notes n),'processing',(select jsonb_agg(to_jsonb(p) order by version) from notes.tesl_row_processing p),'shards',(select jsonb_agg(to_jsonb(s) order by version,entity,target_generation,shard) from notes.tesl_schema_backfill_shards s))::text`).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	before := snapshot()
	call(v2, "PUT", "/touch-all", 500) // Duplicate unique memo after multiple reverse constructions.
	if after := snapshot(); after != before {
		t.Fatal("failed bulk update published old proof columns or migration progress", before, after)
	}
	// The new schema can retain an empty memo; the removed NonEmpty field still
	// requires its explicitly validated fallback until old readers are retired.
	call(v2, "PUT", "/empty", 200)
	if err := request.QueryRow(ctx, "select title,memo,_tesl_v from notes.notes where id='one'").Scan(&title, &memo, &generation); err != nil || title != "valid" || memo != "" || generation != 2 {
		t.Fatal("removed proof fallback is not exact", title, memo, generation, err)
	}
	call(v1, "GET", "/all", 200)
	run("v2", "contract")
	call(v1, "PUT", "/repair", 503)
	var columns int
	if err := request.QueryRow(ctx, "select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='title'").Scan(&columns); err != nil || columns != 0 {
		t.Fatal("Contract retained removed proof column", columns, err)
	}
	if body := call(v2, "GET", "/all", 200); strings.Contains(body, `"title"`) || !strings.Contains(body, `"memo":""`) {
		t.Fatal("Contract lost current data", body)
	}
	call(v2, "PUT", "/touch", 200)
	run("v2", "contract") // Idempotent restart does not recreate the old proof field.
}
