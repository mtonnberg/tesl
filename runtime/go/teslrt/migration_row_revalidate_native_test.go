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
func TestPgRowRevalidateActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_REVALIDATE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated Revalidate applications required")
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
	marker := func(want int, title string) {
		t.Helper()
		var got int
		var stored string
		if err := request.QueryRow(ctx, "select _tesl_v,title from notes.notes where id='one'").Scan(&got, &stored); err != nil || got != want || stored != title {
			t.Fatalf("stored generation/title: %d %q, want %d %q: %v", got, stored, want, title, err)
		}
	}
	run("v1", "install", true)
	run("v1", "worker", true)
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	call(v1, "POST", "/one", 200)
	call(v1, "PUT", "/invalid", 200)
	marker(1, "")
	// Expansion succeeds, but proof rejection must abort durable materialization.
	if output := run("v2", "worker", false); !strings.Contains(string(output), "reject") {
		t.Fatalf("worker failed for a reason other than checked rejection: %s", output)
	}
	marker(1, "")
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	call(v2, "GET", "/all", 500)
	marker(1, "")
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
			t.Fatalf("repaired Revalidate worker exited: %v", err)
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
	expectedColumns := []string{"_tesl_v", "id", "memo", "title"}
	legacy := os.Getenv("TESL_ROW_REVALIDATE_LEGACY") == "1"
	if legacy {
		expectedColumns = []string{"_tesl_v", "id", "memo", "obsolete", "title"}

	}
	if err := request.QueryRow(ctx, "select array_agg(column_name::text order by column_name) from information_schema.columns where table_schema='notes' and table_name='notes'").Scan(&columns); err != nil || !slices.Equal(columns, expectedColumns) {
		t.Fatal("Revalidate introduced shadow or changed physical columns", columns, err)
	}
	// The invalidation set covers every predecessor field, including a field
	// unrelated to the new proof. No old writer can retain a stale proof marker.
	call(v1, "PUT", "/touch", 200)
	marker(1, "repaired")
	call(v2, "GET", "/all", 200)
	marker(1, "repaired")
	if legacy {
		var before string
		if err := request.QueryRow(ctx, "select obsolete from notes.notes where id='one'").Scan(&before); err != nil || before != "changed-by-old" {
			t.Fatal("old application did not update its retained field", before, err)
		}
		call(v2, "PUT", "/touch", 200)
		var obsolete string
		if err := request.QueryRow(ctx, "select obsolete from notes.notes where id='one'").Scan(&obsolete); err != nil || obsolete != "retired" {
			t.Fatal("Revalidate and Legacy reverse adapter did not preserve old representation", obsolete, err)
		}
		call(v1, "GET", "/all", 200)
		marker(2, "repaired")
	}
	call(v1, "PUT", "/invalid", 200)
	call(v2, "GET", "/all", 500)
	marker(1, "")
	if output := run("v2", "contract", false); !strings.Contains(string(output), "reject") {
		t.Fatalf("Contract failed for a reason other than checked rejection: %s", output)
	}
	marker(1, "")
	var minimum, floor int
	if err := request.QueryRow(ctx, "select min_version,compat_floor from notes.tesl_schema_state").Scan(&minimum, &floor); err != nil || minimum != 1 || floor != 1 {
		t.Fatal("rejected Contract retired old application", minimum, floor, err)
	}
	call(v1, "PUT", "/repair", 200)
	run("v2", "contract", true)
	marker(2, "repaired")
	call(v1, "PUT", "/invalid", 503)
	call(v2, "GET", "/all", 200)
	call(v2, "PUT", "/touch", 200)
	marker(2, "repaired")
	if body := call(v2, "PUT", "/invalid", 200); !strings.Contains(body, "refused") {
		t.Fatal("current application admitted an invalid proven value", body)
	}
	marker(2, "repaired")
	if legacy {
		var count int
		if err := request.QueryRow(ctx, "select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name='obsolete'").Scan(&count); err != nil || count != 0 {
			t.Fatal("Contract retained removed Legacy column", count, err)
		}
	}
	run("v2", "contract", true)
}
