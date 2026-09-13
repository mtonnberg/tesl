//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgRowWorkerCASMiss(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated applications required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
	call := func(base, method, path string, status int) string {
		return pgCallRowAccessApp(t, f.ctx, base, method, path, status)
	}
	run("v1", "install")
	run("v1", "worker")
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	call(v1, "POST", "/one", 200)
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"row-backfill-after-conversion", 1}, {"row-backfill-after-read", 2}})
	stop, done := pgStartSettledWorker(t, f, root, "v2", "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	t.Cleanup(func() { pauses[0].resume(); pauses[1].resume() })
	select {
	case <-pauses[0].arrived:
	case err := <-done:
		t.Fatalf("worker before CAS race: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("worker did not convert source row")
	}
	// The real old application changes xmin after the worker read and conversion.
	call(v1, "PUT", "/one", 200)
	pauses[0].resume()
	select {
	case <-pauses[1].arrived:
	case err := <-done:
		t.Fatalf("worker before next source read: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("worker did not continue beyond missed CAS")
	}
	var committedCursor string
	var committedRows, committedPins int
	if err := request.QueryRow(f.ctx, "select last_pk::text,rows_done,(select count(*) from notes.tesl_row_processing) from notes.tesl_schema_backfill_shards").Scan(&committedCursor, &committedRows, &committedPins); err != nil || committedCursor != `"one"` || committedRows != 0 || committedPins != 0 {
		t.Fatal("missed CAS must commit scan cursor without materialization count or ABI", committedCursor, committedRows, committedPins, err)
	}
	pauses[1].resume()
	deadline := time.Now().Add(10 * time.Second)
	for {
		select {
		case err := <-done:
			t.Fatalf("worker lost CAS instead of preserving it: %v", err)
		default:
		}
		var provisional bool
		err := request.QueryRow(f.ctx, "select exists(select 1 from notes.tesl_schema_backfill_shards where state='provisional')").Scan(&provisional)
		if err == nil && provisional {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("missed CAS pass did not finish", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	stop()
	var marker, pins, rowsDone, floor int
	var title string
	var cursor *string
	var target *int
	err := request.QueryRow(f.ctx, "select _tesl_v,title,count,(select count(*) from notes.tesl_row_processing),(select rows_done from notes.tesl_schema_backfill_shards),(select last_pk::text from notes.tesl_schema_backfill_shards),(select compat_floor from notes.tesl_schema_state) from notes.notes where id='one'").Scan(&marker, &title, &target, &pins, &rowsDone, &cursor, &floor)
	if err != nil || marker != 1 || title != "edited" || target != nil || pins != 0 || rowsDone != 0 || cursor != nil || floor != 1 {
		t.Fatal("CAS miss materialized a row, lost old write, pinned ABI or advanced floor", marker, title, target, pins, rowsDone, cursor, floor, err)
	}
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	if body := call(v2, "GET", "/one", 200); !strings.Contains(body, "edited") {
		t.Fatal("lazy read lost fresh old value", body)
	}
	if err := request.QueryRow(f.ctx, "select count(*) from notes.tesl_row_processing").Scan(&pins); err != nil || pins != 0 {
		t.Fatal("read after CAS miss pinned ABI", pins, err)
	}
	// The explicit final pass rescans before retirement and preserves the newer
	// source value, despite provisional progress having passed that key.
	run("v2", "contract")
	if err := request.QueryRow(f.ctx, "select _tesl_v,title,count from notes.notes where id='one'").Scan(&marker, &title, &target); err != nil || marker != 2 || title != "edited" || target == nil || *target != 7 {
		t.Fatal("final pass lost missed source update", marker, title, target, err)
	}
	call(v1, "PUT", "/one", 503)
	call(v2, "PUT", "/one", 200)
	t.Log("actual old-writer xmin conflict skipped CAS without ABI/progress count, then final pass rescanned and preserved it")
}

// This separates accepted nominal record keys from the raw PostgreSQL JSONB
// carrier. The transforming Copy boundary is checked by the compiler fixture;
// this V1 application does not claim nominal Same transport or worker coverage.
func TestPgRowJSONKeyBaselineAndCarrier(t *testing.T) {
	root := os.Getenv("TESL_ROW_JSON_KEY_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated JSONB key application required")
	}
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	app, output := pgStartRowAccessObservedApp(t, f, root, "v1")
	for _, key := range []string{"one", "two", "three"} {
		pgCallRowAccessApp(t, f.ctx, app, "POST", "/"+key, 200)
	}
	body := pgCallRowAccessApp(t, f.ctx, app, "GET", "/all", 200)
	for _, key := range []string{"one", "two", "three"} {
		if !strings.Contains(body, `"storedKey":"`+key+`"`) {
			t.Fatal("original private codec lost nominal key", key, body)
		}
	}
	var valid int
	if err := request.QueryRow(f.ctx, `select count(*) from notes.notes where jsonb_typeof(id)='object' and id->>'storedKey'=title and _tesl_v=1`).Scan(&valid); err != nil || valid != 3 {
		t.Fatal("actual original encoder did not persist distinct JSONB object keys", valid, err)
	}

	// SQL NULL means there is no cursor. JSON literal null is an actual ordered
	// JSONB value; the comparison must retain it instead of decoding it as SQL NULL.
	query := `with keys(id) as (values ('null'::jsonb),('[]'::jsonb),('["a"]'::jsonb),('{"storedKey":"one"}'::jsonb)) select id::text as serialized from keys where ($1::jsonb is null or id>$1::jsonb) order by keys.id`
	read := func(arg any) []string {
		rows, err := request.Query(f.ctx, query, arg)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var result []string
		for rows.Next() {
			var value string
			if err := rows.Scan(&value); err != nil {
				t.Fatal(err)
			}
			result = append(result, value)
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		return result
	}
	all := read(nil)
	afterNull := read([]byte("null"))
	if len(all) != 4 || all[0] != "[]" || all[1] != "null" || len(afterNull) != 2 || strings.Join(afterNull, "|") != strings.Join(all[2:], "|") {
		t.Fatal("JSONB cursor confused absent SQL NULL with JSON literal null", all, afterNull)
	}
	var wrong int
	if err := request.QueryRow(f.ctx, `with keys(id) as (values ('null'::jsonb),('[]'::jsonb),('["a"]'::jsonb),('{"storedKey":"one"}'::jsonb)) select count(*) from keys where id>(jsonb_populate_record(null::notes.notes,jsonb_build_object('id',$1::jsonb))).id`, []byte("null")).Scan(&wrong); err != nil || wrong != 0 {
		t.Fatal("counterexample no longer exercises composite JSON-null conversion", wrong, err)
	}

	// The physical JSONB carrier permits this value, but the generated record
	// decoder requires an object. This deliberately corrupts user data only.
	if _, err := request.Exec(f.ctx, `insert into notes.notes(id,title) values ('null'::jsonb,'malformed-json-null')`); err != nil {
		t.Fatal(err)
	}
	pgCallRowAccessApp(t, f.ctx, app, "GET", "/all", 500)
	if !strings.Contains(output.String(), "a record column failed its codec: no decode alternative matched") {
		t.Fatal("malformed JSON null did not reach original record codec", output.String())
	}
	var abi, shards, contracts, floor int
	if err := request.QueryRow(f.ctx, `select (select count(*) from notes.tesl_row_processing),(select count(*) from notes.tesl_schema_backfill_shards),(select count(*) from notes.tesl_row_contracts),compat_floor from notes.tesl_schema_state`).Scan(&abi, &shards, &contracts, &floor); err != nil || abi != 0 || shards != 0 || contracts != 0 || floor != 1 {
		t.Fatal("malformed baseline key unexpectedly changed migration state", abi, shards, contracts, floor, err)
	}
	if _, err := request.Exec(f.ctx, `delete from notes.notes where id='null'::jsonb`); err != nil {
		t.Fatal(err)
	}
	pgCallRowAccessApp(t, f.ctx, app, "GET", "/all", 200)
	t.Log("real V1 record-key codec accepts object keys and rejects JSON null; raw PostgreSQL cursor keeps SQL NULL distinct from JSON null")
}
