package teslmodapp

// Test-only binding: generated TestTeslApi functions and production handlers are
// unchanged. Resets clear memory tables only; PostgreSQL retains the rollout data.
import (
	"fmt"
	"os"
	"testing"

	"tesl.generated/teslmodapp/internal/teslrt"
)

func runBoundAPITests(m *testing.M) int {
	if os.Getenv("LIVED_API_DATABASE") != "1" {
		return m.Run()
	}
	if err := teslrt.PreflightApplicationDatabases(MainDatabase); err != nil {
		panic(err)
	}
	code := 1
	teslrt.WithDatabase(MainDatabase, func() {
		fmt.Println("postgres-api-tests: retained database bound")
		code = m.Run()
	})
	return code
}
