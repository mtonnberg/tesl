package teslrt

import (
	"bufio"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	DebugProtocolVersion = 1
	debugMaxControlLine  = 1 << 20
	// DebugPortFile and DebugTokenFile are written under <root>/.tesl-stuff/ when
	// the environment selects the loopback TCP fallback, so attach tooling can
	// discover the endpoint AND prove it is allowed to drive it.
	DebugPortFile  = "debug.port"
	DebugTokenFile = "debug.token"
	// DebugTokenEnv lets a launcher that already knows the port (it chose it) hand
	// the child the token to require, instead of reading the token file back.
	DebugTokenEnv         = "TESL_DEBUG_TOKEN" // #nosec G101 -- the NAME of the variable, not a credential.
	debugTokenBytes       = 32
	debugHandshakeTimeout = 5 * time.Second
	debugMaxPendingTCP    = 16
	debugMaxUnixPathBytes = 100
)

type DebugControlRequest struct {
	ID          string                `json:"id"`
	Command     string                `json:"command"`
	Breakpoints []DebugBreakpointSpec `json:"breakpoints,omitempty"`
	// Token authenticates the handshake on a TCP endpoint. Unix endpoints are
	// authenticated by the socket's file permissions and ignore it.
	Token string `json:"token,omitempty"`
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
	debugger *Debugger
	listener net.Listener
	path     string
	done     chan struct{}
	closed   chan struct{}
	mutex    sync.Mutex
	// clients holds only AUTHENTICATED connections: they receive stopped events and
	// hold the debugger attached. pending holds connections that have not completed
	// a handshake yet (TCP only); they receive nothing and are closed with the server.
	clients        map[net.Conn]struct{}
	pending        map[net.Conn]struct{}
	configured     chan struct{}
	configuredOnce sync.Once
	write          sync.Mutex
	// token is the hex credential a TCP client must present in its first message.
	// Empty on Unix endpoints, where filesystem permissions are the credential.
	token            string
	handshakeTimeout time.Duration
	maxPendingTCP    int
	// files are the discovery files (port/token) this server wrote and removes on Close.
	files []string
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
	return newDebugControlServer(debugger, listener, path, ""), nil
}

// StartDebugControlTCP provides the loopback fallback for platforms without
// usable Unix sockets. Port zero asks the OS for an available port. Loopback is
// shared by every local user, so the endpoint mints a fresh per-launch token
// (see Token) and refuses every command until a client has presented it.
func (debugger *Debugger) StartDebugControlTCP(port int) (*DebugControlServer, error) {
	token, err := NewDebugToken()
	if err != nil {
		return nil, err
	}
	return debugger.StartDebugControlTCPWithToken(port, token)
}

// StartDebugControlTCPWithToken is StartDebugControlTCP with a caller-chosen
// token — for a launcher that generated the credential itself and passes it to
// the child through DebugTokenEnv. The token must be NewDebugToken-shaped.
func (debugger *Debugger) StartDebugControlTCPWithToken(port int, token string) (*DebugControlServer, error) {
	if port < 0 || port > 65535 {
		return nil, errors.New("debug control: TCP port outside 0..65535")
	}
	if err := ValidateDebugToken(token); err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		return nil, fmt.Errorf("debug control: listen on loopback: %w", err)
	}
	server := newDebugControlServer(debugger, listener, "", token)
	return server, nil
}

// NewDebugToken returns a fresh 32-byte crypto/rand credential, hex encoded.
func NewDebugToken() (string, error) {
	raw := make([]byte, debugTokenBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("debug control: generate token: %w", err)
	}
	return hex.EncodeToString(raw), nil
}

// ValidateDebugToken accepts exactly the shape NewDebugToken produces, so a
// truncated or hand-typed credential is refused at startup rather than silently
// weakening the endpoint.
func ValidateDebugToken(token string) error {
	raw, err := hex.DecodeString(token)
	if err != nil || len(raw) != debugTokenBytes {
		return errors.New("debug control: token must be 32 bytes, hex encoded")
	}
	return nil
}

// Token is the credential a TCP client must send as `token` in its handshake.
// Empty for Unix endpoints.
func (server *DebugControlServer) Token() string { return server.token }

// Port is the bound TCP port, or zero for a Unix endpoint.
func (server *DebugControlServer) Port() int {
	if address, ok := server.listener.Addr().(*net.TCPAddr); ok {
		return address.Port
	}
	return 0
}

// StartDebugControlFromEnvironment is the debug-build launch seam. It remains
// inert unless TESL_DEBUG is enabled, while explicit socket/port variables make
// test and attach launchers deterministic.
func StartDebugControlFromEnvironment() (*DebugControlServer, error) {
	applyEnvPauseTimeout(DefaultDebugger)
	if socket := os.Getenv("TESL_DEBUG_SOCKET"); socket != "" {
		return DefaultDebugger.StartDebugControl(socket)
	}
	if port := os.Getenv("TESL_DEBUG_PORT"); port != "" {
		value, err := strconv.Atoi(port)
		if err != nil {
			return nil, fmt.Errorf("debug control: invalid TESL_DEBUG_PORT: %w", err)
		}
		token := os.Getenv(DebugTokenEnv)
		if token == "" {
			if token, err = NewDebugToken(); err != nil {
				return nil, err
			}
		}
		return startEnvironmentDebugTCP(value, token)
	}
	enabled := os.Getenv("TESL_DEBUG")
	if enabled != "1" && enabled != "true" {
		return nil, nil
	}
	socket := filepath.Join(debugRootFromEnvironment(), ".tesl-stuff", "debug.sock")
	if len([]byte(socket)) > debugMaxUnixPathBytes {
		token, err := NewDebugToken()
		if err != nil {
			return nil, err
		}
		return startEnvironmentDebugTCP(0, token)
	}
	return DefaultDebugger.StartDebugControl(socket)
}

func startEnvironmentDebugTCP(port int, token string) (*DebugControlServer, error) {
	server, err := DefaultDebugger.StartDebugControlTCPWithToken(port, token)
	if err != nil {
		return nil, err
	}
	// The TCP fallback has no socket file to discover, so publish the port and
	// credential under the project. Both files are owner-only.
	if err := server.writeDiscoveryFiles(filepath.Join(debugRootFromEnvironment(), ".tesl-stuff")); err != nil {
		_ = server.Close()
		return nil, err
	}
	return server, nil
}

func debugRootFromEnvironment() string {
	if root := os.Getenv("TESL_DEBUG_ROOT"); root != "" {
		return root
	}
	return "."
}

// writeDiscoveryFiles publishes DebugPortFile and DebugTokenFile under directory
// with owner-only permissions. Pre-existing files are replaced, never followed:
// a planted symlink must not redirect the credential.
func (server *DebugControlServer) writeDiscoveryFiles(directory string) error {
	if err := os.MkdirAll(directory, 0o700); err != nil { // #nosec G703 -- discovery directory is the configured debug root.
		return fmt.Errorf("debug control: create discovery directory: %w", err)
	}
	entries := []struct{ name, contents string }{
		{DebugPortFile, strconv.Itoa(server.Port()) + "\n"},
		{DebugTokenFile, server.token + "\n"},
	}
	for _, entry := range entries {
		path := filepath.Join(directory, entry.name)
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) { // #nosec G703 -- replace only the runtime's own discovery file.
			return fmt.Errorf("debug control: replace %s: %w", entry.name, err)
		}
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600) // #nosec G304,G703 -- owner-only discovery file under the debug root.
		if err != nil {
			return fmt.Errorf("debug control: write %s: %w", entry.name, err)
		}
		server.mutex.Lock()
		server.files = append(server.files, path)
		server.mutex.Unlock()
		_, writeErr := file.WriteString(entry.contents)
		if closeErr := file.Close(); writeErr == nil {
			writeErr = closeErr
		}
		if writeErr != nil {
			return fmt.Errorf("debug control: write %s: %w", entry.name, writeErr)
		}
	}
	return nil
}

// applyEnvPauseTimeout reads TESL_DEBUG_PAUSE_TIMEOUT_MS (milliseconds) into
// debugger.PauseTimeout. Unset or invalid leaves the current value — zero by
// default, i.e. an interactive session waits forever for its human.
func applyEnvPauseTimeout(debugger *Debugger) {
	if raw := os.Getenv("TESL_DEBUG_PAUSE_TIMEOUT_MS"); raw != "" {
		if value, err := strconv.ParseInt(raw, 10, 64); err == nil && value > 0 {
			debugger.PauseTimeout = time.Duration(value) * time.Millisecond
		}
	}
}

func newDebugControlServer(debugger *Debugger, listener net.Listener, path, token string) *DebugControlServer {
	server := &DebugControlServer{
		debugger:         debugger,
		listener:         listener,
		path:             path,
		done:             make(chan struct{}),
		closed:           make(chan struct{}),
		clients:          make(map[net.Conn]struct{}),
		pending:          make(map[net.Conn]struct{}),
		configured:       make(chan struct{}),
		token:            token,
		handshakeTimeout: debugHandshakeTimeout,
		maxPendingTCP:    debugMaxPendingTCP,
	}
	// The debugger is attached per authenticated client (see admit/release), not
	// here: an endpoint with no client must behave exactly like a release build.
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
		if connection == nil {
			return
		}
		server.mutex.Lock()
		if server.token != "" && len(server.pending) >= server.maxPendingTCP {
			server.mutex.Unlock()
			_ = connection.Close()
			continue
		}
		server.pending[connection] = struct{}{}
		server.mutex.Unlock()
		go server.handleConnection(connection)
	}
}

// admit promotes a connection to an authenticated client. The first client
// attaches the debugger; later ones share the session.
func (server *DebugControlServer) admit(connection net.Conn) {
	server.mutex.Lock()
	defer server.mutex.Unlock()
	delete(server.pending, connection)
	select {
	case <-server.done:
		// A handshake racing Close must not re-attach the debugger to a dead endpoint.
		return
	default:
	}
	if _, already := server.clients[connection]; already {
		return
	}
	if len(server.clients) == 0 {
		server.debugger.Attach(server.broadcast)
	}
	server.clients[connection] = struct{}{}
}

// release forgets a connection. Only the LAST authenticated client leaving
// detaches the debugger: a lost client must never leave application goroutines
// paused, but one client's exit must not end another client's session, and a
// connection that never authenticated has no session to end.
func (server *DebugControlServer) release(connection net.Conn) {
	server.mutex.Lock()
	defer server.mutex.Unlock()
	delete(server.pending, connection)
	if _, authenticated := server.clients[connection]; !authenticated {
		return
	}
	delete(server.clients, connection)
	if len(server.clients) == 0 {
		server.debugger.Detach()
	}
}

func (server *DebugControlServer) authenticates(request DebugControlRequest) bool {
	if request.Command != "handshake" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(request.Token), []byte(server.token)) == 1
}

func (server *DebugControlServer) reply(encoder *json.Encoder, response DebugControlResponse) error {
	server.write.Lock()
	defer server.write.Unlock()
	return encoder.Encode(response)
}

func (server *DebugControlServer) handleConnection(connection net.Conn) {
	if connection == nil {
		return
	}
	defer func() {
		server.release(connection)
		_ = connection.Close()
	}()
	// Unix endpoints are authenticated by the socket's owner-only permissions, so
	// the connection is a client from its first byte (a handshake, if sent, is
	// answered like any other command). TCP endpoints admit nothing before a
	// handshake carrying the token.
	authenticated := server.token == ""
	if authenticated {
		server.admit(connection)
	} else {
		server.mutex.Lock()
		handshakeTimeout := server.handshakeTimeout
		server.mutex.Unlock()
		if err := connection.SetReadDeadline(time.Now().Add(handshakeTimeout)); err != nil {
			return
		}
	}
	scanner := bufio.NewScanner(connection)
	scanner.Buffer(make([]byte, 4096), debugMaxControlLine)
	encoder := json.NewEncoder(connection)
	for scanner.Scan() {
		var request DebugControlRequest
		decoder := json.NewDecoder(strings.NewReader(scanner.Text()))
		decoder.DisallowUnknownFields()
		decodeErr := decoder.Decode(&request)
		if !authenticated {
			if decodeErr != nil || !server.authenticates(request) {
				// Closed at once: no session, no events, and nothing learned beyond
				// "a credential is required". The compare is constant-time.
				_ = server.reply(encoder, DebugControlResponse{ID: request.ID, Error: &DebugControlError{
					Code: "unauthorized", Message: "first message must be a handshake carrying the endpoint token",
				}})
				return
			}
			authenticated = true
			server.admit(connection)
			if err := connection.SetReadDeadline(time.Time{}); err != nil {
				return
			}
		}
		if decodeErr != nil || request.Command == "" {
			_ = server.reply(encoder, DebugControlResponse{ID: request.ID, Error: &DebugControlError{
				Code: "invalid-request", Message: "invalid control request",
			}})
			continue
		}
		response, closeConnection := server.handleRequest(request)
		if err := server.reply(encoder, response); err != nil || closeConnection {
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
	case "configuration-done":
		// DAP sends this only after all per-source breakpoint updates. Releasing on
		// the first set-breakpoints request races when VS Code has breakpoints in
		// several files and sends the target file later.
		server.configuredOnce.Do(func() { close(server.configured) })
		return result(map[string]bool{"ok": true}), false
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
	_ = server.listener.Close()
	server.mutex.Lock()
	if len(server.clients) > 0 {
		server.debugger.Detach()
	}
	for client := range server.clients {
		_ = client.Close()
	}
	for connection := range server.pending {
		_ = connection.Close()
	}
	server.clients = make(map[net.Conn]struct{})
	server.pending = make(map[net.Conn]struct{})
	files := server.files
	server.files = nil
	server.mutex.Unlock()
	<-server.closed
	var firstErr error
	for _, file := range files {
		if err := os.Remove(file); err != nil && !errors.Is(err, os.ErrNotExist) && firstErr == nil { // #nosec G703 -- remove only the discovery files this server wrote.
			firstErr = err
		}
	}
	if server.path != "" {
		if err := os.Remove(server.path); err != nil && firstErr == nil { // #nosec G703 -- the socket this server created.
			firstErr = err
		}
	}
	return firstErr
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
