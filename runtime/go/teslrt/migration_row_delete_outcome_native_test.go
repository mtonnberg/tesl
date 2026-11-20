//go:build tesl_migration_test

package teslrt

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgRowDeleteOutcomeActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_PROOF_RETYPE_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated RowChange applications required")
	}
	for _, race := range []bool{false, true} {
		name := "crash-rollback-and-delete"
		if race {
			name = "old-writer-wins-CAS"
		}
		t.Run(name, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.namespace = "notes"
			run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
			call := func(base, method, path string, status int) string {
				return pgCallRowAccessApp(t, f.ctx, base, method, path, status)
			}
			run("v1", "install")
			run("v1", "worker")
			run("v2", "worker")
			v1 := pgStartRowAccessApp(t, f, root, "v1")
			v2 := pgStartRowAccessApp(t, f, root, "v2")
			call(v1, "POST", "/one", 200)
			call(v1, "PUT", "/obsolete", 200)
			call(v2, "GET", "/all", 500)
			count := func() int {
				var n int
				if err := request.QueryRow(f.ctx, "select count(*) from notes.notes where id='one'").Scan(&n); err != nil {
					t.Fatal(err)
				}
				return n
			}
			if count() != 1 {
				t.Fatal("a request read deleted an old row")
			}
			if race {
				pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"row-backfill-after-conversion", 1}, {"row-backfill-after-read", 2}})
				t.Cleanup(func() {
					for _, p := range pauses {
						p.resume()
					}
				})
				stop, done := pgStartSettledWorker(t, f, root, "v2", "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
				pgAwaitRowSnapshotBoundary(t, pauses[0], done)
				call(v1, "PUT", "/repair", 200)
				pauses[0].resume()
				pgAwaitRowSnapshotBoundary(t, pauses[1], done)
				if count() != 1 {
					t.Fatal("stale deletion removed a concurrently repaired row")
				}
				pauses[1].resume()
				stop()
				run("v2", "contract")
				if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"title":"repaired"`) {
					t.Fatal("final pass lost the accepted old-writer repair", body)
				}
			} else {
				pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"row-backfill-after-dml", 1}})[0]
				t.Cleanup(pause.resume)
				cmd := pgForwardNativeCommand(f, root, "v2", "worker")
				cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
				var output pgRowAppOutput
				cmd.Stdout, cmd.Stderr = &output, &output
				if err := cmd.Start(); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = cmd.Process.Kill() })
				done := make(chan error, 1)
				go func() { done <- cmd.Wait() }()
				pgAwaitRowSnapshotBoundary(t, pause, done)
				if count() != 1 {
					t.Fatal("uncommitted deletion became visible")
				}
				_ = cmd.Process.Kill()
				select {
				case <-done:
				case <-time.After(10 * time.Second):
					t.Fatal("worker did not stop")
				}
				pause.resume()
				if count() != 1 {
					t.Fatal("crashed deletion did not roll back")
				}
				run("v2", "worker")
				if count() != 0 {
					t.Fatal("worker did not publish explicit deletion")
				}
				call(v1, "POST", "/one", 200)
				call(v1, "PUT", "/obsolete", 200)
				run("v2", "worker")
				if count() != 0 {
					t.Fatal("worker did not rescan an old-writer recreation")
				}
				call(v1, "POST", "/two", 200)
				run("v2", "contract")
				if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"id":"a-valid"`) || strings.Contains(body, `"id":"one"`) {
					t.Fatal("deletion damaged retained rows", body)
				}
			}
			call(v1, "POST", "/one", 503)
		})
	}
}
