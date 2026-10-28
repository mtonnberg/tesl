//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// All three executables are the original compiler-emitted cmd/app. The same
// Tesl handlers run before, during, and after the data migration and additive
// successor. The harness only supplies connection environment and schema flags.
func TestPgRowCurrentAdditiveSuccessorOrdinaryApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_CURRENT_PROGRAMS")
	if root == "" {
		t.Skip("original compiler-produced mixed history applications required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	run := func(version string, args ...string) {
		t.Helper()
		command := pgRowAdditiveCommand(f, root, version, args...)
		var output pgRowAppOutput
		command.Stdout, command.Stderr = &output, &output
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- command.Wait() }()
		var err error
		select {
		case err = <-done:
		case <-time.After(5 * time.Second):
			var activity, state, shards string
			_ = f.installer.QueryRow(ctx, `select coalesce(json_agg(r)::text,'[]') from (select pid,state,wait_event_type,wait_event,pg_blocking_pids(pid) as blockers,left(query,200) as query from pg_stat_activity where datname=current_database()) r`).Scan(&activity)
			_ = f.installer.QueryRow(ctx, `select row_to_json(s)::text from notes.tesl_schema_state s`).Scan(&state)
			_ = f.installer.QueryRow(ctx, `select coalesce(json_agg(s)::text,'[]') from notes.tesl_schema_backfill_shards s`).Scan(&shards)
			t.Log("pending command", version, args, "activity", activity, "state", state, "shards", shards)
			err = <-done
		}
		if err != nil {
			t.Fatalf("%s %v: %v\n%s", version, args, err, output.String())
		}
	}
	run("v1", "--schema", "install", "--worker", f.roles.Worker, "--request", f.roles.Request, "--json")
	pgRowAdditiveWorker(t, f, root, "v1")()
	v1 := pgRowAdditiveApp(t, f, root, "v1")
	call := func(base, method, path string, status int) string {
		t.Helper()
		return pgCallRowAccessApp(t, ctx, base, method, path, status)
	}
	call(v1, "POST", "/one", 200)
	stopV2 := pgRowAdditiveWorker(t, f, root, "v2")
	v2 := pgRowAdditiveApp(t, f, root, "v2")
	// Accepted source cannot turn an unperformed Contract into deployed authority.
	out, err := pgRowAdditiveCommand(f, root, "v3", "--schema", "worker", "--json").CombinedOutput()
	if err == nil || !strings.Contains(strings.ToLower(string(out)), "contract") {
		t.Fatalf("V3 before Contract: %v %s", err, out)
	}
	var current, pending, tailColumns int
	if err := request.QueryRow(ctx, `select current,(select count(*) from notes.tesl_row_physical where version=3),(select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name in ('note','priority')) from notes.tesl_schema_state`).Scan(&current, &pending, &tailColumns); err != nil || current != 2 || pending != 0 || tailColumns != 0 {
		t.Fatal("premature additive publication", current, pending, tailColumns, err)
	}
	stopV2()
	run("v2", "--schema", "contract", "V2", "--json")
	call(v1, "GET", "/all", 503)
	call(v2, "GET", "/one", 200)
	var abiBefore, shardsBefore int
	if err := request.QueryRow(ctx, `select (select count(*) from notes.tesl_row_processing),(select count(*) from notes.tesl_schema_backfill_shards)`).Scan(&abiBefore, &shardsBefore); err != nil {
		t.Fatal(err)
	}
	pgRowAdditiveWorker(t, f, root, "v3")()
	var expandedABI, expandedShards int
	if err := request.QueryRow(ctx, `select (select count(*) from notes.tesl_row_processing),(select count(*) from notes.tesl_schema_backfill_shards)`).Scan(&expandedABI, &expandedShards); err != nil || expandedABI != abiBefore || expandedShards != shardsBefore {
		t.Fatal("additive expansion invented processing work", abiBefore, expandedABI, shardsBefore, expandedShards, err)
	}
	v3 := pgRowAdditiveApp(t, f, root, "v3")
	// The original V2 process still writes its exact settled projection. V3's
	// additive default survives, and its own inserts use makeNote's count=9,
	// whereas the historical V2 conversion produced count=7.
	call(v2, "PUT", "/one", 200)
	call(v3, "POST", "/three", 200)
	var generation, count, priority int
	var owner, title string
	var note *string
	if err := request.QueryRow(ctx, `select _tesl_v,count,priority,owner,title,note from notes.notes where id='three'`).Scan(&generation, &count, &priority, &owner, &title, &note); err != nil || generation != 2 || count != 9 || priority != 4 || owner != "writer" || title != "three" || note != nil {
		t.Fatal("current codec/generation or original constructor changed", generation, count, priority, owner, title, note, err)
	}
	if err := request.QueryRow(ctx, `select _tesl_v,count,priority from notes.notes where id='one'`).Scan(&generation, &count, &priority); err != nil || generation != 2 || count != 7 || priority != 4 {
		t.Fatal("late settled writer lost additive data", generation, count, priority, err)
	}
	call(v3, "PUT", "/all", 200)
	before := call(v3, "GET", "/all", 200)
	call(v3, "PUT", "/conflict", 500)
	if after := call(v3, "GET", "/all", 200); after != before {
		t.Fatal("current multi-row update failed to roll back", before, after)
	}
	call(v3, "PUT", "/ambiguous-returning", 500)
	if after := call(v3, "GET", "/all", 200); after != before {
		t.Fatal("ambiguous current update committed", before, after)
	}
	var abiAfter, shardsAfter, retired int
	if err := request.QueryRow(ctx, `select (select count(*) from notes.tesl_row_processing),(select count(*) from notes.tesl_schema_backfill_shards),(select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='author')`).Scan(&abiAfter, &shardsAfter, &retired); err != nil || abiAfter != abiBefore || shardsAfter != shardsBefore || retired != 0 {
		t.Fatal("additive access recreated work, ABI or retired columns", abiBefore, abiAfter, shardsBefore, shardsAfter, retired, err)
	}
}
