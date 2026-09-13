//go:build tesl_migration_test

package teslrt

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPgRowNominalPrimaryKeyLifecycle(t *testing.T) {
	programs := os.Getenv("TESL_ROW_NOMINAL_PROGRAMS")
	if programs == "" {
		t.Skip("actual compiler-generated nominal-key applications required")
	}
	for _, kind := range []string{"record", "adt"} {
		t.Run(kind, func(t *testing.T) {
			root := filepath.Join(programs, kind)
			f, request := pgNewWorkerTest(t)
			f.namespace = "notes"
			run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
			run("v1", "install")
			run("v1", "worker")
			v1 := pgStartRowAccessApp(t, f, root, "v1")
			for _, key := range []string{"one", "two", "three", "null"} {
				pgCallRowAccessApp(t, f.ctx, v1, "POST", "/"+key, 200)
			}
			var original string
			if err := request.QueryRow(f.ctx, `select jsonb_agg(id order by id)::text from notes.notes`).Scan(&original); err != nil {
				t.Fatal(err)
			}
			pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"row-backfill-after-read", 2}})
			stop, done := pgStartSettledWorker(t, f, root, "v2", "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			t.Cleanup(pauses[0].resume)
			select {
			case <-pauses[0].arrived:
			case err := <-done:
				t.Fatalf("actual nominal worker exited: %v", err)
			case <-time.After(15 * time.Second):
				t.Fatal("worker did not commit first nominal batch")
			}
			var cursorMatches bool
			var rows, converted, pins int
			if err := request.QueryRow(f.ctx, `select last_pk=(select id from notes.notes order by id asc limit 1),rows_done,(select count(*) from notes.notes where _tesl_v=2 and count=7),(select count(*) from notes.tesl_row_processing) from notes.tesl_schema_backfill_shards`).Scan(&cursorMatches, &rows, &converted, &pins); err != nil || !cursorMatches || rows != 1 || converted != 1 || pins != 1 {
				t.Fatal("durable nominal key cursor/DML/ABI differ", cursorMatches, rows, converted, pins, err)
			}
			pauses[0].resume()
			deadline := time.Now().Add(15 * time.Second)
			for {
				var provisional bool
				err := request.QueryRow(f.ctx, `select exists(select 1 from notes.tesl_schema_backfill_shards where state='provisional' and last_pk is null)`).Scan(&provisional)
				if err == nil && provisional {
					break
				}
				select {
				case err := <-done:
					t.Fatalf("worker exited before provisional completion: %v", err)
				default:
				}
				if time.Now().After(deadline) {
					t.Fatal("worker did not complete nominal pass", err)
				}
				time.Sleep(20 * time.Millisecond)
			}
			stop()
			v2 := pgStartRowAccessApp(t, f, root, "v2")
			if os.Getenv("TESL_ROW_NOMINAL_LEGACY") == "1" {
				pgCallRowAccessApp(t, f.ctx, v2, "PUT", "/current", 200)
				var currentKeys string
				var compatible int
				if err := request.QueryRow(f.ctx, `select jsonb_agg(id order by id)::text,count(*) filter(where retired='fallback') from notes.notes`).Scan(&currentKeys, &compatible); err != nil || currentKeys != original || compatible != 4 {
					t.Fatal("actual reverse DML changed nominal keys or lost Legacy values", currentKeys, compatible, err)
				}
			}
			pgCallRowAccessApp(t, f.ctx, v1, "PUT", "/all", 200)
			body := pgCallRowAccessApp(t, f.ctx, v2, "GET", "/all", 200)
			if strings.Count(body, `"count":7`) != 4 || strings.Count(body, `"title":"edited"`) != 4 {
				t.Fatal("lazy nominal rows lost late writer", body)
			}
			var demoted int
			if err := request.QueryRow(f.ctx, `select count(*) from notes.notes where _tesl_v=1`).Scan(&demoted); err != nil || demoted != 4 {
				t.Fatal("old writer did not invalidate actual nominal rows", demoted, err)
			}
			run("v2", "contract")
			var final string
			var floor, count int
			if err := request.QueryRow(f.ctx, `select jsonb_agg(id order by id)::text,count(*),(select compat_floor from notes.tesl_schema_state) from notes.notes where _tesl_v=2 and count=7 and title='edited'`).Scan(&final, &count, &floor); err != nil || final != original || count != 4 || floor != 2 {
				t.Fatal("final pass changed primary keys or lost source values", original, final, count, floor, err)
			}
			pgCallRowAccessApp(t, f.ctx, v1, "PUT", "/all", 503)
			pgCallRowAccessApp(t, f.ctx, v2, "PUT", "/all", 200)
			pgCallRowAccessApp(t, f.ctx, v2, "GET", "/all", 200)
			t.Log("actual unchanged handlers retained all nominal keys through worker cursor, late old write, final pass and Contract", original)
		})
	}
}
