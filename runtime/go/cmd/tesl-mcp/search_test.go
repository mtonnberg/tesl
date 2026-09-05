package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/tooling"
)

func TestMCPSearchDispatchAndBounds(t *testing.T) {
	script := filepath.Join(t.TempDir(), "compiler-helper.sh")
	if err := os.WriteFile(script, []byte(compilerHelperScript), 0o700); err != nil {
		t.Fatal(err)
	}
	server := &server{compiler: tooling.Client{Executable: script}}
	if _, err := server.callTool(context.Background(), "tesl.search", map[string]any{"query": "String -> Int"}); err != nil {
		t.Fatal(err)
	}
	for _, args := range []map[string]any{{}, {"query": 42}, {"query": strings.Repeat("é", 129)}} {
		if _, err := server.callTool(context.Background(), "tesl.search", args); err == nil {
			t.Fatalf("accepted invalid search arguments: %#v", args)
		}
	}
}

func TestMCPSearchUsesRealCompiler(t *testing.T) {
	compiler := os.Getenv("TESL_COMPILER")
	if compiler == "" {
		root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
		if err != nil {
			t.Fatal(err)
		}
		compiler = filepath.Join(root, "compiler", "_build", "default", "bin", "main.exe")
	}
	if _, err := os.Stat(compiler); err != nil {
		t.Skipf("built compiler unavailable: %v", err)
	}
	server := &server{compiler: tooling.Client{Executable: compiler}}
	for _, query := range []string{"String -> Int", "String -> Int requires [time]", "nowMillis"} {
		value, err := server.callTool(context.Background(), "tesl.search", map[string]any{"query": query})
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Error   *string `json:"error"`
			Results []struct {
				Name         string `json:"name"`
				Requirements struct {
					Capabilities []string `json:"capabilities"`
				} `json:"requirements"`
			} `json:"results"`
		}
		if err := json.Unmarshal(value, &result); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(query, "requires") {
			if result.Error == nil {
				t.Fatal("unsupported effect syntax did not return a structured error")
			}
		} else if len(result.Results) == 0 {
			t.Fatal("no discovery results")
		} else if query == "nowMillis" && strings.Join(result.Results[0].Requirements.Capabilities, ",") != "time" {
			t.Fatal("MCP lost time capability requirement")
		}
	}
}
