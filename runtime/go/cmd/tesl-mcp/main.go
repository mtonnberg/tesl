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
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/toolchain"
	"tesl.dev/runtime/go/internal/tooling"
)

const mcpProtocolVersion = "2024-11-05"

const (
	defaultDebugAttachTimeout = 30 * time.Second
	debugProcessMargin        = 2 * time.Second
)

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
	server := &server{compiler: tooling.CompilerFromEnvironment()}
	reader := protocol.NewLineReader(os.Stdin)
	writer := protocol.NewLineWriter(os.Stdout)
	for {
		payload, err := reader.Read()
		if errors.Is(err, io.EOF) {
			return
		}
		if err != nil {
			_ = writeError(writer, nil, -32700, err.Error())
			return
		}
		var request jsonRPCRequest
		if err := json.Unmarshal(payload, &request); err != nil {
			_ = writeError(writer, nil, -32700, "parse error")
			continue
		}
		if request.JSONRPC != "2.0" || request.Method == "" {
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
	queryClient := server.compiler
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
		timeout, err := debugTimeout(arguments)
		if err != nil {
			return nil, err
		}
		if command := debugInspectCommand(); command != "" {
			inspectArgs := append([]string{"--file", file}, debugInspectArgs(arguments, timeout)...)
			if server.compiler.Executable != "" {
				inspectArgs = append(inspectArgs, "--compiler", server.compiler.Executable)
			}
			result, err := (tooling.Client{Executable: command, Timeout: debugAttachProcessTimeout(timeout)}).Run(ctx, inspectArgs...)
			if err != nil && len(result.Stdout) == 0 {
				if len(strings.TrimSpace(string(result.Stderr))) > 0 {
					return nil, fmt.Errorf("%w: %s", err, strings.TrimSpace(string(result.Stderr)))
				}
				return nil, err
			}
			return result.Stdout, nil
		}
		args = append([]string{"debug-inspect", file}, debugInspectArgs(arguments, timeout)...)
		queryClient.Timeout = debugAttachProcessTimeout(timeout)
	case "tesl.debug_attach":
		return server.debugAttach(ctx, arguments)
	default:
		return nil, fmt.Errorf("unknown tool: %s", name)
	}
	payload, _, err := queryClient.QueryJSON(ctx, args...)
	if err != nil {
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
	action := stringArgument(arguments, "action", "once")
	if action != "once" && action != "snapshot" && action != "ping" && action != "detach" {
		return nil, fmt.Errorf("unsupported debug attach action %q", action)
	}
	breakpoints := stringSlice(arguments["break_at"])
	if action == "once" && len(breakpoints) == 0 {
		return nil, errors.New("debug attach action once requires at least one break_at")
	}
	project := stringArgument(arguments, "project", "")
	if project == "" {
		workingDirectory, err := os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("discover debug project: %w", err)
		}
		project, err = nearestProject(workingDirectory)
		if err != nil {
			return nil, err
		}
	}
	timeout, err := debugTimeout(arguments)
	if err != nil {
		return nil, err
	}
	command := os.Getenv("TESL_DEBUG_ATTACH")
	if command == "" {
		command = "tesl-debug-attach"
	}
	if _, err := exec.LookPath(command); err != nil {
		return nil, fmt.Errorf("debug attach command unavailable: %w", err)
	}
	args := []string{"--operation", action, "--project", project}
	for _, value := range breakpoints {
		args = append(args, "--break-at", value)
	}
	if when := stringArgument(arguments, "when", ""); when != "" {
		args = append(args, "--when", when)
	}
	if hit := stringArgument(arguments, "hit", ""); hit != "" {
		args = append(args, "--hit", hit)
	}
	args = append(args, "--timeout-ms", strconv.FormatInt(timeout.Milliseconds(), 10))
	result, err := (tooling.Client{Executable: command, Timeout: debugAttachProcessTimeout(timeout)}).Run(ctx, args...)
	if err != nil && len(result.Stdout) == 0 {
		return nil, err
	}
	return result.Stdout, nil
}

func debugAttachProcessTimeout(timeout time.Duration) time.Duration {
	return timeout + debugProcessMargin
}

func debugTimeout(arguments map[string]any) (time.Duration, error) {
	if _, present := arguments["timeout_ms"]; !present {
		return defaultDebugAttachTimeout, nil
	}
	if !numberArgumentPresent(arguments, "timeout_ms") || numberArgument(arguments, "timeout_ms") <= 0 {
		return 0, errors.New("timeout_ms must be a positive integer")
	}
	timeout := time.Duration(numberArgument(arguments, "timeout_ms")) * time.Millisecond
	if timeout > 24*time.Hour {
		return 0, errors.New("timeout_ms must not exceed 86400000")
	}
	return timeout, nil
}

func nearestProject(start string) (string, error) {
	directory, err := filepath.Abs(start)
	if err != nil {
		return "", fmt.Errorf("discover debug project: %w", err)
	}
	for {
		if info, statErr := os.Stat(filepath.Join(directory, "tesl.toml")); statErr == nil && !info.IsDir() {
			return directory, nil
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			return "", fmt.Errorf("discover debug project: no tesl.toml found from %s", start)
		}
		directory = parent
	}
}

func sourceQueryArgs(flag, file string, line, col int) []string {
	return []string{flag, file, strconv.Itoa(line), strconv.Itoa(col)}
}

func debugInspectArgs(arguments map[string]any, timeout time.Duration) []string {
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
	args = append(args, "--timeout-ms", strconv.FormatInt(timeout.Milliseconds(), 10))
	return args
}

func debugInspectCommand() string {
	command, _ := toolchain.Default().Resolve("tesl-debug-inspect")
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
			"timeout_ms":  map[string]any{"type": "integer", "minimum": 1, "maximum": 86400000, "default": 30000},
		},
	}
	debugAttach := map[string]any{
		"type":     "object",
		"required": []string{},
		"allOf": []map[string]any{{
			"if": map[string]any{"anyOf": []map[string]any{
				{"not": map[string]any{"required": []string{"action"}}},
				{"properties": map[string]any{"action": map[string]any{"const": "once"}}, "required": []string{"action"}},
			}},
			"then": map[string]any{"required": []string{"break_at"}},
		}},
		"properties": map[string]any{
			"project":    map[string]string{"type": "string"},
			"action":     map[string]any{"type": "string", "enum": []string{"once", "snapshot", "ping", "detach"}, "default": "once"},
			"break_at":   map[string]any{"type": "array", "minItems": 1, "items": map[string]string{"type": "string"}},
			"when":       map[string]string{"type": "string"},
			"hit":        map[string]string{"type": "string"},
			"timeout_ms": map[string]any{"type": "integer", "minimum": 1, "maximum": 86400000, "default": 30000},
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
	// Keep MCP alive without a compiler. Tool calls return contained MCP errors;
	// initialize/tools/list remain usable for clients inspecting capabilities.
	value, _ := toolchain.Default().Resolve("compiler")
	return value, nil
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

func writeError(writer *protocol.LineWriter, id json.RawMessage, code int, message string) error {
	return writer.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
}
