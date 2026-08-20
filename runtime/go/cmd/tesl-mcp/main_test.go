package main

import (
	"context"
	"encoding/json"
	"fmt"
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
	if !strings.Contains(string(encoded), `"name":"tesl-mcp"`) ||
		!strings.Contains(string(encoded), `"version":"0.3.1"`) {
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

func TestMCPCompilerToolsDispatchWithRequiredArguments(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "compiler-helper.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' '{} '\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	server := &server{compiler: tooling.Client{Executable: script}}
	position := map[string]any{"file": "fixture.tesl", "line": float64(0), "col": float64(0)}
	for _, name := range []string{
		"tesl.agent_context", "tesl.check", "tesl.type_at", "tesl.signature",
		"tesl.completions", "tesl.definition", "tesl.references", "tesl.proof_obligations",
	} {
		arguments := map[string]any{"file": "fixture.tesl"}
		if isSourceQueryTool(name) {
			arguments = position
		}
		if value, err := server.callTool(context.Background(), name, arguments); err != nil {
			t.Fatalf("%s: %v", name, err)
		} else if value == nil {
			t.Fatalf("%s returned no payload", name)
		}
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

func TestMCPDebugAttachForwardsSessionArguments(t *testing.T) {
	directory := t.TempDir()
	argumentsFile := filepath.Join(directory, "arguments")
	script := filepath.Join(directory, "debug-attach-helper.sh")
	contents := "#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + argumentsFile + "'\nprintf '%s' '{\"version\":2,\"stopped\":false}'\n"
	if err := os.WriteFile(script, []byte(contents), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TESL_DEBUG_ATTACH", script)
	server := &server{}
	value, err := server.callTool(context.Background(), "tesl.debug_attach", map[string]any{
		"action":     "once",
		"project":    "/tmp/project",
		"break_at":   []any{"42", "44"},
		"when":       "n == 2",
		"hit":        ">=3",
		"timeout_ms": float64(5000),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(value), `"version":2`) {
		t.Fatalf("attach result = %s", value)
	}
	arguments, err := os.ReadFile(argumentsFile)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"--operation\nonce", "--project\n/tmp/project", "--break-at\n42", "--break-at\n44", "--when\nn == 2", "--hit\n>=3", "--timeout-ms\n5000"} {
		if !strings.Contains(string(arguments), expected) {
			t.Fatalf("attach args missing %q: %s", expected, arguments)
		}
	}
}

func TestMCPUnknownMethodIsProtocolError(t *testing.T) {
	if _, err := (&server{}).handle(context.Background(), "unknown/method", nil); err == nil || !strings.Contains(err.Error(), "unknown method") {
		t.Fatalf("unknown method error = %v", err)
	}
}

func TestMCPCompilerDiscoveryDoesNotBlockCapabilityQueries(t *testing.T) {
	t.Setenv("TESL_COMPILER", "")
	t.Setenv("TESL_REPO_ROOT", t.TempDir())
	t.Setenv("PATH", t.TempDir())
	compiler, err := discoverCompiler()
	if err != nil {
		t.Fatal(err)
	}
	if compiler != "" {
		t.Fatalf("compiler discovery = %q", compiler)
	}
}

func TestMCPShutdownAndSourceQueryValidation(t *testing.T) {
	server := &server{}
	result, err := server.handle(context.Background(), "shutdown", nil)
	if err != nil || result != nil {
		t.Fatalf("shutdown = %#v, %v", result, err)
	}
	value, err := server.callTool(context.Background(), "tesl.type_at", map[string]any{"file": "fixture.tesl"})
	if err == nil || value != nil || !strings.Contains(err.Error(), "line and col") {
		t.Fatalf("missing source position = %q, %v", value, err)
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

func TestMCPStdioCompilerToolMatrix(t *testing.T) {
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
	reader := protocol.NewReader(output)
	requests := []map[string]any{
		{"jsonrpc": "2.0", "id": 1, "method": "initialize"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": map[string]any{"name": "tesl.agent_context", "arguments": map[string]any{"file": "fixture.tesl"}}},
		{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": map[string]any{"name": "tesl.check", "arguments": map[string]any{"file": "fixture.tesl"}}},
		{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": map[string]any{"name": "tesl.type_at", "arguments": map[string]any{"file": "fixture.tesl", "line": 0, "col": 0}}},
		{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": map[string]any{"name": "tesl.signature", "arguments": map[string]any{"file": "fixture.tesl", "line": 0, "col": 0}}},
		{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": map[string]any{"name": "tesl.completions", "arguments": map[string]any{"file": "fixture.tesl", "line": 0, "col": 0}}},
		{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": map[string]any{"name": "tesl.definition", "arguments": map[string]any{"file": "fixture.tesl", "line": 0, "col": 0}}},
		{"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": map[string]any{"name": "tesl.references", "arguments": map[string]any{"file": "fixture.tesl", "line": 0, "col": 0}}},
		{"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": map[string]any{"name": "tesl.proof_obligations", "arguments": map[string]any{"file": "fixture.tesl"}}},
		{"jsonrpc": "2.0", "id": 10, "method": "shutdown"},
	}
	for _, request := range requests {
		if err := writer.WriteJSON(request); err != nil {
			t.Fatal(err)
		}
		payload, err := reader.Read()
		if err != nil {
			t.Fatal(err)
		}
		var response map[string]any
		if err := json.Unmarshal(payload, &response); err != nil {
			t.Fatal(err)
		}
		if response["error"] != nil {
			t.Fatalf("request %v response = %s", request["id"], payload)
		}
	}
	if err := input.Close(); err != nil {
		t.Fatal(err)
	}
	if err := command.Wait(); err != nil {
		t.Fatal(err)
	}
}

func TestMCPStdioRealCompilerAndHeadlessDebugger(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	compiler := os.Getenv("TESL_COMPILER")
	if compiler == "" {
		compiler = filepath.Join(root, "compiler", "_build", "default", "bin", "main.exe")
	}
	if _, err := os.Stat(compiler); err != nil {
		t.Skipf("built compiler unavailable: %v", err)
	}
	lesson := filepath.Join(root, "example", "learn", "lesson61-step-debugging.tesl")
	command := exec.Command(os.Args[0], "-test.run=TestMCPStdioHelper")
	command.Env = append(os.Environ(),
		"TESL_MCP_STDIO_HELPER=1",
		"TESL_COMPILER="+compiler,
		"TESL_REPO_ROOT="+root,
	)
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
	reader := protocol.NewReader(output)
	request := func(id int, method string, params map[string]any) map[string]any {
		t.Helper()
		if err := writer.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}); err != nil {
			t.Fatal(err)
		}
		payload, err := reader.Read()
		if err != nil {
			t.Fatal(err)
		}
		var response map[string]any
		if err := json.Unmarshal(payload, &response); err != nil {
			t.Fatal(err)
		}
		if response["error"] != nil {
			t.Fatalf("%s response = %s", method, payload)
		}
		return response
	}
	request(1, "initialize", nil)
	tools := request(2, "tools/list", nil)
	toolsJSON, err := json.Marshal(tools["result"])
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"tesl.agent_context", "tesl.debug_inspect", "tesl.debug_attach"} {
		if !strings.Contains(string(toolsJSON), name) {
			t.Fatalf("real tools/list missing %s: %s", name, toolsJSON)
		}
	}
	contextResponse := request(3, "tools/call", map[string]any{
		"name":      "tesl.agent_context",
		"arguments": map[string]any{"file": lesson},
	})
	contextText := toolResultText(t, contextResponse)
	if !strings.Contains(contextText, `"ok":true`) {
		t.Fatalf("real agent context is not successful: %s", contextText)
	}
	inspectResponse := request(4, "tools/call", map[string]any{
		"name": "tesl.debug_inspect",
		"arguments": map[string]any{
			"file": lesson, "mode": "test", "break_at": []string{"193"},
		},
	})
	inspectText := toolResultText(t, inspectResponse)
	if !strings.Contains(inspectText, `"stopped":true`) {
		t.Fatalf("real debug inspect did not stop: %s", inspectText)
	}
	request(5, "shutdown", nil)
	if err := input.Close(); err != nil {
		t.Fatal(err)
	}
	if err := command.Wait(); err != nil {
		t.Fatal(err)
	}
}

func toolResultText(t *testing.T, response map[string]any) string {
	t.Helper()
	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatalf("tool response has no result object: %#v", response)
	}
	content, ok := result["content"].([]any)
	if !ok || len(content) == 0 {
		t.Fatalf("tool response has no content: %#v", response)
	}
	first, ok := content[0].(map[string]any)
	if !ok {
		t.Fatalf("tool response content is not an object: %#v", content[0])
	}
	text, ok := first["text"].(string)
	if !ok {
		t.Fatalf("tool response content has no text: %#v", first)
	}
	return text
}

func TestMCPRacketCatalogAndCompilerDifferential(t *testing.T) {
	racket, err := exec.LookPath("racket")
	if err != nil {
		t.Skipf("Racket compatibility oracle unavailable: %v", err)
	}
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	compiler := os.Getenv("TESL_COMPILER")
	if compiler == "" {
		compiler = filepath.Join(root, "compiler", "_build", "default", "bin", "main.exe")
	}
	if _, err := os.Stat(compiler); err != nil {
		t.Skipf("built compiler unavailable: %v", err)
	}
	racketCommand := exec.Command(racket, filepath.Join(root, "editor", "tesl-mcp", "tesl-mcp.rkt"))
	racketCommand.Env = append(os.Environ(), "TESL_REPO_ROOT="+root, "TESL_COMPILER="+compiler)
	racketInput, err := racketCommand.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	racketOutput, err := racketCommand.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := racketCommand.Start(); err != nil {
		t.Fatal(err)
	}
	racketWriter := protocol.NewWriter(racketInput)
	racketReader := protocol.NewReader(racketOutput)
	racketRequest := func(id int, method string, params map[string]any) map[string]any {
		t.Helper()
		if err := racketWriter.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}); err != nil {
			t.Fatal(err)
		}
		payload, err := racketReader.Read()
		if err != nil {
			t.Fatal(err)
		}
		var response map[string]any
		if err := json.Unmarshal(payload, &response); err != nil {
			t.Fatal(err)
		}
		if response["error"] != nil {
			t.Fatalf("Racket %s response = %s", method, payload)
		}
		return response
	}
	racketTools := racketRequest(1, "tools/list", nil)
	lesson := filepath.Join(root, "example", "learn", "lesson01-basic-types-and-functions.tesl")
	racketContext := racketRequest(2, "tools/call", map[string]any{
		"name": "tesl.agent_context", "arguments": map[string]any{"file": lesson},
	})
	if err := racketInput.Close(); err != nil {
		t.Fatal(err)
	}
	if err := racketCommand.Wait(); err != nil {
		t.Fatal(err)
	}

	goTools, err := json.Marshal(map[string]any{"tools": toolDefinitions()})
	if err != nil {
		t.Fatal(err)
	}
	var goCatalog map[string]any
	if err := json.Unmarshal(goTools, &goCatalog); err != nil {
		t.Fatal(err)
	}
	if err := compareToolCatalog(t, goCatalog, racketTools); err != nil {
		t.Fatal(err)
	}

	goContext, err := (&server{compiler: tooling.Client{Executable: compiler}}).callTool(
		context.Background(), "tesl.agent_context", map[string]any{"file": lesson})
	if err != nil {
		t.Fatal(err)
	}
	if racketText := toolResultText(t, racketContext); string(goContext) != racketText {
		t.Fatalf("agent_context differential:\nGo:     %s\nRacket: %s", goContext, racketText)
	}
}

func compareToolCatalog(t *testing.T, goCatalog, racketResponse map[string]any) error {
	goTools, ok := goCatalog["tools"].([]any)
	if !ok {
		return fmt.Errorf("Go catalog has no tools array")
	}
	racketResult, ok := racketResponse["result"].(map[string]any)
	if !ok {
		return fmt.Errorf("Racket catalog has no result object")
	}
	racketTools, ok := racketResult["tools"].([]any)
	if !ok {
		return fmt.Errorf("Racket catalog has no tools array")
	}
	if len(goTools) != len(racketTools) {
		return fmt.Errorf("tool count differs: Go=%d Racket=%d", len(goTools), len(racketTools))
	}
	goByName := make(map[string]map[string]any, len(goTools))
	racketByName := make(map[string]map[string]any, len(racketTools))
	for _, raw := range goTools {
		tool, ok := raw.(map[string]any)
		if !ok {
			return fmt.Errorf("Go tool is not an object: %#v", raw)
		}
		name, _ := tool["name"].(string)
		goByName[name] = tool
	}
	for _, raw := range racketTools {
		tool, ok := raw.(map[string]any)
		if !ok {
			return fmt.Errorf("Racket tool is not an object: %#v", raw)
		}
		name, _ := tool["name"].(string)
		racketByName[name] = tool
	}
	for name, goTool := range goByName {
		racketTool, ok := racketByName[name]
		if !ok {
			return fmt.Errorf("Racket catalog missing %s", name)
		}
		goShape, err := schemaShape(goTool)
		if err != nil {
			return fmt.Errorf("Go %s: %w", name, err)
		}
		racketShape, err := schemaShape(racketTool)
		if err != nil {
			return fmt.Errorf("Racket %s: %w", name, err)
		}
		if string(goShape) != string(racketShape) {
			return fmt.Errorf("schema differs for %s: Go=%s Racket=%s", name, goShape, racketShape)
		}
	}
	return nil
}

func schemaShape(tool map[string]any) ([]byte, error) {
	schema, ok := tool["inputSchema"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("missing inputSchema")
	}
	properties, ok := schema["properties"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("missing schema properties")
	}
	types := make(map[string]string, len(properties))
	for name, raw := range properties {
		property, ok := raw.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("property %s is not an object", name)
		}
		typeName, _ := property["type"].(string)
		types[name] = typeName
	}
	return json.Marshal(map[string]any{"required": schema["required"], "types": types})
}
