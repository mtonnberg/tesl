package teslrt

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

const (
	DebugProtocolVersion = 1
	debugMaxControlLine  = 1 << 20
)

type DebugControlRequest struct {
	ID          string                `json:"id"`
	Command     string                `json:"command"`
	Breakpoints []DebugBreakpointSpec `json:"breakpoints,omitempty"`
}

type DebugBreakpointSpec struct {
	ID        string `json:"id,omitempty"`
	File      string `json:"file"`
	Line      int    `json:"line"`
	Condition string `json:"condition,omitempty"`
	Hit       string `json:"hit,omitempty"`
}

type DebugControlResponse struct {
	ID     string             `json:"id,omitempty"`
	Result json.RawMessage    `json:"result,omitempty"`
	Error  *DebugControlError `json:"error,omitempty"`
}

type DebugControlError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type DebugStoppedEvent struct {
	Event string       `json:"event"`
	Frame DebugFrame   `json:"frame"`
	Stack []DebugFrame `json:"stack,omitempty"`
}

type DebugHandshake struct {
	Version      int      `json:"version"`
	Runtime      string   `json:"runtime"`
	ABIVersion   int      `json:"abiVersion"`
	Capabilities []string `json:"capabilities"`
}

type debugConditionValue struct {
	text    string
	number  int64
	hasNum  bool
	bool    bool
	hasBool bool
}

type DebugControlServer struct {
	debugger       *Debugger
	listener       net.Listener
	path           string
	done           chan struct{}
	closed         chan struct{}
	mutex          sync.Mutex
	clients        map[net.Conn]struct{}
	configured     chan struct{}
	configuredOnce sync.Once
	write          sync.Mutex
	detach         func()
}

// StartDebugControl creates an owner-only Unix-domain endpoint and starts the
// versioned control server. Existing socket files are removed only when they are
// actually sockets; regular files are never overwritten.
func (debugger *Debugger) StartDebugControl(path string) (*DebugControlServer, error) {
	if path == "" {
		return nil, errors.New("debug control: socket path is empty")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil { // #nosec G703 -- debug endpoint path is intentionally caller-selected.
		return nil, fmt.Errorf("debug control: create endpoint directory: %w", err)
	}
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil { // #nosec G302,G703 -- tighten the private endpoint directory.
		return nil, fmt.Errorf("debug control: protect endpoint directory: %w", err)
	}
	if directory, err := os.Stat(filepath.Dir(path)); err != nil { // #nosec G703 -- path is the configured local debug endpoint.
		return nil, fmt.Errorf("debug control: inspect endpoint directory: %w", err)
	} else if directory.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("debug control: endpoint directory is not owner-only")
	}
	if info, err := os.Lstat(path); err == nil { // #nosec G703 -- inspect only the configured debug endpoint.
		if info.Mode()&os.ModeSocket == 0 {
			return nil, errors.New("debug control: endpoint exists and is not a socket")
		}
		if err := os.Remove(path); err != nil { // #nosec G703 -- remove only a verified stale socket.
			return nil, fmt.Errorf("debug control: remove stale endpoint: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("debug control: inspect endpoint: %w", err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("debug control: listen: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil { // #nosec G703 -- protect the configured debug socket.
		_ = listener.Close()
		_ = os.Remove(path) // #nosec G703 -- remove only the socket just created.
		return nil, fmt.Errorf("debug control: protect endpoint: %w", err)
	}
	return newDebugControlServer(debugger, listener, path), nil
}

// StartDebugControlTCP provides the loopback fallback for platforms without
// usable Unix sockets. Port zero asks the OS for an available port.
func (debugger *Debugger) StartDebugControlTCP(port int) (*DebugControlServer, error) {
	if port < 0 || port > 65535 {
		return nil, errors.New("debug control: TCP port outside 0..65535")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		return nil, fmt.Errorf("debug control: listen on loopback: %w", err)
	}
	return newDebugControlServer(debugger, listener, ""), nil
}

// StartDebugControlFromEnvironment is the debug-build launch seam. It remains
// inert unless TESL_DEBUG is enabled, while explicit socket/port variables make
// test and attach launchers deterministic.
func StartDebugControlFromEnvironment() (*DebugControlServer, error) {
	if socket := os.Getenv("TESL_DEBUG_SOCKET"); socket != "" {
		return DefaultDebugger.StartDebugControl(socket)
	}
	if port := os.Getenv("TESL_DEBUG_PORT"); port != "" {
		value, err := strconv.Atoi(port)
		if err != nil {
			return nil, fmt.Errorf("debug control: invalid TESL_DEBUG_PORT: %w", err)
		}
		return DefaultDebugger.StartDebugControlTCP(value)
	}
	enabled := os.Getenv("TESL_DEBUG")
	if enabled != "1" && enabled != "true" {
		return nil, nil
	}
	root := os.Getenv("TESL_DEBUG_ROOT")
	if root == "" {
		root = "."
	}
	return DefaultDebugger.StartDebugControl(filepath.Join(root, ".tesl-stuff", "debug.sock"))
}

func newDebugControlServer(debugger *Debugger, listener net.Listener, path string) *DebugControlServer {
	server := &DebugControlServer{
		debugger:   debugger,
		listener:   listener,
		path:       path,
		done:       make(chan struct{}),
		closed:     make(chan struct{}),
		clients:    make(map[net.Conn]struct{}),
		configured: make(chan struct{}),
	}
	server.detach = debugger.Attach(server.broadcast)
	go server.acceptLoop()
	return server
}

func (server *DebugControlServer) Endpoint() string { return server.listener.Addr().String() }

// WaitForConfiguration holds a compiler-launched target until its DAP client has
// installed the initial breakpoint set. It is deliberately opt-in: ordinary debug
// runs and attach sessions keep their existing start behavior.
func (server *DebugControlServer) WaitForConfiguration() {
	select {
	case <-server.configured:
	case <-server.done:
	}
}

func (server *DebugControlServer) acceptLoop() {
	defer close(server.closed)
	for {
		connection, err := server.listener.Accept()
		if err != nil {
			select {
			case <-server.done:
				return
			default:
			}
			continue
		}
		server.mutex.Lock()
		server.clients[connection] = struct{}{}
		server.mutex.Unlock()
		go server.handleConnection(connection)
	}
}

func (server *DebugControlServer) handleConnection(connection net.Conn) {
	defer func() {
		// A lost control client must never leave application goroutines paused. Detach
		// also clears the listener so a fresh client can establish a new session.
		server.debugger.Detach()
		server.mutex.Lock()
		delete(server.clients, connection)
		server.mutex.Unlock()
		_ = connection.Close()
	}()
	scanner := bufio.NewScanner(connection)
	scanner.Buffer(make([]byte, 4096), debugMaxControlLine)
	encoder := json.NewEncoder(connection)
	for scanner.Scan() {
		var request DebugControlRequest
		decoder := json.NewDecoder(strings.NewReader(scanner.Text()))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&request); err != nil || request.Command == "" {
			_ = encoder.Encode(DebugControlResponse{ID: request.ID, Error: &DebugControlError{
				Code: "invalid-request", Message: "invalid control request",
			}})
			continue
		}
		response, closeConnection := server.handleRequest(request)
		server.write.Lock()
		err := encoder.Encode(response)
		server.write.Unlock()
		if err != nil || closeConnection {
			return
		}
	}
}

func (server *DebugControlServer) handleRequest(request DebugControlRequest) (DebugControlResponse, bool) {
	result := func(value any) DebugControlResponse {
		encoded, _ := json.Marshal(value)
		return DebugControlResponse{ID: request.ID, Result: encoded}
	}
	errorResponse := func(code, message string) DebugControlResponse {
		return DebugControlResponse{ID: request.ID, Error: &DebugControlError{Code: code, Message: message}}
	}
	switch request.Command {
	case "handshake":
		return result(DebugHandshake{
			Version: DebugProtocolVersion, Runtime: "go", ABIVersion: DebugABIVersion,
			Capabilities: []string{"breakpoints", "conditions", "hit-counts", "pause", "snapshot", "continue", "step-in", "step-over", "step-out", "detach"},
		}), false
	case "ping":
		return result(map[string]bool{"ok": true}), false
	case "set-breakpoints":
		server.configuredOnce.Do(func() { close(server.configured) })
		breakpoints := make([]DebugBreakpoint, 0, len(request.Breakpoints))
		for _, specification := range request.Breakpoints {
			condition, err := compileDebugCondition(specification.Condition)
			if err != nil {
				return errorResponse("invalid-condition", err.Error()), false
			}
			hitCondition, err := parseHitCondition(specification.Hit)
			if err != nil {
				return errorResponse("invalid-hit-condition", err.Error()), false
			}
			breakpoints = append(breakpoints, DebugBreakpoint{
				ID: specification.ID, File: specification.File, Line: specification.Line,
				Condition:    condition,
				HitCondition: hitCondition,
			})
		}
		return result(server.debugger.SetBreakpoints(breakpoints)), false
	case "clear-breakpoints":
		server.debugger.ClearBreakpoints()
		return result(map[string]bool{"ok": true}), false
	case "pause":
		server.debugger.Pause()
		return result(map[string]bool{"ok": true}), false
	case "continue":
		server.debugger.Continue()
		return result(map[string]bool{"ok": true}), false
	case "step-in", "step-over", "step-out":
		mode := DebugStepIn
		switch request.Command {
		case "step-over":
			mode = DebugStepOver
		case "step-out":
			mode = DebugStepOut
		}
		if !server.debugger.Step(mode) {
			return errorResponse("not-stopped", "step requires a stopped debugger"), false
		}
		return result(map[string]bool{"ok": true}), false
	case "snapshot":
		return result(server.debugger.SnapshotState()), false
	case "detach":
		return result(map[string]bool{"ok": true}), true
	default:
		return errorResponse("unknown-command", "unsupported control command: "+request.Command), false
	}
}

func splitCondition(value, separator string) []string {
	parts := []string{}
	start := 0
	inString := false
	escaped := false
	for index := 0; index < len(value); index++ {
		character := value[index]
		if inString {
			if escaped {
				escaped = false
			} else if character == '\\' {
				escaped = true
			} else if character == '"' {
				inString = false
			}
			continue
		}
		if character == '"' {
			inString = true
			continue
		}
		if strings.HasPrefix(value[index:], separator) {
			parts = append(parts, value[start:index])
			start = index + len(separator)
			index += len(separator) - 1
		}
	}
	if len(parts) == 0 {
		return []string{value}
	}
	return append(parts, value[start:])
}

func conditionOperand(frame DebugFrame, operand string) (debugConditionValue, bool) {
	operand = strings.TrimSpace(operand)
	if len(operand) >= 2 && operand[0] == '"' && operand[len(operand)-1] == '"' {
		value, err := strconv.Unquote(operand)
		return debugConditionValue{text: value}, err == nil
	}
	if value, err := strconv.ParseInt(operand, 10, 64); err == nil {
		return debugConditionValue{text: operand, number: value, hasNum: true}, true
	}
	if operand == "true" || operand == "false" {
		return debugConditionValue{text: operand, bool: operand == "true", hasBool: true}, true
	}
	var value string
	switch operand {
	case "file":
		value = frame.Location.File
	case "line":
		value = strconv.Itoa(frame.Location.Line)
	case "column":
		value = strconv.Itoa(frame.Location.Column)
	case "function":
		value = frame.Function
	case "id":
		value = frame.ID
	case "depth":
		value = strconv.Itoa(frame.Depth)
	case "test":
		value = frame.Test
	default:
		found := false
		for _, local := range frame.Locals {
			if local.Name == operand {
				value = local.Value.Display
				found = true
				break
			}
		}
		if !found {
			return debugConditionValue{}, false
		}
	}
	if number, err := strconv.ParseInt(value, 10, 64); err == nil {
		return debugConditionValue{text: value, number: number, hasNum: true}, true
	}
	if value == "true" || value == "false" {
		return debugConditionValue{text: value, bool: value == "true", hasBool: true}, true
	}
	return debugConditionValue{text: value}, true
}

func compileDebugCondition(specification string) (func(DebugFrame) bool, error) {
	specification = strings.TrimSpace(specification)
	if specification == "" {
		return nil, nil
	}
	if strings.Contains(specification, "===") || strings.Contains(specification, "!==") {
		return nil, errors.New("condition supports ==, !=, >=, <=, >, and < only")
	}
	if strings.HasPrefix(specification, "!") {
		inner, err := compileDebugCondition(strings.TrimSpace(specification[1:]))
		if err != nil || inner == nil {
			if err == nil {
				err = errors.New("condition negation requires an expression")
			}
			return nil, err
		}
		return func(frame DebugFrame) bool { return !inner(frame) }, nil
	}
	for _, logical := range []string{"||", "&&"} {
		parts := splitCondition(specification, logical)
		if len(parts) > 1 {
			conditions := make([]func(DebugFrame) bool, 0, len(parts))
			for _, part := range parts {
				condition, err := compileDebugCondition(part)
				if err != nil || condition == nil {
					if err == nil {
						err = errors.New("logical condition requires expressions on both sides")
					}
					return nil, err
				}
				conditions = append(conditions, condition)
			}
			return func(frame DebugFrame) bool {
				if logical == "||" {
					for _, condition := range conditions {
						if condition(frame) {
							return true
						}
					}
					return false
				}
				for _, condition := range conditions {
					if !condition(frame) {
						return false
					}
				}
				return true
			}, nil
		}
	}
	operators := []string{"==", "!=", ">=", "<=", ">", "<"}
	for _, operator := range operators {
		if index := strings.Index(specification, operator); index >= 0 {
			left, right := strings.TrimSpace(specification[:index]), strings.TrimSpace(specification[index+len(operator):])
			if left == "" || right == "" {
				return nil, errors.New("condition requires two operands")
			}
			return func(frame DebugFrame) bool {
				leftValue, leftOK := conditionOperand(frame, left)
				rightValue, rightOK := conditionOperand(frame, right)
				if !leftOK || !rightOK {
					return false
				}
				if leftValue.hasNum && rightValue.hasNum {
					return compareConditionNumbers(leftValue.number, rightValue.number, operator)
				}
				if leftValue.hasBool && rightValue.hasBool {
					if operator == "==" {
						return leftValue.bool == rightValue.bool
					}
					if operator == "!=" {
						return leftValue.bool != rightValue.bool
					}
					return false
				}
				switch operator {
				case "==":
					return leftValue.text == rightValue.text
				case "!=":
					return leftValue.text != rightValue.text
				case ">":
					return leftValue.text > rightValue.text
				case ">=":
					return leftValue.text >= rightValue.text
				case "<":
					return leftValue.text < rightValue.text
				case "<=":
					return leftValue.text <= rightValue.text
				default:
					return false
				}
			}, nil
		}
	}
	return nil, errors.New("condition must compare fields, locals, or literals")
}

func compareConditionNumbers(left, right int64, operator string) bool {
	switch operator {
	case "==":
		return left == right
	case "!=":
		return left != right
	case ">":
		return left > right
	case ">=":
		return left >= right
	case "<":
		return left < right
	case "<=":
		return left <= right
	default:
		return false
	}
}

func (server *DebugControlServer) broadcast(event DebugEvent) {
	message, err := json.Marshal(DebugStoppedEvent{Event: event.Kind, Frame: event.Frame, Stack: event.Stack})
	if err != nil {
		return
	}
	message = append(message, '\n')
	server.mutex.Lock()
	clients := make([]net.Conn, 0, len(server.clients))
	for client := range server.clients {
		clients = append(clients, client)
	}
	server.mutex.Unlock()
	server.write.Lock()
	defer server.write.Unlock()
	for _, client := range clients {
		_, _ = client.Write(message)
	}
}

func (server *DebugControlServer) Close() error {
	select {
	case <-server.done:
		return nil
	default:
		close(server.done)
	}
	if server.detach != nil {
		server.detach()
	}
	_ = server.listener.Close()
	server.mutex.Lock()
	for client := range server.clients {
		_ = client.Close()
	}
	server.mutex.Unlock()
	<-server.closed
	if server.path == "" {
		return nil
	}
	return os.Remove(server.path)
}

func parseHitCondition(specification string) (func(int) bool, error) {
	specification = strings.TrimSpace(specification)
	if specification == "" {
		return nil, nil
	}
	operator := "=="
	value := specification
	for _, candidate := range []string{"%", ">=", "<=", ">", "<", "=="} {
		if strings.HasPrefix(specification, candidate) {
			operator, value = candidate, strings.TrimSpace(specification[len(candidate):])
			break
		}
	}
	count, err := strconv.Atoi(value)
	if err != nil || count <= 0 {
		return nil, errors.New("hit condition must be a positive integer with ==, >=, <=, >, <, or %")
	}
	return func(hit int) bool {
		switch operator {
		case "%":
			return hit%count == 0
		case ">=":
			return hit >= count
		case "<=":
			return hit <= count
		case ">":
			return hit > count
		case "<":
			return hit < count
		default:
			return hit == count
		}
	}, nil
}

// CompileDebugCondition exposes the bounded condition grammar to debugger adapters.
func CompileDebugCondition(specification string) (func(DebugFrame) bool, error) {
	return compileDebugCondition(specification)
}

// ParseHitCondition exposes hit-count parsing to debugger adapters.
func ParseHitCondition(specification string) (func(int) bool, error) {
	return parseHitCondition(specification)
}
