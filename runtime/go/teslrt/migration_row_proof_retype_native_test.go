//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// These are separate, unmodified compiler-emitted V1/V2 applications. All
// application writes, repairs and invalid inputs go through their real handlers.
func TestPgRowProofRetypeActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_PROOF_RETYPE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated proof Retype applications required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	run := func(version, mode string, ok bool) []byte {
		return pgForwardNativeRun(t, f, root, version, mode, ok)
	}
	call := func(base, method, path string, status int) string {
		return pgCallRowAccessApp(t, ctx, base, method, path, status)
	}
	contracted := false
	marker := func(want int, title string) {
		t.Helper()
		var got int
		var stored string
		column := "title"
		if contracted || want == 2 {
			column = "title__v2"
		}
		if err := request.QueryRow(ctx, "select _tesl_v,"+column+" from notes.notes where id='one'").Scan(&got, &stored); err != nil || got != want || stored != title {
			t.Fatalf("stored generation/title: %d %q, want %d %q: %v", got, stored, want, title, err)
		}
	}
	run("v1", "install", true)
	run("v1", "worker", true)
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	call(v1, "POST", "/two", 200)
	call(v1, "POST", "/one", 200)
	call(v1, "PUT", "/invalid", 200)
	marker(1, "blocked")
	// Expansion succeeds; the Worker leaves the rejected row unconverted,
	// reports it and keeps running instead of exiting.
	pgForwardNativeWorkerReportsRejection(t, f, root, "v2")
	marker(1, "blocked")
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	call(v2, "GET", "/all", 500)
	marker(1, "blocked")
	// The valid row was inserted before the rejected row. A bulk write must
	// not leave that earlier row updated or claim migration progress on failure.
	snapshot := func() string {
		var state string
		if err := request.QueryRow(ctx, `select jsonb_build_object(
 'rows',(select jsonb_agg(to_jsonb(n) order by id) from notes.notes n),
 'processing',(select jsonb_agg(to_jsonb(p) order by version) from notes.tesl_row_processing p),
 'shards',(select jsonb_agg(to_jsonb(s) order by version,entity,target_generation,shard) from notes.tesl_schema_backfill_shards s))::text`).Scan(&state); err != nil {
			t.Fatal(err)
		}
		return state
	}
	beforeBulk := snapshot()
	call(v2, "PUT", "/touch-all", 500)
	if after := snapshot(); after != beforeBulk {
		t.Fatal("rejected bulk proof migration changed rows, physical columns, generations or progress", beforeBulk, after)
	}
	call(v1, "PUT", "/repair", 200)
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"title":"repaired"`) {
		t.Fatal("lazy revalidation lost repaired source value", body)
	}
	// Read-only lazy validation does not claim durable migration completion.
	marker(1, "repaired")
	stop, done := pgStartSettledWorker(t, f, root, "v2")
	deadline := time.Now().Add(15 * time.Second)
	for {
		select {
		case err := <-done:
			t.Fatalf("repaired proof Retype worker exited: %v", err)
		default:
		}
		var generation int
		var provisional bool
		err := request.QueryRow(ctx, "select _tesl_v,exists(select 1 from notes.tesl_schema_backfill_shards where state='provisional') from notes.notes where id='one'").Scan(&generation, &provisional)
		if err == nil && generation == 2 && provisional {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("repaired worker did not finish provisional pass", generation, provisional, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	stop()
	marker(2, "repaired")
	var columns []string
	expectedColumns := []string{"_tesl_v", "id", "memo", "title", "title__v2"}
	if err := request.QueryRow(ctx, "select array_agg(column_name::text order by column_name) from information_schema.columns where table_schema='notes' and table_name='notes'").Scan(&columns); err != nil || !slices.Equal(columns, expectedColumns) {
		t.Fatal("proof Retype introduced shadow or changed physical columns", columns, err)
	}
	// The invalidation set covers every predecessor field, including a field
	// unrelated to the new proof. No old writer can retain a stale proof marker.
	call(v1, "PUT", "/touch", 200)
	marker(1, "repaired")
	call(v2, "GET", "/all", 200)
	marker(1, "repaired")
	// A new-version write constructs the exact old proof through WriteBack.
	call(v2, "PUT", "/repair", 200)
	if body := call(v1, "GET", "/all", 200); !strings.Contains(body, `"title":"repaired"`) {
		t.Fatal("reverse proof did not preserve old reader", body)
	}
	var oldTitle string
	if err := request.QueryRow(ctx, "select title from notes.notes where id='one'").Scan(&oldTitle); err != nil || oldTitle != "repaired" {
		t.Fatal("reverse proof did not populate retained old column", oldTitle, err)
	}
	call(v1, "PUT", "/invalid", 200)
	call(v2, "GET", "/all", 500)
	marker(1, "blocked")
	if output := run("v2", "contract", false); !strings.Contains(string(output), "reject") {
		t.Fatalf("Contract failed for a reason other than checked rejection: %s", output)
	}
	marker(1, "blocked")
	var minimum, floor int
	if err := request.QueryRow(ctx, "select min_version,compat_floor from notes.tesl_schema_state").Scan(&minimum, &floor); err != nil || minimum != 1 || floor != 1 {
		t.Fatal("rejected Contract retired old application", minimum, floor, err)
	}
	call(v1, "PUT", "/repair", 200)
	run("v2", "contract", true)
	contracted = true
	// The table-retirement extension must never turn an ordinary transforming
	// Contract into an empty-finality retirement, even on an idempotent retry.
	if _, err := f.worker.Exec(ctx, `select notes.tesl_retire_row_window(2,
 (select contract_hash from notes.tesl_row_contracts where version=2),
 (select artefact_hash from notes.tesl_schema_versions where version=2 and step='retired'),
 '{}'::text[], '{}'::smallint[],
 (select source_abi from notes.tesl_schema_versions where version=2 and step='retired'))`); err == nil || !strings.Contains(err.Error(), "empty final inventory requires exact pure table Contract") {
		t.Fatal("ordinary transforming Contract accepted empty finality", err)
	}
	marker(2, "repaired")
	call(v1, "PUT", "/invalid", 503)
	call(v2, "GET", "/all", 200)
	call(v2, "PUT", "/touch", 200)
	marker(2, "repaired")
	if body := call(v2, "PUT", "/invalid", 200); !strings.Contains(body, "refused") {
		t.Fatal("current application admitted an invalid proven value", body)
	}
	marker(2, "repaired")
	var count int
	if err := request.QueryRow(ctx, "select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='title'").Scan(&count); err != nil || count != 0 {
		t.Fatal("Contract retained previous proof column", count, err)
	}
	run("v2", "contract", true)
}

// A weaker current proof does not invent an old value. Optional write-back
// refuses incompatible writes atomically until Contract removes old columns.
func TestPgRowProofWeakenActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_PROOF_RETYPE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated proof applications required")
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
	call(v1, "POST", "/two", 200)
	if body := call(v1, "PUT", "/invalid", 200); !strings.Contains(body, "refused") {
		t.Fatal("strong old proof unexpectedly accepted blocked value", body)
	}
	run("v2", "worker")
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	snapshot := func() string {
		var state string
		if err := request.QueryRow(ctx, "select jsonb_agg(to_jsonb(n) order by id)::text from notes.notes n").Scan(&state); err != nil {
			t.Fatal(err)
		}
		return state
	}
	before := snapshot()
	call(v2, "PUT", "/invalid", 500)
	if snapshot() != before {
		t.Fatal("rejected write-back changed a stored row")
	}
	call(v2, "PUT", "/mixed", 500)
	if snapshot() != before {
		t.Fatal("rejected write-back did not roll back the earlier write in its transaction")
	}
	if os.Getenv("TESL_ROW_PROOF_REMOVED") == "1" {
		call(v2, "PUT", "/empty", 500)
		if snapshot() != before {
			t.Fatal("proof removal fabricated a historical value")
		}
	}
	call(v1, "PUT", "/repair", 200)
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"title":"repaired"`) {
		t.Fatal("old writer did not invalidate and retransform", body)
	}
	wantTitle := `"title":"blocked"`
	call(v2, "PUT", "/touch-all", 200)
	run("v2", "contract")
	call(v1, "PUT", "/repair", 503)
	if os.Getenv("TESL_ROW_PROOF_REMOVED") == "1" {
		call(v2, "PUT", "/empty", 200)
		wantTitle = `"title":""`
	} else {
		call(v2, "PUT", "/invalid", 200)
	}
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, wantTitle) {
		t.Fatal("Contract lost newly valid data", body)
	}
	var count int
	if err := request.QueryRow(ctx, "select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='title'").Scan(&count); err != nil || count != 0 {
		t.Fatal("old proof column survived Contract", count, err)
	}
}

func TestPgRowOptionalReverseBackfillActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_PROOF_RETYPE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated optional reverse application required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx, f.namespace = ctx, "notes"
	run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
	call := func(base, method, path string, status int) string {
		return pgCallRowAccessApp(t, f.ctx, base, method, path, status)
	}
	run("v1", "install")
	run("v1", "worker")
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	call(v1, "POST", "/one", 200)
	pgRunRowWorkerUntil(t, f, root, "v2", 30*time.Second, func() bool {
		var materialized bool
		if err := request.QueryRow(f.ctx, "select exists(select 1 from notes.notes where id='one' and _tesl_v=2)").Scan(&materialized); err != nil {
			t.Fatal(err)
		}
		return materialized
	})
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	var old, current string
	var generation int
	if err := request.QueryRow(f.ctx, "select title,title__v2,_tesl_v from notes.notes where id='one'").Scan(&old, &current, &generation); err != nil || old != "valid" || current != "valid" || generation != 2 {
		t.Fatal("backfill must keep the actual historical value when no inverse is provided", old, current, generation, err)
	}
	call(v2, "PUT", "/repair", 500)
	call(v1, "PUT", "/repair", 200)
	run("v2", "contract")
	call(v1, "PUT", "/repair", 503)
	call(v2, "PUT", "/repair", 200)
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"title":"repaired"`) {
		t.Fatal("retirement failed to remove the historical write-back requirement", body)
	}
}
