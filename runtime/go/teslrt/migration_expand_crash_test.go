//go:build tesl_migration_test

package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Count this actor's arrivals locally, independently of global hook counters.
// The test controls the real executor through its build-tag-only Unix seam.
func pgPauseExpansionBoundary(t *testing.T, name string, hit int) (<-chan struct{}, func()) {
	t.Helper()
	pauses := pgPauseExpansionBoundaries(t, []pgExpansionBoundary{{name, hit}})
	return pauses[0].arrived, pauses[0].resume
}

type pgExpansionBoundary struct {
	name string
	hit  int
}

type pgExpansionBoundaryPause struct {
	arrived <-chan struct{}
	resume  func()
}

// Multiple pauses share one listener and count each named boundary locally. A
// successor can be stopped before it has a chance to hide the first actor's
// effects by adopting or removing a physical object.
func pgPauseExpansionBoundaries(t *testing.T, boundaries []pgExpansionBoundary) []pgExpansionBoundaryPause {
	t.Helper()
	dir, err := os.MkdirTemp("", "tesl-expand-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "control.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	pauses := make([]pgExpansionBoundaryPause, len(boundaries))
	arrivals := make([]chan struct{}, len(boundaries))
	releases := make([]chan struct{}, len(boundaries))
	for i := range boundaries {
		arrivals[i], releases[i] = make(chan struct{}, 1), make(chan struct{})
		pauses[i] = pgExpansionBoundaryPause{arrivals[i], sync.OnceFunc(func() { close(releases[i]) })}
	}
	stopped := make(chan struct{})
	t.Cleanup(func() {
		for _, pause := range pauses {
			pause.resume()
		}
		_ = listener.Close()
		<-stopped
	})
	go func() {
		defer close(stopped)
		seen := make(map[string]int)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
			var event struct{ Name string }
			if err := json.NewDecoder(io.LimitReader(conn, 4096)).Decode(&event); err == nil {
				seen[event.Name]++
				for i, boundary := range boundaries {
					if event.Name == boundary.name && seen[event.Name] == boundary.hit {
						arrivals[i] <- struct{}{}
						<-releases[i]
					}
				}
				_, _ = io.WriteString(conn, "continue\n")
			}
			_ = conn.Close()
		}
	}()
	t.Setenv("TESL_MIGRATION_TEST_SOCKET", socket)
	t.Setenv("TESL_MIGRATION_TEST_ACTOR", "expansion")
	return pauses
}

func pgStartTestExpansion(f *pgControlTestFixture, conn *pgx.Conn, version int) <-chan error {
	done := make(chan error, 1)
	go func() {
		defer func() {
			_ = conn.Close(context.Background())
			if failure := recover(); failure != nil {
				done <- fmt.Errorf("expansion boundary: %v", failure)
			}
		}()
		_, err := ExecutePgMigrationExpansion(f.ctx, conn, pgExpansionTestHistory(f.namespace, version), f.roles)
		done <- err
	}()
	return done
}

func TestPgMigrationExpansionCrashAtEveryDDLAndCommit(t *testing.T) {
	for _, boundary := range []string{"expansion-before-commit", "expansion-after-commit", "expansion-after-ddl"} {
		hits := 8 // intent + six objects + expanded lifecycle
		if boundary == "expansion-after-ddl" {
			hits = 6
		}
		for hit := 1; hit <= hits; hit++ {
			t.Run(fmt.Sprintf("%s/%d", boundary, hit), func(t *testing.T) {
				f := pgNewControlTest(t)
				f.install(t, 1)
				f.expand(t, 1)
				f.call(t, "insert into notes_app.notes(id,active) values ('retained',true)")
				arrived, resume := pgPauseExpansionBoundary(t, boundary, hit)
				conn, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
				if err != nil {
					t.Fatal(err)
				}
				pid := conn.PgConn().PID()
				done := pgStartTestExpansion(f, conn, 2)
				select {
				case <-arrived:
				case err := <-done:
					t.Fatalf("executor ended before boundary: %v", err)
				case <-f.ctx.Done():
					t.Fatal("executor failed to reach boundary")
				}
				var killed bool
				if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_terminate_backend($1::integer)", pid).Scan(&killed); err != nil || !killed {
					t.Fatalf("kill own executor: %v,%v", killed, err)
				}
				resume()
				if err := <-done; err == nil {
					t.Fatal("killed executor reported ordinary success")
				}
				t.Setenv("TESL_MIGRATION_TEST_SOCKET", "")
				want := hit - 2
				if boundary != "expansion-before-commit" {
					want = hit - 1
				}
				want = max(0, min(6, want))
				var count, current int
				if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_expansion_objects where version=2").Scan(&count); err != nil || count != want {
					t.Fatalf("non-atomic object progress: got %d want %d,%v", count, want, err)
				}
				wantCurrent := 1
				if boundary == "expansion-after-commit" && hit == 8 {
					wantCurrent = 2
				}
				if err := f.worker.QueryRow(f.ctx, "select current from notes_app.tesl_schema_state").Scan(&current); err != nil || current != wantCurrent {
					t.Fatalf("partial lifecycle commit: got %d want %d,%v", current, wantCurrent, err)
				}
				f.expand(t, 2)
				if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.notes where id='retained' and active and rank=-9007199254740993").Scan(&count); err != nil || count != 1 {
					t.Fatalf("lost or incorrectly migrated pre-crash row: %d,%v", count, err)
				}
			})
		}
	}
}

func TestPgMigrationExpansionSerializesCompetingVersions(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	f.call(t, "insert into notes_app.notes(id,active) values ('retained',true)")
	arrived, resume := pgPauseExpansionBoundary(t, "expansion-after-ddl", 1)
	leader, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	done := pgStartTestExpansion(f, leader, 2)
	select {
	case <-arrived:
	case err := <-done:
		t.Fatalf("leader did not pause: %v", err)
	case <-f.ctx.Done():
		t.Fatal("leader did not reach DDL")
	}
	var contenders []<-chan error
	var pids []int64
	for i := range 10 {
		conn, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
		if err != nil {
			t.Fatal(err)
		}
		pids = append(pids, int64(conn.PgConn().PID()))
		contenders = append(contenders, pgStartTestExpansion(f, conn, 1+i%3))
	}
	for {
		var waiting int
		if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_locks where pid=any($1::bigint[]) and locktype='advisory' and not granted", pids).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting == 10 {
			break
		}
		select {
		case <-f.ctx.Done():
			t.Fatalf("only %d contenders waited on the boot lock", waiting)
		case <-time.After(10 * time.Millisecond):
		}
	}
	resume()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	for _, done := range contenders {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("TESL_MIGRATION_TEST_SOCKET", "")
	state := f.expand(t, 3)
	if state.Current != 3 || len(state.Versions) != 5 {
		t.Fatalf("duplicate or lost concurrent lifecycle: %+v", state)
	}
}
