package teslrt

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

const postgresRequirementProcessCase = "TESL_TEST_POSTGRES_REQUIREMENT_PROCESS_CASE"

// Exercise the actual testing.T failure/skip boundary in a child test process:
// a required database gate must have a failing exit status, not just a warning.
func TestPgMigrationControlRequiresConfiguredPostgres(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		host string
		port string
		user string
		want string
	}{
		{name: "absent", want: "no shared PostgreSQL cluster configured"},
		{name: "missing_host", port: "5432", user: "unused", want: "no shared PostgreSQL cluster configured"},
		{name: "missing_port", host: "/unused", user: "unused", want: "no shared PostgreSQL cluster configured"},
		{name: "missing_user", host: "/unused", port: "5432", want: "no shared PostgreSQL cluster configured"},
		{name: "malformed_port", host: "/unused", port: "not-a-port", user: "unused", want: "must be a port from 1 to 65535"},
		{name: "zero_port", host: "/unused", port: "0", user: "unused", want: "must be a port from 1 to 65535"},
		{name: "negative_port", host: "/unused", port: "-1", user: "unused", want: "must be a port from 1 to 65535"},
		{name: "oversized_port", host: "/unused", port: "65536", user: "unused", want: "must be a port from 1 to 65535"},
		{name: "unreachable", want: "is not accepting connections"},
	}
	for _, tc := range cases {
		for _, required := range []bool{false, true} {
			mode := "optional"
			if required {
				mode = "required"
			}
			t.Run(tc.name+"/"+mode, func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				// executable is this test binary, never a configured external program.
				cmd := exec.CommandContext(ctx, executable, "-test.run=^TestPostgresRequirementProcessHelper$", "-test.v")
				for _, value := range os.Environ() {
					key, _, _ := strings.Cut(value, "=")
					// In particular, PGHOST/PGPORT override the explicit DSN. No
					// inherited configuration may send this negative test to a server.
					if strings.HasPrefix(key, "PG") || strings.HasPrefix(key, "TESL_TEST_POSTGRES_SHARED_") ||
						key == "TESL_MIGRATION_TEST_REQUIRE_POSTGRES" || key == postgresRequirementProcessCase {
						continue
					}
					cmd.Env = append(cmd.Env, value)
				}
				cmd.Env = append(cmd.Env,
					postgresRequirementProcessCase+"="+tc.name,
					"TESL_TEST_POSTGRES_SHARED_HOST="+tc.host,
					"TESL_TEST_POSTGRES_SHARED_PORT="+tc.port,
					"TESL_TEST_POSTGRES_SHARED_USER="+tc.user,
				)
				if required {
					cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_REQUIRE_POSTGRES=1")
				}
				output, runErr := cmd.CombinedOutput()
				if ctx.Err() != nil {
					t.Fatalf("child test exceeded its deadline: %v\n%s", ctx.Err(), output)
				}
				if !strings.Contains(string(output), tc.want) {
					t.Fatalf("child did not report %q: %v\n%s", tc.want, runErr, output)
				}
				if required {
					var exitErr *exec.ExitError
					if !errors.As(runErr, &exitErr) || exitErr.ExitCode() != 1 ||
						!strings.Contains(string(output), "--- FAIL: TestPostgresRequirementProcessHelper") ||
						!strings.Contains(string(output), "required PostgreSQL unavailable:") {
						t.Fatalf("required PostgreSQL test did not fail: %v\n%s", runErr, output)
					}
				} else if runErr != nil || !strings.Contains(string(output), "--- SKIP: TestPostgresRequirementProcessHelper") {
					t.Fatalf("optional PostgreSQL test did not skip successfully: %v\n%s", runErr, output)
				}
			})
		}
	}
}

func TestPostgresRequirementProcessHelper(t *testing.T) {
	testCase := os.Getenv(postgresRequirementProcessCase)
	if testCase == "" {
		return
	}
	if testCase == "unreachable" {
		// This private directory has no PostgreSQL socket. Exercise real pgx
		// connection failures with the same readiness loop and a short budget.
		waitForClusterWithin(t, PostgresConfig{
			DBName: "postgres", User: "unused", Host: t.TempDir(), Port: 5432,
		}, 200*time.Millisecond)
	} else {
		liveCluster(t)
	}
	t.Fatal("unavailable cluster was accepted")
}
