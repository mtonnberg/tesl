package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/teslrt"
)

// startControl spins up a real debugger + control server on a private unix
// socket, so every test below exercises the same wire the shipped tool speaks.
func startControl(t *testing.T) (*teslrt.Debugger, string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("Unix control endpoint")
	}
	path := filepath.Join(t.TempDir(), "debug.sock")
	debugger := teslrt.NewDebugger()
	server, err := debugger.StartDebugControl(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	return debugger, path
}

func decode(t *testing.T, line string) map[string]any {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal([]byte(line), &value); err != nil {
		t.Fatalf("output line %q is not JSON: %v", line, err)
	}
	return value
}

func TestParseBreakpointAcceptsFileLineAndRejectsTheRest(t *testing.T) {
	file, line, err := parseBreakpoint("server.tesl:42")
	if err != nil || file != "server.tesl" || line != 42 {
		t.Fatalf("parse = %q,%d,%v", file, line, err)
	}
	// Windows-style paths keep their drive letter: only the LAST colon splits.
	file, line, err = parseBreakpoint(`C:\app\server.tesl:7`)
	if err != nil || file != `C:\app\server.tesl` || line != 7 {
		t.Fatalf("windows parse = %q,%d,%v", file, line, err)
	}
	for _, bad := range []string{"", ":12", "server.tesl:", "server.tesl:x", "server.tesl:0", "server.tesl:-1"} {
		if _, _, err := parseBreakpoint(bad); err == nil {
			t.Fatalf("parseBreakpoint(%q) accepted a malformed spec", bad)
		}
	}
}

func TestProjectEndpointPrefersSocketThenPortFile(t *testing.T) {
	project := t.TempDir()
	stuff := filepath.Join(project, ".tesl-stuff")
	if _, err := projectEndpoint(project); err == nil {
		t.Fatal("empty project must not resolve an endpoint")
	}
	if err := os.MkdirAll(stuff, 0o755); err != nil {
		t.Fatal(err)
	}
	port := filepath.Join(stuff, "debug.port")
	if err := os.WriteFile(port, []byte("51723\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// A port file without its token file is an incomplete TCP endpoint: the
	// runtime always writes both, so refusing here beats a confusing "unauthorized".
	if _, err := projectEndpoint(project); err == nil || !strings.Contains(err.Error(), "debug.token") {
		t.Fatalf("port without token = %v", err)
	}
	token := strings.Repeat("ab", 32)
	if err := os.WriteFile(filepath.Join(stuff, "debug.token"), []byte(token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	endpoint, err := projectEndpoint(project)
	if err != nil || endpoint.Socket != "" || endpoint.Address != "127.0.0.1:51723" || endpoint.Token != token {
		t.Fatalf("port discovery = %#v,%v", endpoint, err)
	}
	socketPath := filepath.Join(stuff, "debug.sock")
	if err := os.WriteFile(socketPath, []byte(""), 0o600); err != nil {
		t.Fatal(err)
	}
	endpoint, err = projectEndpoint(project)
	if err != nil || endpoint.Socket != socketPath || endpoint.Address != "" || endpoint.Token != "" {
		t.Fatalf("socket preference = %#v,%v", endpoint, err)
	}
}

// The TCP chain end to end: the runtime publishes debug.port + debug.token, the
// tool discovers both from -project and the handshake is accepted; an explicit
// -tcp without the token is refused by the endpoint.
func TestRunDiscoversTCPPortAndTokenFromProject(t *testing.T) {
	project := t.TempDir()
	t.Setenv("TESL_DEBUG", "")
	t.Setenv("TESL_DEBUG_SOCKET", "")
	t.Setenv("TESL_DEBUG_TOKEN", "")
	t.Setenv("TESL_DEBUG_PORT", "0")
	t.Setenv("TESL_DEBUG_ROOT", project)
	server, err := teslrt.StartDebugControlFromEnvironment()
	if err != nil {
		t.Fatal(err)
	}
	if server == nil {
		t.Fatal("TESL_DEBUG_PORT did not start a control server")
	}
	t.Cleanup(func() { _ = server.Close() })
	stdout := &strings.Builder{}
	if code := run([]string{"-project", project, "-operation", "ping"}, strings.NewReader(""), stdout); code != 0 {
		t.Fatalf("ping via project discovery exit = %d", code)
	}
	if response := decode(t, stdout.String()); response["ok"] != true {
		t.Fatalf("ping response = %#v", response)
	}
	if code := run([]string{"-tcp", server.Endpoint(), "-operation", "ping"}, strings.NewReader(""), &strings.Builder{}); code == 0 {
		t.Fatal("explicit -tcp without -token must be refused by the endpoint")
	}
	stdout.Reset()
	if code := run([]string{"-tcp", server.Endpoint(), "-token", server.Token(), "-operation", "ping"}, strings.NewReader(""), stdout); code != 0 {
		t.Fatalf("ping with explicit token exit = %d", code)
	}
}

func TestRunPingAgainstLiveServer(t *testing.T) {
	_, path := startControl(t)
	stdout := &strings.Builder{}
	code := run([]string{"-socket", path, "-operation", "ping"}, strings.NewReader(""), stdout)
	if code != 0 {
		t.Fatalf("exit = %d", code)
	}
	response := decode(t, stdout.String())
	if response["ok"] != true || response["version"] != float64(2) {
		t.Fatalf("ping response = %#v", response)
	}
}

// The quiet-timeout contract: `--once` against a live server whose breakpoints
// never fire ANSWERS with stopped:false (exit 0) instead of hanging or failing.
func TestRunOnceTimesOutWithAnAnswerNotAHang(t *testing.T) {
	_, path := startControl(t)
	started := time.Now()
	stdout := &strings.Builder{}
	code := run([]string{"-socket", path, "-operation", "once", "-timeout-ms", "150",
		"-break-at", "main.tesl:10"}, strings.NewReader(""), stdout)
	if code != 0 {
		t.Fatalf("exit = %d", code)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("once took %v — the timeout did not bound it", elapsed)
	}
	response := decode(t, stdout.String())
	if response["stopped"] != false || response["reason"] != "breakpoint-not-hit" {
		t.Fatalf("timeout response = %#v", response)
	}
}

// The hit path: arm via --break-at, drive a Checkpoint through the debugger,
// and confirm the tool reports the paused snapshot (locals + source line) and
// continues the program on its way out.
func TestRunOnceStopsReportsAndContinues(t *testing.T) {
	debugger, path := startControl(t)
	go func() {
		time.Sleep(50 * time.Millisecond)
		debugger.Checkpoint(teslrt.DebugFrame{
			Location: teslrt.SourceLocation{File: "worker.tesl", Line: 9},
			Locals:   []teslrt.DebugLocal{{Name: "n", Type: "Int", Value: teslrt.DebugValue{Display: "3"}}},
		})
	}()
	stdout := &strings.Builder{}
	code := run([]string{"-socket", path, "-operation", "once", "-timeout-ms", "10000",
		"-break-at", "worker.tesl:9"}, strings.NewReader(""), stdout)
	if code != 0 {
		t.Fatalf("exit = %d", code)
	}
	response := decode(t, stdout.String())
	if response["stopped"] != true {
		t.Fatalf("stop response = %#v", response)
	}
	if source, ok := response["source"].(map[string]any); !ok ||
		source["file"] != "worker.tesl" || source["line"] != float64(9) {
		t.Fatalf("source = %#v", response["source"])
	}
	locals, ok := response["locals"].([]any)
	if !ok || len(locals) != 1 {
		t.Fatalf("locals = %#v", response["locals"])
	}
	first := locals[0].(map[string]any)
	if first["name"] != "n" || first["value"] != "3" {
		t.Fatalf("local = %#v", first)
	}
}

// NDJSON streaming: each stdin line gets exactly one stdout line, malformed
// lines get an error object without killing the session, an unsupported
// command answers instead of crashing, and EOF ends the bridge cleanly.
func TestBridgeStreamsOneResponsePerLineAndSurvivesBadLines(t *testing.T) {
	_, path := startControl(t)
	input := strings.Join([]string{
		`{"command":"ping"}`,
		`{not json`,
		`{"command":"teleport"}`,
		`{"command":"set-breakpoints","breakpoints":[{"id":"b1","file":"m.tesl","line":4}]}`,
		`{"command":"clear-breakpoints"}`,
		`{"command":"snapshot"}`,
	}, "\n") + "\n"
	stdout := &strings.Builder{}
	code := run([]string{"-socket", path, "-operation", "bridge"}, strings.NewReader(input), stdout)
	if code != 0 {
		t.Fatalf("exit = %d", code)
	}
	scanner := bufio.NewScanner(strings.NewReader(stdout.String()))
	lines := 0
	for scanner.Scan() {
		lines++
		response := decode(t, scanner.Text())
		switch lines {
		case 1:
			if response["ok"] != true {
				t.Fatalf("line 1 (ping) = %#v", response)
			}
		case 2:
			if response["error"] == nil {
				t.Fatalf("line 2 (malformed) = %#v — expected an error object", response)
			}
		case 3:
			if !strings.Contains(response["error"].(string), "unsupported command") {
				t.Fatalf("line 3 (unknown) = %#v", response)
			}
		case 4:
			if response["error"] != "" {
				t.Fatalf("line 4 (set-breakpoints) = %#v", response)
			}
		case 5:
			if response["ok"] != true {
				t.Fatalf("line 5 (clear) = %#v", response)
			}
		case 6:
			if response["stopped"] != false || response["version"] != float64(2) {
				t.Fatalf("line 6 (snapshot, unpaused) = %#v", response)
			}
		}
	}
	if lines != 6 {
		t.Fatalf("bridge streamed %d responses for 6 requests", lines)
	}
}

func TestBridgeDetachEndsTheSessionAndServerSurvivesForReArm(t *testing.T) {
	debugger, path := startControl(t)
	// Session one: set a breakpoint, then detach through the bridge.
	stdout := &strings.Builder{}
	code := run([]string{"-socket", path, "-operation", "bridge"},
		strings.NewReader(`{"command":"set-breakpoints","breakpoints":[{"id":"b1","file":"m.tesl","line":4}]}
{"command":"detach"}`+"\n"), stdout)
	if code != 0 {
		t.Fatalf("session one exit = %d", code)
	}
	responses := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	if len(responses) != 2 || decode(t, responses[1])["detached"] != true {
		t.Fatalf("detach responses = %#v", responses)
	}
	// Give the server's connection-cleanup goroutine a beat to detach the
	// debugger before session two connects.
	time.Sleep(200 * time.Millisecond)
	// A lost client must leave nothing paused AND leave the server willing to
	// accept a fresh session that can re-arm the same breakpoint.
	stdout2 := &strings.Builder{}
	code = run([]string{"-socket", path, "-operation", "bridge"},
		strings.NewReader(`{"command":"set-breakpoints","breakpoints":[{"id":"b2","file":"m.tesl","line":4}]}
{"command":"ping"}`+"\n"), stdout2)
	if code != 0 {
		t.Fatalf("re-arm session exit = %d", code)
	}
	replies := strings.Split(strings.TrimSpace(stdout2.String()), "\n")
	if len(replies) < 2 {
		t.Fatalf("re-arm replies = %#v", replies)
	}
	setResult := decode(t, replies[0])
	if setResult["error"] != "" {
		t.Fatalf("re-arm set-breakpoints = %#v", setResult)
	}
	results := setResult["result"].([]any)
	if len(results) != 1 {
		t.Fatalf("re-arm results = %#v", results)
	}
	if verified := results[0].(map[string]any)["Verified"]; verified != true {
		t.Fatalf("re-armed breakpoint not verified: %#v", results[0])
	}
	if decode(t, replies[1])["ok"] != true {
		t.Fatal("ping after re-arm failed")
	}
	_ = debugger
}

func TestArgumentValidationFailsFast(t *testing.T) {
	cases := [][]string{
		{},                                    // no endpoint at all
		{"-socket", "/x", "-tcp", "h:1"},      // mutually exclusive endpoints
		{"-socket", "/x", "-timeout-ms", "0"}, // non-positive timeout
		{"-socket", "/x", "-operation", "reboot"},                      // unknown operation
		{"-socket", "/x", "-operation", "once", "-break-at", "noline"}, // bad spec
	}
	for _, arguments := range cases {
		stdout := &strings.Builder{}
		if code := run(arguments, strings.NewReader(""), stdout); code == 0 {
			t.Fatalf("arguments %v should fail", arguments)
		} else if stdout.Len() != 0 {
			t.Fatalf("failed run wrote to stdout: %q", stdout.String())
		}
	}
}

func TestDialRefusesMissingSocketQuickly(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "absent.sock")
	started := time.Now()
	if _, err := dial(missing, "", 500*time.Millisecond); err == nil {
		t.Fatal("dial to missing socket must fail")
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("dial took %v for a missing file", elapsed)
	}
}
