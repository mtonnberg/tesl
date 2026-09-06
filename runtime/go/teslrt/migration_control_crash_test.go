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
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestPgMigrationControlCrashBeforeAndAfterCommit(t *testing.T) {
	for _, boundary := range []string{"control-before-commit", "control-after-commit"} {
		t.Run(boundary, func(t *testing.T) {
			f := pgNewControlTest(t)
			// Keep the Unix path below the kernel limit independently of the
			// test's descriptive name and its temporary directory suffix.
			dir, err := os.MkdirTemp("", "tesl-control-crash-")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.RemoveAll(dir) })
			socket := filepath.Join(dir, "control.sock")
			listener, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			arrived, release, stopped := make(chan struct{}, 1), make(chan struct{}), make(chan struct{})
			releaseBoundary := sync.OnceFunc(func() { close(release) })
			defer func() {
				releaseBoundary()
				_ = listener.Close()
				<-stopped
			}()
			go func() {
				defer close(stopped)
				paused := false
				for {
					conn, err := listener.Accept()
					if err != nil {
						return
					}
					_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
					var event struct{ Name string }
					if err := json.NewDecoder(io.LimitReader(conn, 4096)).Decode(&event); err == nil {
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
			t.Setenv("TESL_MIGRATION_TEST_SOCKET", socket)
			t.Setenv("TESL_MIGRATION_TEST_ACTOR", "control-installer")
			conn, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
			if err != nil {
				t.Fatal(err)
			}
			pid := conn.PgConn().PID()
			done := make(chan error, 1)
			go func() {
				defer func() {
					if failure := recover(); failure != nil {
						done <- fmt.Errorf("installer boundary: %v", failure)
					}
				}()
				_, err := InstallPgMigrationControl(f.ctx, conn, f.namespace, f.roles, 7)
				_ = conn.Close(context.Background())
				done <- err
			}()
			select {
			case <-arrived:
			case err := <-done:
				t.Fatalf("installer ended before boundary: %v", err)
			case <-f.ctx.Done():
				t.Fatal("installer did not reach commit boundary")
			}
			var committedUUID string
			if boundary == "control-after-commit" {
				if err := f.installer.QueryRow(f.ctx, "select database_uuid::text from notes_app.tesl_schema_meta").Scan(&committedUUID); err != nil {
					t.Fatal(err)
				}
			}
			var killed bool
			if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_terminate_backend($1::integer)", pid).Scan(&killed); err != nil || !killed {
				t.Fatalf("terminate installer backend: %v, %v", killed, err)
			}
			releaseBoundary()
			if err := <-done; err == nil {
				t.Fatal("terminated installer reported an ordinary successful return")
			}
			state, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
			if err != nil || state.Present != (boundary == "control-after-commit") {
				t.Fatalf("partial or lost control commit after backend death: %+v, %v", state, err)
			}
			retry := f.install(t, 9)
			if boundary == "control-after-commit" {
				if retry.DatabaseUUID != committedUUID || !reflect.DeepEqual(state, retry) {
					t.Fatalf("retry replaced committed installation: %+v / %+v", state, retry)
				}
			} else if retry.InitialVersion != 9 {
				t.Fatalf("uncommitted installer reserved a durable target: %+v", retry)
			}
		})
	}
}
