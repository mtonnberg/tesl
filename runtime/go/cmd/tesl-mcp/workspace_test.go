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

func TestMCPWorkspaceNavigationAndCheckedRename(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	compiler := filepath.Join(root, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("build compiler for workspace MCP integration")
	}
	project := t.TempDir()
	path := filepath.Join(project, "main.tesl")
	main := "module Main exposing [run]\nimport Tesl.Prelude exposing [Int]\nimport Lib exposing [double]\nfn run(n: Int) -> Int = double n\n"
	lib := "module Lib exposing [double]\nimport Tesl.Prelude exposing [Int]\nfn double(n: Int) -> Int = n * 2\n"
	for name, text := range map[string]string{"tesl.toml": "[project]\nname=\"test\"\n", "main.tesl": main, "lib.tesl": lib} {
		if err := os.WriteFile(filepath.Join(project, name), []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	server := server{compiler: tooling.Client{Executable: compiler, Sessions: tooling.NewWorkspaceSessions(), Environment: append(os.Environ(), "TESL_REPO_ROOT="+root)}}
	defer func() { _ = server.compiler.Close() }()
	args := map[string]any{"file": path, "line": float64(3), "col": float64(24)}
	var current tooling.WorkspaceResponse
	for _, name := range []string{"tesl.workspace_definition", "tesl.workspace_references"} {
		payload, err := server.callTool(context.Background(), name, args)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(payload, &current); err != nil {
			t.Fatal(err)
		}
		if !current.Complete || current.Symbol == nil || current.Symbol.Definition.File != filepath.Join(project, "lib.tesl") || len(current.References) != 4 {
			t.Fatalf("workspace tool %s = %s", name, payload)
		}
	}
	args["new_name"] = "twice"
	args["expected_snapshot"] = current.Snapshot
	payload, err := server.callTool(context.Background(), "tesl.workspace_rename", args)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(payload, &current); err != nil {
		t.Fatal(err)
	}
	if current.Rename == nil || !current.Rename.Safe || len(current.Rename.Files) != 2 {
		t.Fatalf("rename proposal = %s", payload)
	}
	if err := os.WriteFile(filepath.Join(project, "lib.tesl"), []byte(strings.ReplaceAll(lib, "n * 2", "n * 3")), 0600); err != nil {
		t.Fatal(err)
	}
	payload, err = server.callTool(context.Background(), "tesl.workspace_rename", args)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(payload, &current); err != nil {
		t.Fatal(err)
	}
	if current.Rename == nil || current.Rename.Safe || len(current.Rename.Files) != 0 {
		t.Fatalf("stale proposal accepted: %s", payload)
	}
	for _, name := range []string{"tesl.workspace_definition", "tesl.workspace_references", "tesl.workspace_rename"} {
		found := false
		for _, tool := range toolDefinitions() {
			if tool["name"] == name {
				found = true
			}
		}
		if !found {
			t.Fatalf("missing discoverable tool %s", name)
		}
	}
}

func TestMCPWorkspaceRenameRequiresExplicitPrecondition(t *testing.T) {
	server := server{}
	for _, args := range []map[string]any{
		{"file": "main.tesl", "line": float64(0), "col": float64(0), "new_name": "changed"},
		{"file": "main.tesl", "line": float64(0), "col": float64(0), "expected_snapshot": "revision"},
	} {
		if _, err := server.callTool(context.Background(), "tesl.workspace_rename", args); err == nil || !strings.Contains(err.Error(), "expected_snapshot") {
			t.Fatalf("missing precondition accepted: %v", err)
		}
	}
}
