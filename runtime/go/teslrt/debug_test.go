package teslrt

import "testing"

func TestDebuggerIsNoOpUntilAttached(t *testing.T) {
	debugger := NewDebugger()
	debugger.Checkpoint(DebugFrame{Version: DebugABIVersion, ID: "fn"})
	seen := make(chan DebugEvent, 1)
	detach := debugger.Attach(func(event DebugEvent) { seen <- event })
	debugger.Checkpoint(DebugFrame{Version: DebugABIVersion, ID: "fn"})
	event := <-seen
	if event.Frame.ID != "fn" || event.Frame.Version != DebugABIVersion {
		t.Fatalf("event = %#v", event)
	}
	detach()
	debugger.Checkpoint(DebugFrame{Version: DebugABIVersion, ID: "fn"})
}
