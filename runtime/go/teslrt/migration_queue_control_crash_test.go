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
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Real backend termination, not an injected Go error. Each boundary is observed
// on another connection, then the installer backend is killed before resumption.
func pgQueueCandidateCrash(t *testing.T, f *pgControlTestFixture, boundary string, run func(*pgx.Conn) error) {
	t.Helper()
	dir, err := os.MkdirTemp("", "tesl-q4-crash-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "gate.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	arrived, release, stopped := make(chan struct{}, 1), make(chan struct{}), make(chan struct{})
	resume := sync.OnceFunc(func() { close(release) })
	defer func() { resume(); _ = listener.Close(); <-stopped }()
	go func() {
		defer close(stopped)
		paused := false
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
			var event struct{ Name string }
			if json.NewDecoder(io.LimitReader(conn, 4096)).Decode(&event) == nil {
				if event.Name == boundary && !paused {
					paused = true
					arrived <- struct{}{}
					<-release
				}
				_, _ = io.WriteString(conn, "continue\n")
			}
			_ = conn.Close()
		}
	}()
	previousSocket, previousActor := os.Getenv("TESL_MIGRATION_TEST_SOCKET"), os.Getenv("TESL_MIGRATION_TEST_ACTOR")
	defer func() {
		t.Setenv("TESL_MIGRATION_TEST_SOCKET", previousSocket)
		t.Setenv("TESL_MIGRATION_TEST_ACTOR", previousActor)
	}()
	t.Setenv("TESL_MIGRATION_TEST_SOCKET", socket)
	t.Setenv("TESL_MIGRATION_TEST_ACTOR", "queue-candidate-installer")
	conn, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	pid := conn.PgConn().PID()
	done := make(chan error, 1)
	go func() {
		var failure error
		defer func() {
			if p := recover(); p != nil {
				failure = fmt.Errorf("boundary panic: %v", p)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			_ = conn.Close(ctx)
			done <- failure
		}()
		failure = run(conn)
	}()
	select {
	case <-arrived:
	case err := <-done:
		t.Fatalf("candidate ended before %s: %v", boundary, err)
	case <-f.ctx.Done():
		t.Fatal("candidate failed to reach crash boundary")
	}
	var killed bool
	if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_terminate_backend($1::integer)", pid).Scan(&killed); err != nil || !killed {
		t.Fatalf("backend termination: %v %v", killed, err)
	}
	resume()
	if err := <-done; err == nil {
		t.Fatal("terminated backend reported ordinary success")
	}
}

func TestQueueCandidateFreshCrashPublishesAllOrNothing(t *testing.T) {
	boundaries := []string{"queue-candidate-table-tesl_queue_baseline", "queue-candidate-table-tesl_queue_versions", "queue-candidate-table-tesl_queue_contracts", "queue-candidate-table-tesl_queue_payloads", "queue-candidate-table-tesl_jobs", "queue-candidate-inventory", "control-before-commit", "control-after-commit"}
	for _, boundary := range boundaries {
		t.Run(boundary, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			h := pgQueueCandidateTestHistory(t, false)
			pgQueueCandidateCrash(t, f, boundary, func(conn *pgx.Conn) error { _, err := pgInstallQueueCandidate(f.ctx, conn, h, f.roles); return err })
			committed := boundary == "control-after-commit"
			var exists bool
			if err := f.installer.QueryRow(f.ctx, "select exists(select 1 from pg_catalog.pg_namespace where nspname='notes_app')").Scan(&exists); err != nil || exists != committed {
				t.Fatalf("partial/lost namespace %v %v", exists, err)
			}
			var before PgMigrationControlState
			if committed {
				var err error
				before, err = pgCandidateReadOnly(t, f, request, &h)
				if err != nil {
					t.Fatal(err)
				}
			}
			retried, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles)
			if err != nil {
				t.Fatal(err)
			}
			if committed && !reflect.DeepEqual(before, retried) {
				t.Fatal("retry replaced committed baseline identity")
			}
			if _, err := pgCandidateReadOnly(t, f, request, &h); err != nil {
				t.Fatal(err)
			}
		})
	}
}
func TestQueueCandidateUpgradeCrashPreservesUnknownAuthority(t *testing.T) {
	boundaries := []string{"queue-candidate-upgrade-before-objects", "queue-candidate-table-tesl_queue_baseline", "queue-candidate-table-tesl_queue_versions", "queue-candidate-table-tesl_queue_contracts", "queue-candidate-table-tesl_queue_payloads", "queue-candidate-table-tesl_jobs", "queue-candidate-upgrade-before-commit", "queue-candidate-upgrade-after-commit"}
	for _, boundary := range boundaries {
		t.Run(boundary, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.install(t, 1)
			f.expand(t, 2)
			h := pgExpansionTestHistory(f.namespace, 2)
			before := pgControlUpgradePreservedRows(t, f)
			pgQueueCandidateCrash(t, f, boundary, func(conn *pgx.Conn) error { _, err := pgUpgradeQueueCandidate(f.ctx, conn, h, f.roles); return err })
			var format int
			var tables int
			if err := f.installer.QueryRow(f.ctx, "select format_version,(select count(*) from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='notes_app' and c.relname like 'tesl_queue_%') from notes_app.tesl_schema_meta").Scan(&format, &tables); err != nil {
				t.Fatal(err)
			}
			committed := strings.HasSuffix(boundary, "after-commit")
			if (committed && format != 4) || (!committed && (format != 3 || tables != 0)) {
				t.Fatalf("partial upgrade format=%d relations=%d", format, tables)
			}
			if before != pgControlUpgradePreservedRows(t, f) {
				t.Fatal("crash changed completed entity/history rows")
			}
			state, err := pgUpgradeQueueCandidate(f.ctx, f.installer, h, f.roles)
			if err != nil || state.Format != 4 {
				t.Fatalf("retry %+v %v", state, err)
			}
			if _, err := pgCandidateReadOnly(t, f, request, nil); err != nil {
				t.Fatal(err)
			}
			var authority string
			if err := f.installer.QueryRow(f.ctx, "select inventory_authority from notes_app.tesl_queue_baseline").Scan(&authority); err != nil || authority != "unknown" {
				t.Fatalf("crash/retry promoted baseline %s %v", authority, err)
			}
		})
	}
}
