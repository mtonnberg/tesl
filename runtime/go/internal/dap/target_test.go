package dap

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	"tesl.dev/runtime/go/teslrt"
)

func TestProcessTargetAttachesToTCPRuntime(t *testing.T) {
	control, err := teslrt.NewDebugger().StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
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

func TestProcessTargetLaunchesAndReportsLifecycle(t *testing.T) {
	arguments, err := json.Marshal(processLaunchArguments{
		Program: os.Args[0], Cwd: t.TempDir(),
		Args: []string{"-test.run=TestProcessTargetLaunchHelper", "-test.v"},
		Env:  map[string]string{"TESL_DAP_TARGET_HELPER": "1"},
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
	control, err := teslrt.StartDebugControlFromEnvironment()
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()
	select {}
}
