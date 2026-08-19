package dap

import (
	"encoding/json"
	"testing"

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
