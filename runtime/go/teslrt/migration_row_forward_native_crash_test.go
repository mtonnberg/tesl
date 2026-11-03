//go:build tesl_migration_test

package teslrt

import (
	"bytes"
	"fmt"
	"os"
	"testing"
)

func TestPgRowForwardCompiledCrashPrefixes(t *testing.T) {
	root := os.Getenv("TESL_ROW_FORWARD_CALIBRATION")
	if root == "" {
		t.Skip("separate compiler-emitted calibration artifacts required")
	}
	cases := []pgExpansionBoundary{{"row-forward-after-manifest", 1}, {"row-forward-after-intent", 1}, {"row-forward-before-publication", 1}}
	for hit := 1; hit <= 3; hit++ {
		cases = append(cases, pgExpansionBoundary{"row-forward-after-ddl", hit}, pgExpansionBoundary{"row-forward-after-receipt", hit})
	}
	for _, point := range cases {
		t.Run(fmt.Sprintf("%s/%d", point.name, point.hit), func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.namespace = "notes"
			pgForwardNativeRun(t, f, root, "v1", "install", true)
			pgForwardNativeRun(t, f, root, "v1", "worker", true)
			if _, err := request.Exec(f.ctx, `insert into notes.notes(id,author,title) values('one','original','hello')`); err != nil {
				t.Fatal(err)
			}
			arrived, resume := pgPauseExpansionBoundary(t, point.name, point.hit)
			defer resume()
			command := pgForwardNativeCommand(f, root, "v2", "worker")
			var output bytes.Buffer
			command.Stdout = &output
			command.Stderr = &output
			if err := command.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() { _ = command.Process.Kill() }()
			done := make(chan error, 1)
			go func() { done <- command.Wait() }()
			select {
			case <-arrived:
			case err := <-done:
				t.Fatalf("worker did not reach boundary: %v %s", err, output.String())
			case <-f.ctx.Done():
				t.Fatal(f.ctx.Err())
			}
			if err := command.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			resume()
			if err := <-done; err == nil {
				t.Fatal("killed worker succeeded")
			}
			// The unchanged original binary must understand the actual committed prefix,
			// including a manifest without intent and columns without the final trigger.
			pgForwardNativeRun(t, f, root, "v1", "observe", true)
			var current int
			if err := request.QueryRow(f.ctx, "select current from notes.tesl_schema_state").Scan(&current); err != nil || current != 1 {
				t.Fatal("crash published V2 prematurely", current, err)
			}
			if _, err := request.Exec(f.ctx, `update notes.notes set title='old app still writes' where id='one'`); err != nil {
				t.Fatal(err)
			}
			pgForwardNativeRun(t, f, root, "v2", "worker", true)
			pgForwardNativeRun(t, f, root, "v1", "observe", true)
			pgForwardNativeRun(t, f, root, "v2", "read", true)
		})
	}
}
