package dap

import (
	"encoding/json"
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
	backend, err := target.AttachBackend(json.RawMessage(`{"address":"` + control.Endpoint() + `"}`))
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

func TestLaunchEndpointDefaultsToPrivateUnixSocket(t *testing.T) {
	endpoint, err := launchEndpoint(processLaunchArguments{}, "/tmp/tesl-project")
	if err != nil {
		t.Fatal(err)
	}
	if endpoint.socket != "/tmp/tesl-project/.tesl-stuff/debug.sock" || endpoint.environment["TESL_DEBUG"] != "1" {
		t.Fatalf("endpoint = %#v", endpoint)
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
