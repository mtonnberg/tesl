package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

const mcpProtocolVersion = "2024-11-05"

type server struct {
	compiler tooling.Client
}

type callParams struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments"`
}

type jsonRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

func main() {
	compiler, err := discoverCompiler()
	if err != nil {
		fmt.Fprintln(os.Stderr, "tesl-mcp:", err)
		os.Exit(1)
	}
	server := &server{compiler: tooling.Client{Executable: compiler}}
	reader := protocol.NewReader(os.Stdin)
	writer := protocol.NewWriter(os.Stdout)
	for {
		payload, err := reader.Read()
		if errors.Is(err, io.EOF) {
			return
		}
		if err != nil {
			_ = writeError(writer, nil, -32700, err.Error())
			continue
		}
		var request jsonRPCRequest
		if err := json.Unmarshal(payload, &request); err != nil || request.JSONRPC != "2.0" || request.Method == "" {
			_ = writeError(writer, nil, -32600, "invalid request")
			continue
		}
		if len(request.ID) == 0 {
			continue
		}
		result, err := server.handle(context.Background(), request.Method, request.Params)
		if err != nil {
			code := -32603
			if strings.HasPrefix(err.Error(), "unknown method:") {
				code = -32601
			}
			_ = writeError(writer, request.ID, code, err.Error())
			continue
		}
		_ = writer.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(request.ID), "result": result})
	}
}

func (server *server) handle(ctx context.Context, method string, raw json.RawMessage) (any, error) {
	switch method {
	case "initialize":
		return map[string]any{
			"protocolVersion": mcpProtocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]string{"name": "tesl-mcp", "version": "0.3.1"},
		}, nil
	case "ping":
		return map[string]any{}, nil
	case "shutdown":
		return nil, nil
	case "tools/list":
		return map[string]any{"tools": toolDefinitions()}, nil
	case "tools/call":
		var params callParams
		if err := json.Unmarshal(raw, &params); err != nil || params.Name == "" {
			return toolError("tools/call: invalid params"), nil
		}
		value, err := server.callTool(ctx, params.Name, params.Arguments)
		if err != nil {
			return map[string]any{"isError": true, "content": []map[string]string{{"type": "text", "text": err.Error()}}}, nil
		}
		return map[string]any{"isError": false, "content": []map[string]string{{"type": "text", "text": string(value)}}}, nil
	default:
		return nil, fmt.Errorf("unknown method: %s", method)
	}
}

func (server *server) callTool(ctx context.Context, name string, arguments map[string]any) ([]byte, error) {
	file, _ := arguments["file"].(string)
	line, col := numberArgument(arguments, "line"), numberArgument(arguments, "col")
	if isSourceQueryTool(name) {
		if file == "" {
			return nil, errors.New("file is required")
		}
		if !numberArgumentPresent(arguments, "line") || !numberArgumentPresent(arguments, "col") || line < 0 || col < 0 {
			return nil, errors.New("line and col must be non-negative integers")
		}
	}
	var args []string
	switch name {
	case "tesl.agent_context", "tesl.proof_obligations":
		if file == "" {
			return nil, errors.New("file is required")
		}
		args = []string{"--agent-context-json", file}
	case "tesl.check":
		if file == "" {
			return nil, errors.New("file is required")
		}
		args = []string{"--check-json", file}
	case "tesl.type_at":
		args = sourceQueryArgs("--type-at-json", file, line, col)
	case "tesl.signature":
		args = sourceQueryArgs("--signature-help-json", file, line, col)
	case "tesl.completions":
		args = sourceQueryArgs("--completions-json", file, line, col)
	case "tesl.definition":
		args = sourceQueryArgs("--definition-json", file, line, col)
	case "tesl.references":
		args = sourceQueryArgs("--occurrences-json", file, line, col)
	case "tesl.debug_inspect":
		if file == "" {
			return nil, errors.New("file is required")
		}
		if command := debugInspectCommand(); command != "" {
			inspectArgs := append([]string{"--file", file}, debugInspectArgs(arguments)...)
			result, err := (tooling.Client{Executable: command}).Run(ctx, inspectArgs...)
			if err != nil && len(result.Stdout) == 0 {
				return nil, err
			}
			return result.Stdout, nil
		}
		args = append([]string{"debug-inspect", file}, debugInspectArgs(arguments)...)
	case "tesl.debug_attach":
		return server.debugAttach(ctx, arguments)
	default:
		return nil, fmt.Errorf("unknown tool: %s", name)
	}
	payload, result, err := server.compiler.QueryJSON(ctx, args...)
	if err != nil {
		if len(result.Stdout) > 0 {
			return result.Stdout, nil
		}
		return nil, err
	}
	if name == "tesl.proof_obligations" {
		var envelope struct {
			Proof []json.RawMessage `json:"proof_obligations"`
		}
		if err := json.Unmarshal(payload, &envelope); err != nil {
			return nil, err
		}
		return json.Marshal(envelope.Proof)
	}
	return payload, nil
}

func (server *server) debugAttach(ctx context.Context, arguments map[string]any) ([]byte, error) {
	command := os.Getenv("TESL_DEBUG_ATTACH")
	if command == "" {
		command = "tesl-debug-attach"
	}
	if _, err := exec.LookPath(command); err != nil {
		return nil, fmt.Errorf("debug attach command unavailable: %w", err)
	}
	args := []string{"--operation", stringArgument(arguments, "action", "snapshot")}
	if project := stringArgument(arguments, "project", ""); project != "" {
		args = append(args, "--project", project)
	}
	for _, value := range stringSlice(arguments["break_at"]) {
		args = append(args, "--break-at", value)
	}
	if when := stringArgument(arguments, "when", ""); when != "" {
		args = append(args, "--when", when)
	}
	if hit := stringArgument(arguments, "hit", ""); hit != "" {
		args = append(args, "--hit", hit)
	}
	if timeout := numberArgument(arguments, "timeout_ms"); timeout > 0 {
		args = append(args, "--timeout-ms", strconv.Itoa(timeout))
	}
	result, err := (tooling.Client{Executable: command}).Run(ctx, args...)
	if err != nil && len(result.Stdout) == 0 {
		return nil, err
	}
	return result.Stdout, nil
}

func sourceQueryArgs(flag, file string, line, col int) []string {
	return []string{flag, file, strconv.Itoa(line), strconv.Itoa(col)}
}

func debugInspectArgs(arguments map[string]any) []string {
	args := []string{"--mode", stringArgument(arguments, "mode", "program")}
	for _, value := range stringSlice(arguments["break_at"]) {
		args = append(args, "--break-at", value)
	}
	items, _ := arguments["breakpoints"].([]any)
	for _, value := range items {
		if object, ok := value.(map[string]any); ok {
			line := numberArgument(object, "line")
			spec := strconv.Itoa(line)
			if condition := stringArgument(object, "condition", ""); condition != "" {
				spec += ": " + condition
			} else if hit := stringArgument(object, "hit", ""); hit != "" {
				spec += ": " + hit
			}
			args = append(args, "--break-at", spec)
		}
	}
	if enabled, ok := arguments["continue"].(bool); ok && enabled {
		args = append(args, "--continue")
	}
	return args
}

func debugInspectCommand() string {
	if command := os.Getenv("TESL_DEBUG_INSPECT_BIN"); command != "" {
		return command
	}
	command, err := exec.LookPath("tesl-debug-inspect")
	if err != nil {
		return ""
	}
	return command
}

func toolDefinitions() []map[string]any {
	types := map[string]any{"type": "object", "required": []string{"file"}, "properties": map[string]any{"file": map[string]string{"type": "string"}}}
	position := map[string]any{"type": "object", "required": []string{"file", "line", "col"}, "properties": map[string]any{"file": map[string]string{"type": "string"}, "line": map[string]string{"type": "integer"}, "col": map[string]string{"type": "integer"}}}
	debugInspect := map[string]any{
		"type":     "object",
		"required": []string{"file"},
		"properties": map[string]any{
			"file":        map[string]string{"type": "string"},
			"break_at":    map[string]any{"type": "array", "items": map[string]string{"type": "string"}},
			"breakpoints": map[string]any{"type": "array", "items": map[string]any{"type": "object", "required": []string{"line"}, "properties": map[string]any{"line": map[string]string{"type": "integer"}, "condition": map[string]string{"type": "string"}, "hit": map[string]string{"type": "string"}}}},
			"mode":        map[string]any{"type": "string", "enum": []string{"program", "test"}},
			"continue":    map[string]string{"type": "boolean"},
		},
	}
	debugAttach := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"project":    map[string]string{"type": "string"},
			"action":     map[string]any{"type": "string", "enum": []string{"once", "snapshot", "ping", "detach"}},
			"break_at":   map[string]any{"type": "array", "items": map[string]string{"type": "string"}},
			"when":       map[string]string{"type": "string"},
			"hit":        map[string]string{"type": "string"},
			"timeout_ms": map[string]string{"type": "integer"},
		},
	}
	return []map[string]any{
		{"name": "tesl.agent_context", "description": "Compact compiler context after an edit.", "inputSchema": types},
		{"name": "tesl.check", "description": "Compiler diagnostics and fixes.", "inputSchema": types},
		{"name": "tesl.type_at", "description": "Type at a source position.", "inputSchema": position},
		{"name": "tesl.signature", "description": "Call signature help.", "inputSchema": position},
		{"name": "tesl.completions", "description": "Completion candidates.", "inputSchema": position},
		{"name": "tesl.definition", "description": "Same-file definition.", "inputSchema": position},
		{"name": "tesl.references", "description": "Same-file occurrences.", "inputSchema": position},
		{"name": "tesl.proof_obligations", "description": "Unproven compiler obligations.", "inputSchema": types},
		{"name": "tesl.debug_inspect", "description": "Run a debug target to an agent-selected breakpoint.", "inputSchema": debugInspect},
		{"name": "tesl.debug_attach", "description": "Attach to a running debug target.", "inputSchema": debugAttach},
	}
}

func isSourceQueryTool(name string) bool {
	switch name {
	case "tesl.type_at", "tesl.signature", "tesl.completions", "tesl.definition", "tesl.references":
		return true
	default:
		return false
	}
}

func toolError(message string) map[string]any {
	return map[string]any{
		"isError": true,
		"content": []map[string]string{{"type": "text", "text": message}},
	}
}

func discoverCompiler() (string, error) {
	if value := os.Getenv("TESL_COMPILER"); value != "" {
		return value, nil
	}
	if root := os.Getenv("TESL_REPO_ROOT"); root != "" {
		candidate := filepath.Join(root, "compiler", "_build", "default", "bin", "main.exe")
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}
	if value, err := exec.LookPath("tesl-compiler"); err == nil {
		return value, nil
	}
	if value, err := exec.LookPath("tesl"); err == nil {
		return value, nil
	}
	// Keep MCP alive without a compiler. Tool calls return contained MCP errors;
	// initialize/tools/list remain usable for clients inspecting capabilities.
	return "", nil
}

func numberArgument(arguments map[string]any, name string) int {
	value, _ := arguments[name].(float64)
	return int(value)
}

func numberArgumentPresent(arguments map[string]any, name string) bool {
	value, ok := arguments[name].(float64)
	return ok && value == float64(int(value))
}

func stringArgument(arguments map[string]any, name, fallback string) string {
	if value, ok := arguments[name].(string); ok {
		return value
	}
	return fallback
}

func stringSlice(value any) []string {
	values, _ := value.([]any)
	result := make([]string, 0, len(values))
	for _, item := range values {
		if text, ok := item.(string); ok {
			result = append(result, text)
		}
	}
	return result
}

func writeError(writer *protocol.Writer, id json.RawMessage, code int, message string) error {
	return writer.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
}
