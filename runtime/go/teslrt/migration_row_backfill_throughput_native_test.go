//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Opt-in throughput measurement for the ongoing Worker's row conversion: the
// compiler-generated V1/V2 Retype application of the physical Retype suite,
// with TESL_ROW_BACKFILL_THROUGHPUT_ROWS old rows stored before V2's Worker
// starts. It reports rows per second from Worker start until no old-generation
// row remains, and checks a sample row's converted value.
func TestPgRowBackfillThroughput(t *testing.T) {
	root := os.Getenv("TESL_ROW_RETYPE_PHYSICAL_PROGRAMS")
	rowsText := os.Getenv("TESL_ROW_BACKFILL_THROUGHPUT_ROWS")
	if root == "" || rowsText == "" {
		t.Skip("set TESL_ROW_RETYPE_PHYSICAL_PROGRAMS and TESL_ROW_BACKFILL_THROUGHPUT_ROWS")
	}
	rows, err := strconv.Atoi(rowsText)
	if err != nil || rows < 1 {
		t.Fatal("TESL_ROW_BACKFILL_THROUGHPUT_ROWS must be a positive integer")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true) // Expand while empty.
	// One row written by the real V1 application fixes the stored shape; the
	// rest are SQL copies of it with distinct keys and titles.
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	pgCallRowAccessApp(t, ctx, v1, "POST", "/one", 200)
	if _, err := f.installer.Exec(ctx, `insert into notes.notes
 select (pg_catalog.jsonb_populate_record(n, pg_catalog.jsonb_build_object(
   'id','note-'||lpad(g::text,9,'0'),'title','title-'||g))).*
 from notes.notes n, pg_catalog.generate_series(1,$1) g where n.id='one'`, rows); err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(ctx, "analyze notes.notes"); err != nil {
		t.Fatal(err)
	}
	worker := pgForwardNativeCommand(f, root, "v2", "worker")
	var output pgRowAppOutput
	worker.Stdout, worker.Stderr = &output, &output
	started := time.Now()
	if err := worker.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- worker.Wait(); close(done) }()
	t.Cleanup(func() {
		_ = worker.Process.Signal(os.Interrupt)
		select {
		case <-done:
		case <-time.After(20 * time.Second):
			_ = worker.Process.Kill()
			<-done
		}
	})
	for {
		var remaining int
		if err := request.QueryRow(ctx, `select count(*) from notes.notes where "_tesl_v"<2`).Scan(&remaining); err != nil {
			t.Fatal(err)
		}
		if remaining == 0 {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("Worker exited with %d rows left: %v\n%s", remaining, err, output.String())
		case <-time.After(100 * time.Millisecond):
		}
	}
	elapsed := time.Since(started)
	var converted string
	if err := request.QueryRow(ctx, `select metadata__v2::text from notes.notes where id='note-000000001'`).Scan(&converted); err != nil || !strings.Contains(converted, "migrated") {
		t.Fatal("converted value", converted, err)
	}
	t.Logf("converted %d rows in %s: %.0f rows/s", rows, elapsed.Round(time.Millisecond), float64(rows)/elapsed.Seconds())
}
