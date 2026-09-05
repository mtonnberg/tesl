package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

const compilerHelperScript = `#!/bin/sh
case "$1" in
  --search-json)
    test "$2" = 'String -> Int' || exit 2
    printf '%s' '{"version":1,"catalog_id":"fixture","scope":"builtins","query":"String -> Int","mode":"type","error":null,"total":0,"limit":20,"results":[]}' ;;
  --agent-context-json)
    printf '%s' '{"version":1,"file":"fixture.tesl","content_hash":"abc","ok":true,"summary":"clean","diagnostics":[],"symbols":[],"proof_obligations":[]}' ;;
  --check-json)
    printf '%s' '{"version":1,"diagnostics":[]}' ;;
  --type-at-json)
    printf '%s' '{"version":1,"type_at":null}' ;;
  --signature-help-json)
    printf '%s' '{"version":1,"signature":null}' ;;
  --completions-json)
    printf '%s' '{"version":1,"completions":[]}' ;;
  --definition-json)
    printf '%s' '{"version":1,"definition":null}' ;;
  --occurrences-json)
    printf '%s' '{"version":1,"occurrences":[]}' ;;
  *)
    printf '%s' '{"version":1}' ;;
esac
`

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
	if err := os.WriteFile(script, []byte(compilerHelperScript), 0o700); err != nil {
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

func TestMCPCompilerToolRejectsMalformedAgentContextMember(t *testing.T) {
	script := filepath.Join(t.TempDir(), "compiler-helper.sh")
	payload := `{"version":1,"file":"fixture.tesl","content_hash":"abc","ok":true,"summary":"clean","diagnostics":[],"symbols":[{"name":"broken","kind":"fn"}],"proof_obligations":[]}`
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' '"+payload+"'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	server := &server{compiler: tooling.Client{Executable: script}}
	if _, err := server.callTool(context.Background(), "tesl.agent_context", map[string]any{"file": "fixture.tesl"}); err == nil || !strings.Contains(err.Error(), "signature") {
		t.Fatalf("malformed agent-context member error = %v", err)
	}
}

func TestMCPCompilerToolRejectsMalformedNestedDiagnosticFix(t *testing.T) {
	script := filepath.Join(t.TempDir(), "compiler-helper.sh")
	payload := `{"version":1,"diagnostics":[{"file":"fixture.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":{"kind":"multi","title":"Fix all","edits":[{"kind":"replace_line","line":0}]},"source":"parser"}]}`
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' '"+payload+"'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	server := &server{compiler: tooling.Client{Executable: script}}
	if _, err := server.callTool(context.Background(), "tesl.check", map[string]any{"file": "fixture.tesl"}); err == nil || !strings.Contains(err.Error(), "replacement") {
		t.Fatalf("malformed diagnostic fix error = %v", err)
	}
}

func TestMCPCompilerToolsDispatchWithRequiredArguments(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "compiler-helper.sh")
	if err := os.WriteFile(script, []byte(compilerHelperScript), 0o700); err != nil {
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
	timeout, err := debugTimeout(map[string]any{"timeout_ms": float64(5000)})
	if err != nil || timeout != 5*time.Second {
		t.Fatalf("debug timeout = %s, %v", timeout, err)
	}
	if args := strings.Join(debugInspectArgs(nil, timeout), " "); !strings.Contains(args, "--timeout-ms 5000") {
		t.Fatalf("debug inspect args = %s", args)
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

func TestMCPDebugAttachDefaultsAndProjectDiscovery(t *testing.T) {
	project := t.TempDir()
	nested := filepath.Join(project, "src", "nested")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(project, "tesl.toml"), []byte("[project]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := nearestProject(nested)
	if err != nil {
		t.Fatal(err)
	}
	if got != project {
		t.Fatalf("nearestProject() = %q, want %q", got, project)
	}
	if timeout := debugAttachProcessTimeout(30 * time.Second); timeout != 30*time.Second+debugProcessMargin {
		t.Fatalf("debug process timeout = %s", timeout)
	}
	if _, err := (&server{}).debugAttach(context.Background(), map[string]any{"project": project}); err == nil || !strings.Contains(err.Error(), "requires at least one break_at") {
		t.Fatalf("default action error = %v", err)
	}
}

func TestMCPDebugAttachSchemaRequiresBreakpointsForDefaultOnce(t *testing.T) {
	var schema map[string]any
	for _, tool := range toolDefinitions() {
		if tool["name"] == "tesl.debug_attach" {
			schema, _ = tool["inputSchema"].(map[string]any)
			break
		}
	}
	if schema == nil || schema["allOf"] == nil {
		t.Fatalf("debug_attach schema does not constrain default once action: %#v", schema)
	}
	properties, _ := schema["properties"].(map[string]any)
	action, _ := properties["action"].(map[string]any)
	if action["default"] != "once" {
		t.Fatalf("action default = %#v", action["default"])
	}
	timeout, _ := properties["timeout_ms"].(map[string]any)
	if timeout["default"] != 30000 {
		t.Fatalf("timeout default = %#v", timeout["default"])
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

func TestMCPStdioRawConformance(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "compiler-helper.sh")
	if err := os.WriteFile(script, []byte(compilerHelperScript), 0o700); err != nil {
		t.Fatal(err)
	}
	if len(os.Args) == 0 {
		t.Fatal("test executable path unavailable")
	}
	command := exec.Command(os.Args[0], "-test.run=TestMCPStdioHelper")
	command.Env = append(os.Environ(), "TESL_MCP_STDIO_HELPER=1", "TESL_COMPILER="+script)
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if input == nil {
		t.Fatal("MCP helper stdin pipe is nil")
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	// This probe deliberately does not use the production protocol package: raw
	// MCP 2024-11-05 clients write and read one JSON object per line.
	if _, err := input.Write([]byte("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n")); err != nil {
		t.Fatal(err)
	}
	if _, err := input.Write([]byte("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n")); err != nil {
		t.Fatal(err)
	}
	if err := input.Close(); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(output)
	if !scanner.Scan() {
		t.Fatalf("missing initialize response: %v", scanner.Err())
	}
	first := scanner.Text()
	if !scanner.Scan() {
		t.Fatalf("missing tools/list response: %v", scanner.Err())
	}
	second := scanner.Text()
	if strings.HasPrefix(first, "Content-Length:") || !strings.Contains(first, `"protocolVersion":"2024-11-05"`) {
		t.Fatalf("initialize response = %s", first)
	}
	if !strings.Contains(second, `"tesl.agent_context"`) {
		t.Fatalf("tools/list response missing agent context: %s", second)
	}
	if err := command.Wait(); err != nil {
		t.Fatal(err)
	}
}

func TestMCPStdioTerminatesOnTruncatedLine(t *testing.T) {
	script := filepath.Join(t.TempDir(), "compiler-helper.sh")
	if err := os.WriteFile(script, []byte(compilerHelperScript), 0o700); err != nil {
		t.Fatal(err)
	}
	if len(os.Args) == 0 {
		t.Fatal("test executable path unavailable")
		return
	}
	command := exec.Command(os.Args[0], "-test.run=TestMCPStdioHelper")
	command.Env = append(os.Environ(), "TESL_MCP_STDIO_HELPER=1", "TESL_COMPILER="+script)
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
		return
	}
	if input == nil {
		t.Fatal("MCP helper stdin pipe is nil")
		return
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	if _, err := input.Write([]byte(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`)); err != nil {
		t.Fatal(err)
	}
	if err := input.Close(); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(output)
	if !scanner.Scan() || !strings.Contains(scanner.Text(), `"code":-32700`) {
		t.Fatalf("truncated-line response = %q, error = %v", scanner.Text(), scanner.Err())
	}
	for scanner.Scan() {
		if strings.HasPrefix(scanner.Text(), "{") {
			t.Fatalf("server continued after truncated line: %s", scanner.Text())
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if err := command.Wait(); err != nil {
		t.Fatal(err)
	}
}

func TestMCPStdioCompilerToolMatrix(t *testing.T) {
	directory := t.TempDir()
	script := filepath.Join(directory, "compiler-helper.sh")
	if err := os.WriteFile(script, []byte(compilerHelperScript), 0o700); err != nil {
		t.Fatal(err)
	}
	if len(os.Args) == 0 {
		t.Fatal("test executable path unavailable")
	}
	command := exec.Command(os.Args[0], "-test.run=TestMCPStdioHelper")
	command.Env = append(os.Environ(), "TESL_MCP_STDIO_HELPER=1", "TESL_COMPILER="+script)
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if input == nil {
		t.Fatal("MCP helper stdin pipe is nil")
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	writer := protocol.NewLineWriter(input)
	reader := protocol.NewLineReader(output)
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
	inspectBin := filepath.Join(t.TempDir(), "tesl-debug-inspect")
	inspectBuild := exec.Command("go", "build", "-o", inspectBin, "./cmd/tesl-debug-inspect")
	inspectBuild.Dir = filepath.Join(root, "runtime", "go")
	if output, err := inspectBuild.CombinedOutput(); err != nil {
		t.Fatalf("build current debug inspect launcher: %v\n%s", err, output)
	}
	lesson := filepath.Join(root, "example", "learn", "lesson61-step-debugging.tesl")
	if len(os.Args) == 0 {
		t.Fatal("test executable path unavailable")
	}
	command := exec.Command(os.Args[0], "-test.run=TestMCPStdioHelper")
	command.Env = append(os.Environ(),
		"TESL_MCP_STDIO_HELPER=1",
		"TESL_COMPILER="+compiler,
		"TESL_DEBUG_INSPECT_BIN="+inspectBin,
		"TESL_REPO_ROOT="+root,
	)
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if input == nil {
		t.Fatal("MCP helper stdin pipe is nil")
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	writer := protocol.NewLineWriter(input)
	reader := protocol.NewLineReader(output)
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
	if racketInput == nil {
		t.Fatal("Racket MCP stdin pipe is nil")
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
	compilerTools := []struct {
		name string
		args map[string]any
	}{
		{name: "tesl.check", args: map[string]any{"file": lesson}},
		{name: "tesl.type_at", args: map[string]any{"file": lesson, "line": float64(35), "col": float64(2)}},
		{name: "tesl.signature", args: map[string]any{"file": lesson, "line": float64(35), "col": float64(2)}},
		{name: "tesl.completions", args: map[string]any{"file": lesson, "line": float64(35), "col": float64(2)}},
		{name: "tesl.definition", args: map[string]any{"file": lesson, "line": float64(35), "col": float64(2)}},
		{name: "tesl.references", args: map[string]any{"file": lesson, "line": float64(35), "col": float64(2)}},
		{name: "tesl.proof_obligations", args: map[string]any{"file": lesson}},
	}
	goServer := &server{compiler: tooling.Client{Executable: compiler}}
	for index, tool := range compilerTools {
		racketResponse := racketRequest(index+3, "tools/call", map[string]any{
			"name": tool.name, "arguments": tool.args,
		})
		racketText := toolResultText(t, racketResponse)
		goText, err := goServer.callTool(context.Background(), tool.name, tool.args)
		if err != nil {
			t.Fatalf("Go %s: %v", tool.name, err)
		}
		if string(goText) != racketText {
			t.Fatalf("%s differential:\nGo:     %s\nRacket: %s", tool.name, goText, racketText)
		}
	}
	if err := racketInput.Close(); err != nil {
		t.Fatal(err)
	}
	if err := racketCommand.Wait(); err != nil {
		t.Fatal(err)
	}

	// The frozen Racket implementation predates builtin search. Keep comparing
	// every legacy tool exactly; the new Go-only tool has its own compiler test.
	var legacyTools []map[string]any
	for _, tool := range toolDefinitions() {
		if tool["name"] != "tesl.search" {
			legacyTools = append(legacyTools, tool)
		}
	}
	goTools, err := json.Marshal(map[string]any{"tools": legacyTools})
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

	goContext, err := goServer.callTool(
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
		// The Go debugger schemas carry timeout/default constraints that the
		// legacy Racket compatibility server does not model. Compiler-query tool
		// shapes remain a useful differential oracle; debugger schemas do not.
		if name == "tesl.debug_inspect" || name == "tesl.debug_attach" {
			continue
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
