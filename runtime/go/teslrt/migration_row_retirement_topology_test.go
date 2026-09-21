package teslrt

import (
	"os"
	"strings"
	"testing"
)

func TestRowRetirementRequiresWorkerBeforeBaseline(t *testing.T) {
	for _, test := range []struct {
		name, topology    string
		deployed, allowed bool
	}{
		{"explicit embedded", "Embedded", false, false},
		{"default embedded", "", false, false},
		{"explicit worker", "Worker", false, true},
		{"deployed default worker", "", true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			value, present := os.LookupEnv("TESL_DEPLOYED")
			t.Cleanup(func() {
				if present {
					_ = os.Setenv("TESL_DEPLOYED", value)
				} else {
					_ = os.Unsetenv("TESL_DEPLOYED")
				}
			})
			if test.deployed {
				t.Setenv("TESL_DEPLOYED", "1")
			} else {
				if err := os.Unsetenv("TESL_DEPLOYED"); err != nil {
					t.Fatal(err)
				}
			}
			h, _ := rowRetirementSourceFixture(t)
			companion := map[string]any{"version": 1, "kind": "compiled-row-transform-history", "compilerAbi": h.SourceCompilerABI, "storedValueCompatibility": h.StoredValueCompatibility, "databases": []any{map[string]any{"database": h.Database, "family": h.Family, "namespace": h.Namespace, "currentVersion": h.CurrentVersion, "transforms": []any{}}}}
			db := rowTestRegister(t, h, companion)
			db.Config.MigrationTopology = test.topology
			// No connection is configured; rejection precedes even sealed-App/catalog
			// requirements, and cannot cause database I/O or partial installation.
			_, err := pgCompiledRowBaseline(db)
			if err == nil {
				t.Fatal("unsealed fixture unexpectedly admitted")
			}
			if test.allowed {
				if !strings.Contains(err.Error(), "sealed complete App") {
					t.Fatal("Worker topology did not reach ordinary baseline validation", err)
				}
			} else if !strings.Contains(err.Error(), "table Drop requires Worker migration topology") {
				t.Fatal("unsupported topology did not fail before baseline work", err)
			}
		})
	}
}
