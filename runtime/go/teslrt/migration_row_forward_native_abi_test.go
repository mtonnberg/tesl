//go:build tesl_migration_test

package teslrt

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func pgForwardABIRoot(t *testing.T) string {
	t.Helper()
	root := os.Getenv("TESL_ROW_FORWARD_CALIBRATION")
	if root == "" {
		t.Skip("separate actual A/B compiler artifacts required")
	}
	var a, b map[string]any
	for name, dst := range map[string]*map[string]any{"v2": &a, "v2b": &b} {
		raw, err := os.ReadFile(filepath.Join(root, name, "retained-physical-history.json"))
		if err != nil {
			t.Fatal(err)
		}
		if err = json.Unmarshal(raw, dst); err != nil {
			t.Fatal(err)
		}
	}
	if a["compilerAbi"] == b["compilerAbi"] || a["storedValueCompatibility"] != b["storedValueCompatibility"] || !reflect.DeepEqual(a["databases"], b["databases"]) {
		t.Fatal("fixtures must be independently compiled ABIs with exact same physical behavior contracts")
	}
	return root
}

func TestPgRowForwardPreopenedDifferentABIRefusesAfterFirstWrite(t *testing.T) {
	root := pgForwardABIRoot(t)
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	if _, err := request.Exec(f.ctx, `insert into notes.notes(id,author,title) values('one','original','hello')`); err != nil {
		t.Fatal(err)
	}
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	command := pgForwardNativeCommand(f, root, "v2b", "park")
	var diagnostics bytes.Buffer
	command.Stderr = &diagnostics
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = command.Process.Kill() }()
	scanner := bufio.NewScanner(output)
	if !scanner.Scan() || scanner.Text() != "opened" {
		_ = command.Wait()
		t.Fatalf("B did not open before processing: %s", diagnostics.String())
	}
	if _, err := fmt.Fprintln(input, "read"); err != nil {
		t.Fatal(err)
	}
	if !scanner.Scan() || strings.Contains(scanner.Text(), `"error"`) {
		t.Fatalf("B initial lazy read refused: %s", scanner.Text())
	}
	var count int
	if err := request.QueryRow(f.ctx, "select count(*) from notes.tesl_row_processing").Scan(&count); err != nil || count != 0 {
		t.Fatal("read pinned ABI", count, err)
	}
	pgForwardNativeRun(t, f, root, "v2", "insert", true)
	if _, err := fmt.Fprintln(input, "read"); err != nil {
		t.Fatal(err)
	}
	if !scanner.Scan() || !strings.Contains(scanner.Text(), "compiler ABI is pinned") {
		t.Fatalf("preopened B read survived another ABI's first write: %s", scanner.Text())
	}
	if _, err := fmt.Fprintln(input, "quit"); err != nil {
		t.Fatal(err)
	}
	if err := command.Wait(); err != nil {
		t.Fatal(err, diagnostics.String())
	}
	pgForwardNativeRun(t, f, root, "v1", "observe", true)
}

func TestPgRowForwardFirstABIOrdersDisjointReadThenWriteTransactions(t *testing.T) {
	root := pgForwardABIRoot(t)
	for _, second := range []string{"v2", "v2b"} {
		t.Run(second, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.namespace = "notes"
			pgForwardNativeRun(t, f, root, "v1", "install", true)
			pgForwardNativeRun(t, f, root, "v1", "worker", true)
			if _, err := request.Exec(f.ctx, `insert into notes.notes(id,author,title) values('one','first','original'),('two','second','original')`); err != nil {
				t.Fatal(err)
			}
			pgForwardNativeRun(t, f, root, "v2", "worker", true)
			arrived, resume := pgPauseExpansionBoundary(t, "row-read-after-abi", 1)
			defer resume()
			first := pgForwardNativeCommand(f, root, "v2", "tx-update")
			first.Args = append(first.Args, "one")
			first.Env = append(first.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			var firstOut bytes.Buffer
			first.Stdout = &firstOut
			first.Stderr = &firstOut
			if err := first.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() { _ = first.Process.Kill() }()
			firstDone := make(chan error, 1)
			go func() { firstDone <- first.Wait() }()
			select {
			case <-arrived:
			case err := <-firstDone:
				t.Fatal("first transaction exited before barrier", err, firstOut.String())
			case <-f.ctx.Done():
				t.Fatal(f.ctx.Err())
			}
			next := pgForwardNativeCommand(f, root, second, "tx-update")
			next.Args = append(next.Args, "two")
			var nextOut bytes.Buffer
			next.Stdout = &nextOut
			next.Stderr = &nextOut
			if err := next.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() { _ = next.Process.Kill() }()
			nextDone := make(chan error, 1)
			go func() { nextDone <- next.Wait() }()
			// The second transaction must wait before its physical SELECT/row locks,
			// not reach an exclusive-latch upgrade after independently changing its row.
			deadline := time.Now().Add(5 * time.Second)
			for {
				var waiting int
				if err := f.installer.QueryRow(f.ctx, `select count(*) from pg_catalog.pg_stat_activity where datname=current_database() and usename=$1 and wait_event='advisory' and query like '%tesl_row_check_abi%'`, f.roles.Request).Scan(&waiting); err != nil {
					t.Fatal(err)
				}
				if waiting == 1 {
					break
				}
				select {
				case err := <-nextDone:
					t.Fatal("second transaction bypassed pre-operation ABI barrier", err, nextOut.String())
				default:
				}
				if time.Now().After(deadline) {
					t.Fatal("second transaction did not wait before row locks")
				}
				time.Sleep(5 * time.Millisecond)
			}
			resume()
			if err := <-firstDone; err != nil {
				t.Fatal("first transaction failed", err, firstOut.String())
			}
			err := <-nextDone
			if second == "v2" && err != nil {
				t.Fatal("same-ABI disjoint read/write transactions deadlocked", err, nextOut.String())
			}
			if second == "v2b" && (err == nil || !strings.Contains(nextOut.String(), "compiler ABI is pinned")) {
				t.Fatal("different ABI transaction did not refuse", err, nextOut.String())
			}
			var one, two int
			if err := request.QueryRow(f.ctx, `select (select _tesl_v from notes.notes where id='one'),(select _tesl_v from notes.notes where id='two')`).Scan(&one, &two); err != nil {
				t.Fatal(err)
			}
			want := 2
			if second == "v2b" {
				want = 1
			}
			if one != 2 || two != want {
				t.Fatal("wrong committed generations", one, two)
			}
		})
	}
}

func TestPgRowForwardCompiledPredecessorWorkerAfterPublication(t *testing.T) {
	root := pgForwardABIRoot(t)
	f, request := pgNewWorkerTest(t)
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	snapshot := func() string {
		t.Helper()
		var value string
		err := request.QueryRow(f.ctx, `select jsonb_build_object(
   'intent',(select to_jsonb(e) from notes.tesl_schema_expansions e where version=1),
   'receipts',(select jsonb_agg(to_jsonb(r) order by ordinal) from notes.tesl_schema_expansion_objects r where version=1),
   'source',(select jsonb_agg(to_jsonb(s)) from notes.tesl_row_versions s),
   'state',(select to_jsonb(s) from notes.tesl_schema_state s))::text`).Scan(&value)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	before := snapshot()
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v1b", "worker", true)
	if after := snapshot(); after != before {
		t.Fatal("completed predecessor worker mutated provenance or state", before, after)
	}
}
