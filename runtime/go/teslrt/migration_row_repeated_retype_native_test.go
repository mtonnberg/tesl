//go:build tesl_migration_test

package teslrt

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgRowRepeatedRetypeCatchupRestart(t *testing.T) {
	root := os.Getenv("TESL_ROW_REPEATED_RETYPE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated V1/V2/V3 programs required")
	}
	for _, boundary := range []string{"row-forward-after-receipt", "row-contract-after-retirement", "row-contract-after-receipt", "row-catchup-after-step"} {
		t.Run(boundary, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			t.Cleanup(cancel)
			f.ctx, f.namespace = ctx, "notes"
			pgForwardNativeRun(t, f, root, "v1", "install", true)
			pgForwardNativeRun(t, f, root, "v1", "worker", true)
			// Ordinary Request DML seeds bytes in the exact V1 codec. No control
			// state or heartbeat is fabricated to make retirement pass.
			if _, err := request.Exec(ctx, `insert into notes.notes(id,metadata,author,title,memo) values ('one','{"oldText":"retained"}','writer','one','base')`); err != nil {
				t.Fatal(err)
			}
			pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{boundary, 1}})
			defer pauses[0].resume()
			cmd := pgForwardNativeCommand(f, root, "v3", "catch-up")
			cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			var output pgRowAppOutput
			cmd.Stdout, cmd.Stderr = &output, &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			select {
			case <-pauses[0].arrived:
			case err := <-done:
				t.Fatalf("catch-up exited before interruption: %v %s", err, output.String())
			case <-ctx.Done():
				_ = cmd.Process.Kill()
				<-done
				t.Fatal("catch-up did not reach interruption", output.String())
			}
			var concurrent *pgRowAppOutput
			if boundary == "row-contract-after-retirement" {
				concurrent, _ = pgRowAdditiveProcess(t, pgForwardNativeCommand(f, root, "v3", "catch-up"))
				waiting, stop := context.WithTimeout(ctx, 100*time.Millisecond)
				if concurrent.WaitContains(waiting, `"kind":"schema-caught-up"`) {
					stop()
					_ = cmd.Process.Kill()
					<-done
					t.Fatal("competing coordinator bypassed the held boot fence")
				}
				stop()
			}
			_ = cmd.Process.Kill()
			<-done
			pauses[0].resume()
			out := pgForwardNativeRun(t, f, root, "v3", "catch-up", true)
			if !strings.Contains(string(out), `"currentVersion":3`) {
				t.Fatal("catch-up failed to report latest target", string(out))
			}
			if concurrent != nil && !concurrent.WaitContains(ctx, `"kind":"schema-caught-up"`) {
				t.Fatal("competing coordinator could not resume the same history", concurrent.String())
			}
			var current, minimum, generation int
			var text, detail string
			if err := request.QueryRow(ctx, `select s.current,s.min_version,n._tesl_v,n.metadata__v2->>'newText',n.metadata__v2->>'detail' from notes.tesl_schema_state s,notes.notes n where n.id='one'`).Scan(&current, &minimum, &generation, &text, &detail); err != nil || current != 3 || minimum != 2 || generation != 2 || text != "retained" || detail != "migrated" {
				t.Fatal("interrupted historical conversion lost retained source", current, minimum, generation, text, detail, err)
			}
			pgForwardNativeRun(t, f, root, "v3", "catch-up", true)
		})
	}
}

// All three binaries come from public compilation and guarded source generation.
// The compiler fixture removes their original source tree before this runs.
func TestPgRowRepeatedRetypeApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_REPEATED_RETYPE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated V1/V2/V3 programs required")
	}
	f, request := pgNewWorkerTest(t)
	// Three independent releases, two Contracts, rejection/repair and process
	// restart exceed the base fixture's single-window 30-second budget.
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	run := func(version, mode string) {
		started := time.Now()
		pgForwardNativeRun(t, f, root, version, mode, true)
		t.Logf("%s %s completed in %s", version, mode, time.Since(started))
	}
	call := func(base, method, path string, status int) string {
		return pgCallRowAccessApp(t, f.ctx, base, method, path, status)
	}
	columnCount := func(name string, want int) {
		t.Helper()
		var count int
		err := request.QueryRow(f.ctx, `select count(*) from information_schema.columns where table_schema='notes' and table_name='notes' and column_name=$1`, name).Scan(&count)
		if err != nil || count != want {
			t.Fatalf("column %s: want %d got %d: %v", name, want, count, err)
		}
	}
	readRow := func(base, id, textKey, detailKey, text, detail string) {
		t.Helper()
		var rows []struct {
			ID       string            `json:"id"`
			Owner    string            `json:"owner"`
			Count    int               `json:"count"`
			Metadata map[string]string `json:"metadata"`
		}
		if err := json.Unmarshal([]byte(call(base, "GET", "/all", 200)), &rows); err != nil {
			t.Fatal(err)
		}
		for _, row := range rows {
			if row.ID == id {
				wantCount := 9
				if id == "one" {
					wantCount = 7 // Original V1 row acquired V2's computed value.
				}
				if row.Count != wantCount || row.Owner != "writer" {
					t.Fatalf("%s: second Retype changed an unrelated value: %#v", id, row)
				}
				if len(row.Metadata) != 2 || row.Metadata[textKey] != text || row.Metadata[detailKey] != detail {
					t.Fatalf("%s: wrong versioned codec/value: %#v", id, row.Metadata)
				}
				return
			}
		}
		t.Fatalf("missing row %s", id)
	}
	snapshot := func() string {
		t.Helper()
		var result string
		if err := request.QueryRow(f.ctx, `select coalesce(jsonb_agg(to_jsonb(n) order by id),'[]'::jsonb)::text from notes.notes n`).Scan(&result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	run("v1", "install")
	run("v1", "worker")
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	call(v1, "POST", "/one", 200)
	run("v2", "worker")
	v2 := pgStartRowAccessApp(t, f, root, "v2")
	refusal := pgForwardNativeRun(t, f, root, "v3", "worker", false)
	if !strings.Contains(string(refusal), "Contract V2") {
		t.Fatalf("premature V3 should require Contract V2: %s", refusal)
	}
	columnCount("metadata__v3", 0)
	run("v2", "contract")
	columnCount("metadata", 0)
	columnCount("metadata__v2", 1)
	call(v1, "GET", "/all", 503)
	call(v2, "PUT", "/one", 200)
	readRow(v2, "one", "newText", "detail", "edited-metadata", "made")

	run("v3", "worker")
	// This original V2 process predates V3 expansion. Its new row must remain
	// generation 2; a V3 projection must not claim durable materialization.
	call(v2, "POST", "/two", 200)
	v3 := pgStartRowAccessApp(t, f, root, "v3")
	before := snapshot()
	readRow(v3, "two", "thirdText", "thirdDetail", "two", "made")
	if after := snapshot(); after != before {
		t.Fatal("lazy repeated conversion wrote physical state")
	}
	var generation int
	var absent bool
	if err := request.QueryRow(f.ctx, `select _tesl_v,metadata__v3 is null from notes.notes where id='two'`).Scan(&generation, &absent); err != nil || generation != 2 || !absent {
		t.Fatal("late predecessor insert claimed current generation", generation, absent, err)
	}
	call(v3, "POST", "/three", 200)
	readRow(v3, "three", "thirdText", "thirdDetail", "three", "made-v3")
	readRow(v2, "three", "newText", "detail", "three", "made-v3")
	var oldText, oldDetail, newText, newDetail string
	if err := request.QueryRow(f.ctx, `select metadata__v2->>'newText',metadata__v2->>'detail',metadata__v3->>'thirdText',metadata__v3->>'thirdDetail',_tesl_v from notes.notes where id='three'`).Scan(&oldText, &oldDetail, &newText, &newDetail, &generation); err != nil || oldText != "three" || newText != oldText || oldDetail != "made-v3" || newDetail != oldDetail || generation != 3 {
		t.Fatal("second-window dual writes use incorrect storage or codecs", oldText, oldDetail, newText, newDetail, generation, err)
	}
	before = snapshot()
	call(v3, "PUT", "/conflict", 500)
	if after := snapshot(); after != before {
		t.Fatal("failed second-window bulk write changed stored rows or generations")
	}
	call(v3, "PUT", "/all", 200)
	call(v2, "PUT", "/one", 200)
	if err := request.QueryRow(f.ctx, `select _tesl_v from notes.notes where id='one'`).Scan(&generation); err != nil || generation != 2 {
		t.Fatal("late V2 update did not invalidate generation 3", generation, err)
	}
	readRow(v3, "one", "thirdText", "thirdDetail", "edited-metadata", "made")
	call(v2, "PUT", "/all", 200)
	readRow(v3, "three", "thirdText", "thirdDetail", "three", "made-v3")
	// A rejected row in the second window cannot retire the V2 binary needed
	// to repair it. Its failed lazy conversion must not change physical state.
	call(v2, "POST", "/reject", 200)
	before = snapshot()
	call(v3, "GET", "/all", 500)
	if after := snapshot(); after != before {
		t.Fatal("rejected lazy conversion changed stored state")
	}
	refusal = pgForwardNativeRun(t, f, root, "v3", "contract", false)
	if !strings.Contains(string(refusal), "reject") {
		t.Fatalf("Contract failed for a reason other than conversion rejection: %s", refusal)
	}
	var minimum, floor int
	if err := request.QueryRow(f.ctx, `select min_version,compat_floor from notes.tesl_schema_state`).Scan(&minimum, &floor); err != nil || minimum != 2 || floor != 2 {
		t.Fatal("rejected second Contract retired its repair writer", minimum, floor, err)
	}
	if err := request.QueryRow(f.ctx, `select _tesl_v,metadata__v3 is null from notes.notes where id='reject'`).Scan(&generation, &absent); err != nil || generation != 2 || !absent {
		t.Fatal("rejected source row was materialized", generation, absent, err)
	}
	columnCount("metadata__v2", 1)
	call(v2, "PUT", "/repair", 200)
	readRow(v3, "reject", "thirdText", "thirdDetail", "repaired", "made")
	run("v3", "contract")
	columnCount("metadata__v2", 0)
	columnCount("metadata__v3", 1)
	call(v2, "GET", "/all", 503)
	readRow(v3, "one", "thirdText", "thirdDetail", "edited-metadata", "made")
	readRow(v3, "two", "thirdText", "thirdDetail", "two", "made")
	readRow(v3, "three", "thirdText", "thirdDetail", "three", "made-v3")
	readRow(v3, "reject", "thirdText", "thirdDetail", "repaired", "made")
	call(v3, "PUT", "/one", 200)
	call(v3, "POST", "/missing", 200)
	readRow(v3, "missing", "thirdText", "thirdDetail", "missing", "made-v3")
	before = snapshot()
	run("v3", "contract")
	if after := snapshot(); after != before {
		t.Fatal("restarting completed Contract changed retained values")
	}
	restarted := pgStartRowAccessApp(t, f, root, "v3")
	readRow(restarted, "one", "thirdText", "thirdDetail", "edited-metadata", "made-v3")
}
