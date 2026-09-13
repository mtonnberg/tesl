//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgRowRetypePhysicalContractApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_RETYPE_PHYSICAL_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated Retype applications required")
	}
	adt := os.Getenv("TESL_ROW_RETYPE_PHYSICAL_KIND") == "adt"
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
	call(v1, "POST", "/two", 200)
	expected := 2
	if adt {
		call(v1, "POST", "/absent", 200)
		expected++
	}
	stop, done := pgStartSettledWorker(t, f, root, "v2")
	deadline := time.Now().Add(10 * time.Second)
	for {
		select {
		case err := <-done:
			t.Fatalf("worker exited before durable backfill: %v", err)
		default:
		}
		var converted int
		var provisional bool
		err := f.worker.QueryRow(ctx, "select (select count(*) from notes.notes where _tesl_v=2),exists(select 1 from notes.tesl_schema_backfill_shards where state='provisional')").Scan(&converted, &provisional)
		if err == nil && converted == expected && provisional {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("worker did not materialize preexisting Retype rows", converted, provisional, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	stop()
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	oldValue, newValue, extraValue := "metadata->>'oldText'", "metadata__v2->>'newText'", "metadata__v2->>'detail'"
	if adt {
		oldValue, newValue, extraValue = "metadata->'fields'->>'text'", "metadata__v2->'fields'->>'text'", "metadata__v2->'fields'->>'extra'"
	}
	var oldText, newText, detail string
	if err := request.QueryRow(ctx, "select "+oldValue+","+newValue+","+extraValue+" from notes.notes where id='one'").Scan(&oldText, &newText, &detail); err != nil || oldText != "one" || newText != oldText || detail != "migrated" {
		t.Fatal("worker must durably preserve both nominal codecs", oldText, newText, detail, err)
	}
	if adt {
		if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"tag":"Missing"`) || strings.Contains(body, `"tag":"Absent"`) {
			t.Fatal("worker nullary ADT migration", body)
		}
	}
	call(v1, "PUT", "/one", 200)
	var marker int
	if err := request.QueryRow(ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil || marker != 1 {
		t.Fatal("late original Retype writer must invalidate", marker, err)
	}
	call(v2, "GET", "/all", 200)
	if err := request.QueryRow(ctx, "select _tesl_v from notes.notes where id='one'").Scan(&marker); err != nil || marker != 1 {
		t.Fatal("lazy read must leave the late old row for the actual final pass", marker, err)
	}
	pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"row-contract-after-floor", 1}})[0]
	command := pgForwardNativeCommand(f, root, "v2", "contract")
	command.Env = append(command.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
	var output pgRowAppOutput
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	completed := make(chan error, 1)
	reaped := make(chan struct{})
	go func() { completed <- command.Wait(); close(completed); close(reaped) }()
	t.Cleanup(func() {
		pause.resume()
		select {
		case <-reaped:
		default:
			_ = command.Process.Kill()
			<-reaped
		}
	})
	select {
	case <-pause.arrived:
	case err := <-completed:
		t.Fatalf("Contract exited before pre-DDL assertion: %v\n%s", err, output.String())
	case <-ctx.Done():
		t.Fatal("Contract did not reach prepared settled phase", ctx.Err(), output.String())
	}
	if err := request.QueryRow(ctx, "select "+newValue+","+extraValue+",_tesl_v from notes.notes where id='one'").Scan(&newText, &detail, &marker); err != nil || newText != "edited-metadata" || detail != "migrated" || marker != 2 {
		t.Fatal("final pass did not durably remigrate the late old JSONB write", newText, detail, marker, err)
	}
	// This is the same V2 Main process, while old columns still exist. Neither
	// settled insert nor update may call the old codec or require its storage.
	call(v2, "POST", "/three", 200)
	var omitted bool
	if err := request.QueryRow(ctx, "select metadata is null and author is null,_tesl_v from notes.notes where id='three'").Scan(&omitted, &marker); err != nil || !omitted || marker != 2 {
		t.Fatal("prepared Retype insert must omit old storage and stamp current generation", omitted, marker, err)
	}
	call(v2, "PUT", "/one", 200)
	call(v2, "GET", "/all", 200)
	if err := request.QueryRow(ctx, "select "+newValue+","+extraValue+" from notes.notes where id='one'").Scan(&newText, &detail); err != nil || newText != "edited-metadata" || detail != "made" {
		t.Fatal("same process must update new codec before old-column DDL", newText, detail, err)
	}
	pause.resume()
	select {
	case err := <-completed:
		if err != nil {
			t.Fatalf("Contract failed: %v\n%s", err, output.String())
		}
	case <-ctx.Done():
		t.Fatal("Contract failed to complete", ctx.Err(), output.String())
	}
	var oldColumns, contracts int
	if err := request.QueryRow(ctx, "select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name in ('metadata','author')").Scan(&oldColumns); err != nil || oldColumns != 0 {
		t.Fatal("Contract did not remove exact old JSONB and Rename storage", oldColumns, err)
	}
	if err := f.worker.QueryRow(ctx, "select count(*) from notes.tesl_schema_versions where version=2 and step='contracted'").Scan(&contracts); err != nil || contracts != 1 {
		t.Fatal("Contract completion not durable", contracts, err)
	}
	call(v2, "POST", "/missing", 200)
	call(v2, "PUT", "/one", 200)
	body := call(v2, "GET", "/all", 200)
	if adt && (!strings.Contains(body, `"tag":"Missing"`) || strings.Contains(body, `"tag":"Absent"`)) {
		t.Fatal("settled ADT constructor encoding", body)
	}
	if !adt && (strings.Contains(body, `"oldText"`) || !strings.Contains(body, `"newText":"missing"`)) {
		t.Fatal("settled record codec", body)
	}
	call(v1, "PUT", "/one", 503)
	run("v2", "contract")
	t.Log("preexisting record/ADT worker backfill, late old write, finality, pre-DDL current-only writes, same-process post-Contract queries and idempotent resume passed")
}
