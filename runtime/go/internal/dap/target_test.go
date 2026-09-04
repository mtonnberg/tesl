package dap

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/teslrt"
)

func TestProcessTargetAttachesToTCPRuntime(t *testing.T) {
	control, err := teslrt.NewDebugger().StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = control.Close() }()
	target := NewProcessTarget()
	// A TCP endpoint refuses a handshake without its token — including the
	// attach adapter's own.
	if _, err := target.AttachBackend(json.RawMessage(`{"address":"` + control.Endpoint() + `"}`)); err == nil {
		t.Fatal("attach without token must be refused")
	}
	backend, err := target.AttachBackend(json.RawMessage(`{"address":"` + control.Endpoint() + `","token":"` + control.Token() + `"}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := backend.(*ControlClient); !ok {
		t.Fatalf("backend = %T, want *ControlClient", backend)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
}

// The editor's `port` + default `project` configuration: the token is read from
// the project's token file when the attach arguments carry none.
func TestProcessTargetAttachByPortReadsProjectToken(t *testing.T) {
	control, err := teslrt.NewDebugger().StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = control.Close() }()
	project := t.TempDir()
	stuff := filepath.Join(project, ".tesl-stuff")
	if err := os.MkdirAll(stuff, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stuff, teslrt.DebugTokenFile), []byte(control.Token()+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	target := NewProcessTarget()
	arguments, _ := json.Marshal(processAttachArguments{Project: project, Port: control.Port()})
	if _, err := target.AttachBackend(arguments); err != nil {
		t.Fatal(err)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestDiscoverProjectEndpointReadsTokenBesidePort(t *testing.T) {
	project := t.TempDir()
	stuff := filepath.Join(project, ".tesl-stuff")
	if err := os.MkdirAll(stuff, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stuff, teslrt.DebugPortFile), []byte("4321\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := DiscoverProjectEndpoint(project); err == nil || !strings.Contains(err.Error(), teslrt.DebugTokenFile) {
		t.Fatalf("missing token file error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(stuff, teslrt.DebugTokenFile), []byte("not-hex\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := DiscoverProjectEndpoint(project); err == nil {
		t.Fatal("malformed token accepted")
	}
	token, err := teslrt.NewDebugToken()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stuff, teslrt.DebugTokenFile), []byte("  "+token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	endpoint, err := DiscoverProjectEndpoint(project)
	if err != nil || endpoint.Address != "127.0.0.1:4321" || endpoint.Token != token || endpoint.Socket != "" {
		t.Fatalf("endpoint = %#v, %v", endpoint, err)
	}
}

// A TCP launch mints the token in the launcher and passes it to the child
// through the environment, so the launcher can dial as soon as the port opens.
func TestLaunchEndpointTCPMintsTokenForChild(t *testing.T) {
	endpoint, err := launchEndpoint(processLaunchArguments{DebugPort: 4567}, "/tmp/tesl-project")
	if err != nil {
		t.Fatal(err)
	}
	if endpoint.address != "127.0.0.1:4567" || endpoint.token == "" {
		t.Fatalf("endpoint = %#v", endpoint)
	}
	if err := teslrt.ValidateDebugToken(endpoint.token); err != nil {
		t.Fatal(err)
	}
	if endpoint.environment[teslrt.DebugTokenEnv] != endpoint.token || endpoint.environment["TESL_DEBUG_PORT"] != "4567" {
		t.Fatalf("environment = %#v", endpoint.environment)
	}
	other, err := launchEndpoint(processLaunchArguments{DebugAddress: "127.0.0.1:4568"}, "/tmp/tesl-project")
	if err != nil || other.address != "127.0.0.1:4568" || other.token == endpoint.token {
		t.Fatalf("address endpoint = %#v, %v", other, err)
	}
}

func TestLaunchEndpointDefaultsToPrivateUnixSocket(t *testing.T) {
	longTemp := filepath.Join(t.TempDir(), strings.Repeat("deep-", 24))
	if err := os.MkdirAll(longTemp, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", longTemp)
	endpoint, err := launchEndpoint(processLaunchArguments{}, filepath.Join(longTemp, "workspace"))
	if err != nil {
		t.Fatal(err)
	}
	defer endpoint.cleanup()
	if endpoint.socket == "" || len([]byte(endpoint.socket)) > 100 || strings.HasPrefix(endpoint.socket, longTemp) || endpoint.environment["TESL_DEBUG"] != "1" {
		t.Fatalf("endpoint = %#v", endpoint)
	}
	info, err := os.Stat(filepath.Dir(endpoint.socket))
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("private endpoint directory = %v, %v", info, err)
	}
}

func TestLaunchEndpointRejectsConflictingPorts(t *testing.T) {
	_, err := launchEndpoint(processLaunchArguments{DebugAddress: "127.0.0.1:4000", DebugPort: 4001}, ".")
	if err == nil {
		t.Fatal("accepted conflicting debug endpoints")
	}
}

func TestDialProjectEndpointRejectsMissingEndpoint(t *testing.T) {
	_, err := dialProjectEndpoint(t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "no debug endpoint") {
		t.Fatalf("error = %v", err)
	}
}

func generatedGoTestFixture(t *testing.T) (string, string, string) {
	_, testFile, _, _ := runtime.Caller(0)
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(testFile), "../../../.."))
	compiler := filepath.Join(repoRoot, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("compiler build unavailable")
	}
	source := filepath.Join(repoRoot, "example", "learn", "lesson14-test-blocks.tesl")
	if _, err := os.Stat(source); err != nil {
		t.Skip("test source unavailable")
	}
	t.Setenv("TESL_REPO_ROOT", repoRoot)
	return repoRoot, compiler, source
}

func TestPrepareProgramBuildsGeneratedGoTest(t *testing.T) {
	repoRoot, compiler, source := generatedGoTestFixture(t)
	target := NewProcessTarget()
	program, args, cleanup, err := target.prepareProgram(processLaunchArguments{
		Program: source, Compiler: compiler, Mode: "test", OutDir: filepath.Join(t.TempDir(), "generated"),
	}, repoRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	if len(args) != 0 {
		t.Fatalf("generated test args = %#v, want none", args)
	}
	if _, err := os.Stat(program); err != nil {
		t.Fatalf("generated test binary: %v", err)
	}
}

func TestProcessTargetLaunchesGeneratedGoTest(t *testing.T) {
	repoRoot, compiler, source := generatedGoTestFixture(t)
	arguments, err := json.Marshal(processLaunchArguments{
		Program: source, Compiler: compiler, Cwd: repoRoot, Mode: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	target := NewProcessTarget()
	backend, err := target.LaunchBackend(arguments)
	if err != nil {
		t.Fatal(err)
	}
	client, ok := backend.(*ControlClient)
	if !ok {
		t.Fatalf("backend = %T, want *ControlClient", backend)
	}
	stopped := make(chan struct{}, 1)
	detach := client.Attach(func(event teslrt.DebugEvent) {
		if event.Kind == "stopped" {
			select {
			case stopped <- struct{}{}:
			default:
			}
		}
	})
	defer detach()
	// Locate the `test "factorial"` header line dynamically: the emitter puts a
	// checkpoint on that exact source line, and a hardcoded number drifts every
	// time the lesson's comment block gains or loses a line (it already did once).
	contents, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	breakpointLine := 0
	for index, text := range strings.Split(string(contents), "\n") {
		if strings.Contains(text, `test "factorial"`) {
			breakpointLine = index + 1
			break
		}
	}
	if breakpointLine == 0 {
		t.Fatal("fixture lost its factorial test header")
	}
	if _, err := client.SetBreakpointSpecs([]teslrt.DebugBreakpointSpec{{ID: "factorial", File: source, Line: breakpointLine}}); err != nil {
		t.Fatal(err)
	}
	if err := client.ConfigurationDone(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("generated test did not hit launch breakpoint")
	}
	snapshot, err := client.SnapshotState()
	if err != nil || !snapshot.Paused {
		t.Fatalf("launch snapshot = %#v, %v", snapshot, err)
	}
	if err := client.Continue(); err != nil {
		t.Fatal(err)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestProcessTargetGeneratedServerHandlerBreakpointDoesNotWaitForMain(t *testing.T) {
	repoRoot, compiler, _ := generatedGoTestFixture(t)
	templatePath := filepath.Join(repoRoot, "example", "learn", "lesson17-telemetry.tesl")
	contents, err := os.ReadFile(templatePath)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	text := strings.Replace(string(contents), "port: 8086", fmt.Sprintf("port: %d", port), 1)
	source := filepath.Join(t.TempDir(), "lesson17-telemetry.tesl")
	if err := os.WriteFile(source, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	breakpointLine := 0
	for index, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "handler get healthCheck") {
			breakpointLine = index + 1
			break
		}
	}
	if breakpointLine == 0 {
		t.Fatal("live server fixture lost its health handler")
	}

	arguments, err := json.Marshal(processLaunchArguments{Program: source, Compiler: compiler, Cwd: repoRoot})
	if err != nil {
		t.Fatal(err)
	}
	target := NewProcessTarget()
	backend, err := target.LaunchBackend(arguments)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = target.Close() }()
	client := backend.(*ControlClient)
	stopped := make(chan teslrt.DebugEvent, 1)
	detach := client.Attach(func(event teslrt.DebugEvent) {
		if event.Kind == "stopped" {
			stopped <- event
		}
	})
	defer detach()
	if _, err := client.SetBreakpointSpecs([]teslrt.DebugBreakpointSpec{{ID: "health", File: source, Line: breakpointLine}}); err != nil {
		t.Fatal(err)
	}
	if err := client.ConfigurationDone(); err != nil {
		t.Fatal(err)
	}

	response := make(chan error, 1)
	go func() {
		httpClient := &http.Client{Timeout: 10 * time.Second}
		deadline := time.Now().Add(5 * time.Second)
		for {
			result, requestErr := httpClient.Get(fmt.Sprintf("http://127.0.0.1:%d/health", port))
			if requestErr == nil {
				_ = result.Body.Close()
				if result.StatusCode != http.StatusOK {
					requestErr = fmt.Errorf("health response status %d", result.StatusCode)
				}
				response <- requestErr
				return
			}
			if time.Now().After(deadline) {
				response <- requestErr
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
	}()
	select {
	case event := <-stopped:
		if event.Frame.Function != "healthCheck" {
			t.Fatalf("stopped in %q, want healthCheck", event.Frame.Function)
		}
	case err := <-response:
		t.Fatalf("request completed before handler breakpoint: %v", err)
	case <-time.After(8 * time.Second):
		t.Fatal("live handler breakpoint waited for the quiescent main server scope")
	}
	if snapshot, err := client.SnapshotState(); err != nil || !snapshot.Paused {
		t.Fatalf("live server snapshot = %#v, %v", snapshot, err)
	}
	if err := client.Continue(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-response:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("health request did not finish after continue")
	}
}

func TestProcessTargetLaunchesAndReportsLifecycle(t *testing.T) {
	if len(os.Args) == 0 {
		t.Fatal("test executable path unavailable")
	}
	arguments, err := json.Marshal(processLaunchArguments{
		Program: os.Args[0], Cwd: t.TempDir(),
		Args:     []string{"-test.run=TestProcessTargetLaunchHelper", "-test.v"},
		Env:      map[string]string{"TESL_DAP_TARGET_HELPER": "1"},
		TestName: "named test", TestKind: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	target := NewProcessTarget()
	events := make(chan TargetEvent, 4)
	target.SetEventListener(func(event TargetEvent) { events <- event })
	backend, err := target.LaunchBackend(arguments)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := backend.(*ControlClient); !ok {
		t.Fatalf("backend = %T, want *ControlClient", backend)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}

	seen := map[string]bool{}
	deadline := time.After(2 * time.Second)
	for !seen["exited"] || !seen["terminated"] {
		select {
		case event := <-events:
			seen[event.Event] = true
		case <-deadline:
			t.Fatalf("lifecycle events = %#v", seen)
		}
	}
	if !seen["exited"] || !seen["terminated"] {
		t.Fatalf("lifecycle events = %#v", seen)
	}
}

func TestProcessTargetLaunchHelper(t *testing.T) {
	if os.Getenv("TESL_DAP_TARGET_HELPER") != "1" {
		return
	}
	if os.Getenv("TESL_TEST_NAME") != "named test" || os.Getenv("TESL_TEST_KIND") != "test" {
		t.Fatalf("test selection environment = %q/%q", os.Getenv("TESL_TEST_NAME"), os.Getenv("TESL_TEST_KIND"))
	}
	control, err := teslrt.StartDebugControlFromEnvironment()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = control.Close() }()
	select {}
}
