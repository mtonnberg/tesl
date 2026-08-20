package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

func TestMCPStdioHelper(t *testing.T) {
	if os.Getenv("TESL_MCP_STDIO_HELPER") != "1" {
		return
	}
	main()
}

func TestMCPInitializeAndToolCatalog(t *testing.T) {
	server := &server{}
	result, err := server.handle(context.Background(), "initialize", nil)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(result)
	if !strings.Contains(string(encoded), `"name":"tesl-mcp"`) {
		t.Fatalf("initialize = %s", encoded)
	}
	result, err = server.handle(context.Background(), "tools/list", nil)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ = json.Marshal(result)
	for _, name := range []string{"tesl.agent_context", "tesl.check", "tesl.debug_inspect", "tesl.debug_attach"} {
		if !strings.Contains(string(encoded), name) {
			t.Fatalf("tools/list missing %s: %s", name, encoded)
		}
	}
}

func TestMCPCompilerToolWrapsCompactJSON(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "compiler-helper.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' '{\"version\":1,\"ok\":true,\"diagnostics\":[],\"symbols\":[],\"proof_obligations\":[]}'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	server := &server{compiler: tooling.Client{Executable: script}}
	value, err := server.callTool(context.Background(), "tesl.agent_context", map[string]any{"file": "fixture.tesl"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(value), `"ok":true`) {
		t.Fatalf("agent context = %s", value)
	}
}

func TestMCPDebugInspectUsesGoLauncher(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "debug-inspect-helper.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' '{\"version\":2,\"stopped\":true}'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TESL_DEBUG_INSPECT_BIN", script)
	server := &server{compiler: tooling.Client{Executable: script}}
	value, err := server.callTool(context.Background(), "tesl.debug_inspect", map[string]any{
		"file":     "fixture.tesl",
		"break_at": []any{"42"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(value), `"stopped":true`) {
		t.Fatalf("debug inspect = %s", value)
	}
}

func TestMCPUnknownMethodIsProtocolError(t *testing.T) {
	if _, err := (&server{}).handle(context.Background(), "unknown/method", nil); err == nil || !strings.Contains(err.Error(), "unknown method") {
		t.Fatalf("unknown method error = %v", err)
	}
}

func TestMCPStdioProtocol(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "compiler-helper.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' '{\"version\":1,\"ok\":true,\"diagnostics\":[],\"symbols\":[],\"proof_obligations\":[]}'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(os.Args[0], "-test.run=TestMCPStdioHelper")
	command.Env = append(os.Environ(), "TESL_MCP_STDIO_HELPER=1", "TESL_COMPILER="+script)
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	writer := protocol.NewWriter(input)
	if err := writer.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize"}); err != nil {
		t.Fatal(err)
	}
	if err := writer.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}); err != nil {
		t.Fatal(err)
	}
	if err := input.Close(); err != nil {
		t.Fatal(err)
	}
	reader := protocol.NewReader(output)
	first, err := reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	second, err := reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(first), `"protocolVersion":"2024-11-05"`) {
		t.Fatalf("initialize response = %s", first)
	}
	if !strings.Contains(string(second), `"tesl.agent_context"`) {
		t.Fatalf("tools/list response missing agent context: %s", second)
	}
	if err := command.Wait(); err != nil {
		t.Fatal(err)
	}
}
