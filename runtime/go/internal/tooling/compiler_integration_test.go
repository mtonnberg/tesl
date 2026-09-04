package tooling

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestBuiltCompilerJSONQuerySurface(t *testing.T) {
	_, testFile, _, _ := runtime.Caller(0)
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(testFile), "../../../.."))
	compiler := filepath.Join(repoRoot, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("compiler build unavailable")
	}
	client := Client{Executable: compiler, Environment: withEnvironment(os.Environ(), "TESL_REPO_ROOT", repoRoot)}
	source := "module Probe exposing [double]\nimport Tesl.Prelude exposing [Int]\nfn double(n: Int) -> Int = n * 2\n"
	flags := []string{
		"--check-json", "--type-at-json", "--field-at-json", "--completions-json",
		"--signature-help-json", "--definition-json", "--occurrences-json",
		"--selection-range-json", "--type-definition-json", "--local-bindings-json",
		"--semantic-json",
	}
	for _, flag := range flags {
		t.Run(flag, func(t *testing.T) {
			positions := []string{"2", "1"}
			if flag == "--check-json" || flag == "--local-bindings-json" || flag == "--semantic-json" {
				positions = nil
			}
			payload, result, err := client.QuerySourceJSON(context.Background(), flag, "/workspace/probe.tesl", source, positions...)
			if err != nil {
				t.Fatalf("%v (exit=%d stderr=%s)", err, result.ExitCode, result.Stderr)
			}
			var envelope struct {
				Version int `json:"version"`
			}
			if err := json.Unmarshal(payload, &envelope); err != nil {
				t.Fatal(err)
			}
			if envelope.Version != 1 {
				t.Fatalf("version = %d, payload = %s", envelope.Version, payload)
			}
		})
	}
	t.Run("--doc-json", func(t *testing.T) {
		payload, _, err := client.QueryJSON(context.Background(), "--doc-json", "Int")
		if err != nil {
			t.Fatal(err)
		}
		var envelope struct {
			Version int               `json:"version"`
			Entries []json.RawMessage `json:"entries"`
		}
		if err := json.Unmarshal(payload, &envelope); err != nil {
			t.Fatal(err)
		}
		if envelope.Version != 1 || len(envelope.Entries) == 0 {
			t.Fatalf("doc response = %s", payload)
		}
	})
}

func TestBuiltCompilerAcceptsScopedDatabaseCapabilities(t *testing.T) {
	_, testFile, _, _ := runtime.Caller(0)
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(testFile), "../../../.."))
	compiler := filepath.Join(repoRoot, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("compiler build unavailable")
	}
	client := Client{Executable: compiler, Environment: withEnvironment(os.Environ(), "TESL_REPO_ROOT", repoRoot)}
	source := "module ScopedProbe exposing [Note, listNotes]\n" +
		"import Tesl.Prelude exposing [List, String]\n" +
		"import Tesl.DB exposing [dbRead]\n" +
		"entity Note table \"notes\" primaryKey id { id: String @db(text) }\n" +
		"fn listNotes() -> List Note requires [dbRead Note] = select note from Note\n"
	payload, result, err := client.QuerySourceJSON(context.Background(), "--check-json", "/workspace/scoped-probe.tesl", source)
	if err != nil {
		t.Fatalf("scoped capability diagnostic query failed: %v (exit=%d stderr=%s payload=%s)", err, result.ExitCode, result.Stderr, payload)
	}
	var envelope struct {
		Diagnostics []json.RawMessage `json:"diagnostics"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		t.Fatal(err)
	}
	if len(envelope.Diagnostics) != 0 {
		t.Fatalf("scoped capability produced editor diagnostics: %s", payload)
	}
}
