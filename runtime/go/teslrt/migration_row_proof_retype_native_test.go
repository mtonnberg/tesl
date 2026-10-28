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
	// Expansion succeeds, but proof rejection must abort durable materialization.
	if output := run("v2", "worker", false); !strings.Contains(string(output), "reject") {
		t.Fatalf("worker failed for a reason other than checked rejection: %s", output)
	}
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

// Weakening expands the new writer's accepted domain. WriteBack must construct
// an actually valid old representation when that value is not expressible under
// the predecessor proof. The new column retains the exact value until an old
// write invalidates the row and causes replay from that old representation.
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
	if body := call(v1, "PUT", "/invalid", 200); !strings.Contains(body, "refused") {
		t.Fatal("strong old proof unexpectedly accepted blocked value", body)
	}
	run("v2", "worker")
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	if body := call(v2, "PUT", "/invalid", 200); !strings.Contains(body, "invalidated") {
		t.Fatal("weakened proof did not admit newly valid value", body)
	}
	var prior, current string
	var generation int
	if err := request.QueryRow(ctx, "select title,title__v2,_tesl_v from notes.notes where id='one'").Scan(&prior, &current, &generation); err != nil || prior != "valid" || current != "blocked" || generation != 2 {
		t.Fatal("reverse establish did not preserve two proof domains", prior, current, generation, err)
	}
	if body := call(v1, "GET", "/all", 200); !strings.Contains(body, `"title":"valid"`) {
		t.Fatal("old reader did not receive valid fallback", body)
	}
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"title":"blocked"`) {
		t.Fatal("new reader lost accepted value", body)
	}
	// An unrelated old-writer change invalidates the whole predecessor row.
	// The explicit fallback is valid, but is not a lossless round trip.
	assertFallbackReplay := func(storedCurrent string) {
		t.Helper()
		call(v1, "PUT", "/touch", 200)
		var memo string
		if err := request.QueryRow(ctx, "select title,title__v2,_tesl_v,memo from notes.notes where id='one'").Scan(&prior, &current, &generation, &memo); err != nil || prior != "valid" || current != storedCurrent || generation != 1 || memo != "touched" {
			t.Fatal("unrelated old write did not invalidate retained representations", prior, current, generation, memo, err)
		}
		if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"title":"valid"`) || !strings.Contains(body, `"memo":"touched"`) {
			t.Fatal("new reader did not replay the explicit old fallback", body)
		}
		if err := request.QueryRow(ctx, "select title__v2,_tesl_v from notes.notes where id='one'").Scan(&current, &generation); err != nil || current != storedCurrent || generation != 1 {
			t.Fatal("lazy replay unexpectedly materialized the fallback", current, generation, err)
		}
	}
	assertFallbackReplay("blocked")
	call(v2, "PUT", "/invalid", 200)
	if os.Getenv("TESL_ROW_PROOF_REMOVED") == "1" {
		if body := call(v2, "PUT", "/empty", 200); !strings.Contains(body, "emptied") {
			t.Fatal("removed proof still refused empty scalar", body)
		}
		if err := request.QueryRow(ctx, "select title,title__v2 from notes.notes where id='one'").Scan(&prior, &current); err != nil || prior != "valid" || current != "" {
			t.Fatal("proof removal lost raw value or valid predecessor", prior, current, err)
		}
		// Change memo first so the following V1 /touch is an actual update,
		// not a no-op with the already stored "touched" value.
		call(v2, "PUT", "/touch-all", 200)
		assertFallbackReplay("")
	}
	call(v1, "PUT", "/repair", 200)
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"title":"repaired"`) {
		t.Fatal("old writer did not invalidate and retransform", body)
	}
	wantTitle := `"title":"blocked"`
	if os.Getenv("TESL_ROW_PROOF_REMOVED") == "1" {
		call(v2, "PUT", "/empty", 200)
		wantTitle = `"title":""`
	} else {
		call(v2, "PUT", "/invalid", 200)
	}
	run("v2", "contract")
	call(v1, "PUT", "/repair", 503)
	if body := call(v2, "GET", "/all", 200); !strings.Contains(body, wantTitle) {
		t.Fatal("Contract lost newly valid data", body)
	}
	var count int
	if err := request.QueryRow(ctx, "select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='title'").Scan(&count); err != nil || count != 0 {
		t.Fatal("old proof column survived Contract", count, err)
	}
}
