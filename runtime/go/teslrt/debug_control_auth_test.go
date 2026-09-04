package teslrt

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// controlConn is a minimal line-protocol client for the tests below.
type controlConn struct {
	t      *testing.T
	conn   net.Conn
	reader *bufio.Reader
}

func dialControl(t *testing.T, network, address string) *controlConn {
	t.Helper()
	conn, err := net.Dial(network, address)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return &controlConn{t: t, conn: conn, reader: bufio.NewReader(conn)}
}

// send writes one request and returns the decoded reply, or io.EOF-shaped error
// when the endpoint closed the connection instead of answering.
func (client *controlConn) send(request DebugControlRequest) (map[string]any, error) {
	client.t.Helper()
	if err := json.NewEncoder(client.conn).Encode(request); err != nil {
		return nil, err
	}
	return client.readLine()
}

func (client *controlConn) readLine() (map[string]any, error) {
	client.t.Helper()
	_ = client.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := client.reader.ReadString('\n')
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(line), &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (client *controlConn) mustSend(request DebugControlRequest) map[string]any {
	client.t.Helper()
	response, err := client.send(request)
	if err != nil {
		client.t.Fatalf("%s: %v", request.Command, err)
	}
	if response["error"] != nil {
		client.t.Fatalf("%s rejected: %v", request.Command, response)
	}
	return response
}

// expectClosed asserts the endpoint has closed the connection: further reads
// hit EOF (after at most one unauthorized error line) and writes eventually fail.
func (client *controlConn) expectClosed() {
	client.t.Helper()
	_ = client.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		_, err := client.reader.ReadString('\n')
		if err != nil {
			if errors.Is(err, io.EOF) || strings.Contains(err.Error(), "reset") {
				return
			}
			client.t.Fatalf("connection not closed by endpoint: %v", err)
		}
	}
}

// secretCheckpoint runs a checkpoint carrying a request-scoped local on its own
// goroutine and reports when it returned.
func secretCheckpoint(debugger *Debugger, frame DebugFrame) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		debugger.Checkpoint(frame)
		close(done)
	}()
	return done
}

var loginFrame = DebugFrame{ID: "f1", Function: "login", Location: SourceLocation{File: "main.tesl", Line: 7}, Locals: []DebugLocal{
	{Name: "sessionCookie", Type: "String", Accessor: func() DebugValue { return DebugValueOf("sid=abc123", "sessionCookie") }},
}}

func heldFor(done <-chan struct{}, wait time.Duration) bool {
	select {
	case <-done:
		return false
	case <-time.After(wait):
		return true
	}
}

func TestDebugControlTCPRefusesCommandsBeforeHandshake(t *testing.T) {
	debugger := NewDebugger()
	server, err := debugger.StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	if err := ValidateDebugToken(server.Token()); err != nil {
		t.Fatalf("server token: %v", err)
	}

	// No handshake at all: pause is refused, the connection is closed, and the
	// next checkpoint is NOT held (no listener was attached).
	bare := dialControl(t, "tcp4", server.Endpoint())
	if response, err := bare.send(DebugControlRequest{ID: "1", Command: "pause"}); err == nil {
		if errObj, _ := response["error"].(map[string]any); errObj == nil || errObj["code"] != "unauthorized" {
			t.Fatalf("pause without handshake answered %v", response)
		}
	}
	bare.expectClosed()
	if heldFor(secretCheckpoint(debugger, loginFrame), 200*time.Millisecond) {
		t.Fatal("checkpoint held by an unauthenticated pause")
	}

	// Handshake without a token, and with the wrong token: same fate.
	for _, token := range []string{"", strings.Repeat("00", 32), server.Token()[:63] + "x"} {
		client := dialControl(t, "tcp4", server.Endpoint())
		if response, err := client.send(DebugControlRequest{ID: "1", Command: "handshake", Token: token}); err == nil {
			if response["error"] == nil {
				t.Fatalf("handshake with token %q accepted", token)
			}
		}
		client.expectClosed()
	}
	if heldFor(secretCheckpoint(debugger, loginFrame), 200*time.Millisecond) {
		t.Fatal("checkpoint held after rejected handshakes")
	}

	// The right token: pause works, the stop is held, the event and snapshot carry
	// the locals, continue releases.
	client := dialControl(t, "tcp4", server.Endpoint())
	client.mustSend(DebugControlRequest{ID: "1", Command: "handshake", Token: server.Token()})
	client.mustSend(DebugControlRequest{ID: "2", Command: "pause"})
	done := secretCheckpoint(debugger, loginFrame)
	event, err := client.readLine()
	if err != nil || event["event"] != "stopped" {
		t.Fatalf("stopped event = %v, %v", event, err)
	}
	if !heldFor(done, 200*time.Millisecond) {
		t.Fatal("authenticated pause did not hold the checkpoint")
	}
	snapshot := client.mustSend(DebugControlRequest{ID: "3", Command: "snapshot"})
	if raw, _ := json.Marshal(snapshot); !strings.Contains(string(raw), "sid=abc123") {
		t.Fatalf("snapshot lacks locals: %s", raw)
	}
	client.mustSend(DebugControlRequest{ID: "4", Command: "continue"})
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("continue did not release the checkpoint")
	}
}

func TestDebugControlSessionSurvivesUnauthenticatedChurn(t *testing.T) {
	debugger := NewDebugger()
	server, err := debugger.StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()

	// The operator's session is live first...
	operator := dialControl(t, "tcp4", server.Endpoint())
	operator.mustSend(DebugControlRequest{ID: "1", Command: "handshake", Token: server.Token()})
	operator.mustSend(DebugControlRequest{ID: "2", Command: "set-breakpoints", Breakpoints: []DebugBreakpointSpec{{ID: "bp", File: "main.tesl", Line: 7}}})

	// ...then a port scanner connects and drops, and a second probe sends garbage.
	scanner := dialControl(t, "tcp4", server.Endpoint())
	_ = scanner.conn.Close()
	probe := dialControl(t, "tcp4", server.Endpoint())
	_, _ = probe.conn.Write([]byte("GET / HTTP/1.0\r\n\r\n"))
	probe.expectClosed()
	time.Sleep(50 * time.Millisecond)

	// The operator's breakpoint still stops, and the probes saw no event.
	done := secretCheckpoint(debugger, loginFrame)
	event, err := operator.readLine()
	if err != nil || event["event"] != "stopped" {
		t.Fatalf("stopped event after churn = %v, %v", event, err)
	}
	if !heldFor(done, 200*time.Millisecond) {
		t.Fatal("breakpoint no longer holds after an unauthenticated disconnect")
	}
	operator.mustSend(DebugControlRequest{ID: "3", Command: "continue"})
	<-done
}

func TestDebugControlTCPBoundsSilentHandshakesAndPendingConnections(t *testing.T) {
	server, err := NewDebugger().StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	server.mutex.Lock()
	server.handshakeTimeout = 80 * time.Millisecond
	server.maxPendingTCP = 2
	server.mutex.Unlock()

	first, err := net.Dial("tcp4", server.Endpoint())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = first.Close() }()
	second, err := net.Dial("tcp4", server.Endpoint())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = second.Close() }()

	deadline := time.Now().Add(time.Second)
	for {
		server.mutex.Lock()
		pending := len(server.pending)
		server.mutex.Unlock()
		if pending == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("pending handshakes = %d, want 2", pending)
		}
		time.Sleep(time.Millisecond)
	}

	overflow, err := net.Dial("tcp4", server.Endpoint())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = overflow.Close() }()
	_ = overflow.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := overflow.Read(make([]byte, 1)); err == nil {
		t.Fatal("connection above pending handshake cap remained open")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatalf("connection above pending handshake cap was not closed: %v", err)
	}

	_ = first.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := first.Read(make([]byte, 1)); err == nil {
		t.Fatal("silent unauthenticated connection survived handshake deadline")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatalf("server did not enforce its handshake deadline: %v", err)
	}
}

func TestDebugControlDetachesOnlyWhenLastClientLeaves(t *testing.T) {
	debugger := NewDebugger()
	server, err := debugger.StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	first := dialControl(t, "tcp4", server.Endpoint())
	first.mustSend(DebugControlRequest{ID: "1", Command: "handshake", Token: server.Token()})
	second := dialControl(t, "tcp4", server.Endpoint())
	second.mustSend(DebugControlRequest{ID: "1", Command: "handshake", Token: server.Token()})
	second.mustSend(DebugControlRequest{ID: "2", Command: "set-breakpoints", Breakpoints: []DebugBreakpointSpec{{ID: "bp", File: "main.tesl", Line: 7}}})

	// The first client detaches through the protocol; the second keeps its session.
	first.mustSend(DebugControlRequest{ID: "2", Command: "detach"})
	first.expectClosed()
	time.Sleep(50 * time.Millisecond)
	done := secretCheckpoint(debugger, loginFrame)
	if event, err := second.readLine(); err != nil || event["event"] != "stopped" {
		t.Fatalf("stopped event = %v, %v", event, err)
	}
	if !heldFor(done, 200*time.Millisecond) {
		t.Fatal("first client's detach ended the second client's session")
	}
	second.mustSend(DebugControlRequest{ID: "3", Command: "continue"})
	<-done

	// The last client leaving detaches: nothing is held afterwards.
	_ = second.conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		debugger.mutex.Lock()
		detached := debugger.listener == nil
		debugger.mutex.Unlock()
		if detached {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if heldFor(secretCheckpoint(debugger, loginFrame), 200*time.Millisecond) {
		t.Fatal("checkpoint held after the last client left")
	}
}

func TestDebugControlContinueClearsRetainedLocals(t *testing.T) {
	debugger := NewDebugger()
	server, err := debugger.StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	client := dialControl(t, "tcp4", server.Endpoint())
	client.mustSend(DebugControlRequest{ID: "1", Command: "handshake", Token: server.Token()})
	client.mustSend(DebugControlRequest{ID: "2", Command: "pause"})
	done := secretCheckpoint(debugger, loginFrame)
	if _, err := client.readLine(); err != nil {
		t.Fatal(err)
	}
	client.mustSend(DebugControlRequest{ID: "3", Command: "continue"})
	<-done
	snapshot := client.mustSend(DebugControlRequest{ID: "4", Command: "snapshot"})
	raw, _ := json.Marshal(snapshot)
	if strings.Contains(string(raw), "sid=abc123") || strings.Contains(string(raw), `"login"`) {
		t.Fatalf("snapshot after continue still carries the stopped frame: %s", raw)
	}
	result, _ := snapshot["result"].(map[string]any)
	if result["paused"] != false {
		t.Fatalf("snapshot after continue = %v", result)
	}

	// Detach clears it too: stop again, drop the client, then a fresh client
	// reads an empty frame.
	client.mustSend(DebugControlRequest{ID: "5", Command: "pause"})
	done = secretCheckpoint(debugger, loginFrame)
	if _, err := client.readLine(); err != nil {
		t.Fatal(err)
	}
	if frame, paused := debugger.Snapshot(); !paused || frame.Function != "login" {
		t.Fatalf("expected a held login frame, got %#v paused=%v", frame, paused)
	}
	_ = client.conn.Close()
	<-done
	fresh := dialControl(t, "tcp4", server.Endpoint())
	fresh.mustSend(DebugControlRequest{ID: "1", Command: "handshake", Token: server.Token()})
	snapshot = fresh.mustSend(DebugControlRequest{ID: "2", Command: "snapshot"})
	if raw, _ := json.Marshal(snapshot); strings.Contains(string(raw), "sid=abc123") {
		t.Fatalf("snapshot after detach still carries the stopped frame: %s", raw)
	}
}

// Unix endpoints keep the permission-based contract: no handshake needed, a
// handshake (with or without a token) is harmless, and client churn does not end
// another client's session.
func TestDebugControlUnixSessionSurvivesClientChurn(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix control endpoint")
	}
	path := filepath.Join(t.TempDir(), "debug.sock")
	debugger := NewDebugger()
	server, err := debugger.StartDebugControl(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	if server.Token() != "" {
		t.Fatal("unix endpoint must not require a token")
	}
	dropped := dialControl(t, "unix", path)
	dropped.mustSend(DebugControlRequest{ID: "1", Command: "handshake", Token: "ignored-on-unix"})
	_ = dropped.conn.Close()
	time.Sleep(50 * time.Millisecond)

	client := dialControl(t, "unix", path)
	client.mustSend(DebugControlRequest{ID: "1", Command: "set-breakpoints", Breakpoints: []DebugBreakpointSpec{{ID: "bp", File: "main.tesl", Line: 7}}})
	done := secretCheckpoint(debugger, loginFrame)
	if event, err := client.readLine(); err != nil || event["event"] != "stopped" {
		t.Fatalf("stopped event = %v, %v", event, err)
	}
	if !heldFor(done, 200*time.Millisecond) {
		t.Fatal("an earlier client's disconnect ended this client's session")
	}
	client.mustSend(DebugControlRequest{ID: "2", Command: "continue"})
	<-done
}

func TestDebugControlEnvironmentPublishesPortAndToken(t *testing.T) {
	root := t.TempDir()
	t.Setenv("TESL_DEBUG", "")
	t.Setenv("TESL_DEBUG_SOCKET", "")
	t.Setenv("TESL_DEBUG_PORT", "0")
	t.Setenv("TESL_DEBUG_ROOT", root)
	t.Setenv(DebugTokenEnv, "")
	server, err := StartDebugControlFromEnvironment()
	if err != nil {
		t.Fatal(err)
	}
	if server == nil {
		t.Fatal("TESL_DEBUG_PORT did not start a control server")
	}
	stuff := filepath.Join(root, ".tesl-stuff")
	portFile, tokenFile := filepath.Join(stuff, DebugPortFile), filepath.Join(stuff, DebugTokenFile)
	for _, path := range []string{portFile, tokenFile} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode = %o", path, info.Mode().Perm())
		}
	}
	port, _ := os.ReadFile(portFile)
	if !strings.HasSuffix(server.Endpoint(), ":"+strings.TrimSpace(string(port))) {
		t.Fatalf("port file %q does not match endpoint %s", port, server.Endpoint())
	}
	token, _ := os.ReadFile(tokenFile)
	if strings.TrimSpace(string(token)) != server.Token() {
		t.Fatalf("token file %q does not match Token() %q", token, server.Token())
	}
	client := dialControl(t, "tcp4", server.Endpoint())
	client.mustSend(DebugControlRequest{ID: "1", Command: "handshake", Token: strings.TrimSpace(string(token))})
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{portFile, tokenFile} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s survived Close: %v", path, err)
		}
	}

	// A launcher-supplied token is honoured verbatim; a malformed one is refused.
	launcherToken, err := NewDebugToken()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(DebugTokenEnv, launcherToken)
	server, err = StartDebugControlFromEnvironment()
	if err != nil {
		t.Fatal(err)
	}
	if server == nil {
		t.Fatal("TESL_DEBUG_PORT did not start a control server")
	}
	if server.Token() != launcherToken {
		t.Fatalf("Token() = %q, want launcher token", server.Token())
	}
	_ = server.Close()
	t.Setenv(DebugTokenEnv, "short")
	if server, err := StartDebugControlFromEnvironment(); err == nil {
		_ = server.Close()
		t.Fatal("malformed launcher token accepted")
	}
}
