package migrationtest

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// Keep the native compiler-upgrade gate from passing merely because its
// retained-database witness was skipped. Exercise the actual test entry points.
func TestCompiledLessonsRequireConfiguredPostgres(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"TestCompiledAdditiveLessonRetainsRows", "TestCompiledMigrationCompilerUpgradeRetainsRows"} {
		t.Run(name, func(t *testing.T) {
			for _, required := range []string{"", "1"} {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				cmd := exec.CommandContext(ctx, executable, "-test.run=^"+name+"$", "-test.v")
				for _, value := range os.Environ() {
					key, _, _ := strings.Cut(value, "=")
					if key != "TESL_MIGRATION_TEST_DSN" && key != "TESL_MIGRATION_TEST_REQUIRE_POSTGRES" {
						cmd.Env = append(cmd.Env, value)
					}
				}
				cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_DSN=", "TESL_MIGRATION_TEST_REQUIRE_POSTGRES="+required)
				output, runErr := cmd.CombinedOutput()
				cancel()
				if required == "1" {
					if runErr == nil || !strings.Contains(string(output), "--- FAIL: "+name) ||
						!strings.Contains(string(output), "requires TESL_MIGRATION_TEST_DSN") {
						t.Fatalf("required native PostgreSQL test did not fail: %v\n%s", runErr, output)
					}
				} else if runErr != nil || !strings.Contains(string(output), "--- SKIP: "+name) {
					t.Fatalf("optional native PostgreSQL test did not skip: %v\n%s", runErr, output)
				}
			}
		})
	}
}
