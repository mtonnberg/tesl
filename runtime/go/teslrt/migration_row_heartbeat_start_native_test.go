//go:build tesl_migration_test

package teslrt

import (
	"net"
	"net/http"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestPgRowHeartbeatReusesVerifiedStartup(t *testing.T) {
	root := os.Getenv("TESL_ROW_ACCESS_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated original applications required")
	}
	for _, failRegistration := range []bool{false, true} {
		name := "owned connection"
		if failRegistration {
			name = "registration failure closes owner"
		}
		t.Run(name, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			f.namespace = "notes"
			pgForwardNativeRun(t, f, root, "v1", "install", true)
			pgForwardNativeRun(t, f, root, "v1", "worker", true)
			pgForwardNativeRun(t, f, root, "v2", "worker", true)
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			address := listener.Addr().String()
			_, port, _ := net.SplitHostPort(address)
			if err := listener.Close(); err != nil {
				t.Fatal(err)
			}
			boundaries := []pgExpansionBoundary{{"row-startup-before-heartbeat", 1}}
			if !failRegistration {
				boundaries = append(boundaries, pgExpansionBoundary{"row-startup-after-heartbeat", 1})
			}
			pauses := pgPauseConcurrentRowBoundaries(t, boundaries)
			for _, pause := range pauses {
				defer pause.resume()
			}
			cmd := pgForwardNativeCommand(f, root, "v2", "serve")
			cmd.Env = append(cmd.Env, "ROW_PORT="+port, "TESL_PG_POOL_LEASE_TIMEOUT_MS=10000", "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
			output, done := pgRowEpochNativeCommand(t, cmd)
			select {
			case <-pauses[0].arrived:
			case err := <-done:
				t.Fatal("startup failed before ownership transfer", err, output.String())
			case <-time.After(10 * time.Second):
				t.Fatal("startup did not reach ownership boundary", output.String())
			}
			pids := func() []int32 {
				var result []int32
				if err := f.installer.QueryRow(f.ctx, "select coalesce(array_agg(pid order by pid),'{}'::integer[]) from pg_catalog.pg_stat_activity where datname=pg_catalog.current_database() and usename=$1", f.roles.Request).Scan(&result); err != nil {
					t.Fatal(err)
				}
				return result
			}
			before := pids()
			var instances int
			if err := f.worker.QueryRow(f.ctx, "select count(*) from notes.tesl_schema_instances where instance like 'tesl-app:%'").Scan(&instances); err != nil || instances != 0 {
				t.Fatal("startup registered before its verified connection transfer", instances, err)
			}
			if failRegistration {
				if _, err := f.installer.Exec(f.ctx, "revoke execute on function notes.tesl_heartbeat(integer,integer,integer) from "+quoteIdentifier(f.roles.Request)); err != nil {
					t.Fatal(err)
				}
			}
			pauses[0].resume()
			if failRegistration {
				select {
				case err := <-done:
					if err == nil || !strings.Contains(output.String(), "permission denied") {
						t.Fatal("failed registration was published", err, output.String())
					}
				case <-time.After(10 * time.Second):
					t.Fatal("registration failure did not close startup", output.String())
				}
				after := pids()
				if len(after) != len(before)-2 {
					t.Fatal("failed registration leaked startup or pooled Request connection", before, after)
				}
				return
			}
			select {
			case <-pauses[1].arrived:
			case err := <-done:
				t.Fatal("registration failed", err, output.String())
			case <-time.After(10 * time.Second):
				t.Fatal("registration did not complete", output.String())
			}
			after := pids()
			if !slices.Equal(before, after) {
				t.Fatal("heartbeat replaced a fully verified startup connection", before, after)
			}
			var monitors int
			if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_stat_activity a join notes.tesl_schema_instances i on i.instance=a.application_name where a.datname=pg_catalog.current_database() and a.usename=$1 and i.instance like 'tesl-app:%'", f.roles.Request).Scan(&monitors); err != nil || monitors != 1 {
				t.Fatal("dedicated Request heartbeat identity differs", monitors, err)
			}
			if err := f.worker.QueryRow(f.ctx, "select count(*) from notes.tesl_schema_instances where instance like 'tesl-app:%'").Scan(&instances); err != nil || instances != 1 {
				t.Fatal("initial heartbeat was not durable before pool publication", instances, err)
			}
			pauses[1].resume()
			deadline := time.Now().Add(10 * time.Second)
			for !strings.Contains(output.String(), "tesl: serving") {
				if time.Now().After(deadline) {
					t.Fatal("application failed after registered startup", output.String())
				}
				time.Sleep(10 * time.Millisecond)
			}
			pgCallRowAccessApp(t, f.ctx, "http://"+address, "GET", "/all", 200)
			// Losing the transferred monitor must still refuse local admission;
			// recovery creates and fully verifies a new Request connection.
			if _, err := f.installer.Exec(f.ctx, "alter role "+quoteIdentifier(f.roles.Request)+" nologin"); err != nil {
				t.Fatal(err)
			}
			restore := func() {
				if _, err := f.installer.Exec(f.ctx, "alter role "+quoteIdentifier(f.roles.Request)+" login"); err != nil {
					t.Error(err)
				}
			}
			defer restore()
			if _, err := f.installer.Exec(f.ctx, "select pg_catalog.pg_terminate_backend(a.pid) from pg_catalog.pg_stat_activity a join notes.tesl_schema_instances i on i.instance=a.application_name where a.usename=$1 and i.instance like 'tesl-app:%'", f.roles.Request); err != nil {
				t.Fatal(err)
			}
			status := func() int {
				request, err := http.NewRequestWithContext(f.ctx, "GET", "http://"+address+"/all", nil)
				if err != nil {
					t.Fatal(err)
				}
				response, err := http.DefaultClient.Do(request)
				if err != nil {
					t.Fatal(err)
				}
				defer func() { _ = response.Body.Close() }()
				return response.StatusCode
			}
			deadline = time.Now().Add(10 * time.Second)
			for status() != 503 {
				if time.Now().After(deadline) {
					t.Fatal("transferred heartbeat loss did not refuse admission")
				}
				time.Sleep(50 * time.Millisecond)
			}
			restore()
			deadline = time.Now().Add(12 * time.Second)
			for status() != 200 {
				if time.Now().After(deadline) {
					t.Fatal("transferred heartbeat reconnect did not recover admission")
				}
				time.Sleep(50 * time.Millisecond)
			}

		})
	}
}
