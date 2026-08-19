package teslrt

import (
	"testing"
	"time"
)

func TestDebuggerIsNoOpUntilAttached(t *testing.T) {
	debugger := NewDebugger()
	debugger.Checkpoint(DebugFrame{Version: DebugABIVersion, ID: "fn"})
	seen := make(chan DebugEvent, 1)
	detach := debugger.Attach(func(event DebugEvent) { seen <- event })
	debugger.SetBreakpoints([]DebugBreakpoint{{File: "main.tesl", Line: 1}})
	done := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{Version: DebugABIVersion, ID: "fn", Location: SourceLocation{File: "main.tesl", Line: 1}, Locals: []DebugLocal{{
			Name: "answer", Type: "Int", Accessor: func() DebugValue {
				return DebugValue{Type: "Int", Display: "42"}
			},
		}}})
		close(done)
	}()
	event := <-seen
	if event.Frame.ID != "fn" || event.Frame.Version != DebugABIVersion {
		t.Fatalf("event = %#v", event)
	}
	if event.Frame.Locals[0].Value.Display != "42" || event.Frame.Locals[0].Accessor != nil {
		t.Fatalf("locals = %#v", event.Frame.Locals)
	}
	detach()
	<-done
	debugger.Checkpoint(DebugFrame{Version: DebugABIVersion, ID: "fn"})
}

func TestDebuggerStopsAtBreakpointAndResumes(t *testing.T) {
	debugger := NewDebugger()
	seen := make(chan DebugEvent, 1)
	debugger.Attach(func(event DebugEvent) { seen <- event })
	results := debugger.SetBreakpoints([]DebugBreakpoint{{ID: "line", File: "main.tesl", Line: 7}})
	if len(results) != 1 || !results[0].Verified {
		t.Fatalf("breakpoint results = %#v", results)
	}
	done := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{Version: DebugABIVersion, ID: "frame", Location: SourceLocation{File: "main.tesl", Line: 7}})
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("checkpoint did not pause")
	case event := <-seen:
		if event.Frame.Location.Line != 7 {
			t.Fatalf("event = %#v", event)
		}
	}
	if _, paused := debugger.Snapshot(); !paused {
		t.Fatal("Snapshot() reports running while stopped")
	}
	debugger.Continue()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Continue() did not release checkpoint")
	}
}

func TestDebuggerHonorsConditionAndHitCount(t *testing.T) {
	debugger := NewDebugger()
	seen := make(chan DebugEvent, 1)
	debugger.Attach(func(event DebugEvent) { seen <- event })
	debugger.SetBreakpoints([]DebugBreakpoint{{
		File: "main.tesl", Line: 3,
		Condition:    func(frame DebugFrame) bool { return frame.Depth == 2 },
		HitCondition: func(hit int) bool { return hit == 2 },
	}})
	for hit := 1; hit <= 2; hit++ {
		done := make(chan struct{})
		go func(depth int) {
			debugger.Checkpoint(DebugFrame{Location: SourceLocation{File: "main.tesl", Line: 3}, Depth: depth})
			close(done)
		}(2)
		if hit == 1 {
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("first conditional hit unexpectedly paused")
			}
		} else {
			<-seen
			debugger.Continue()
			<-done
		}
	}
}

func TestDebuggerStepModesStopAtNextFrame(t *testing.T) {
	debugger := NewDebugger()
	seen := make(chan DebugEvent, 2)
	detach := debugger.Attach(func(event DebugEvent) { seen <- event })
	debugger.SetBreakpoints([]DebugBreakpoint{{File: "main.tesl", Line: 1}})
	done := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{Function: "outer", Location: SourceLocation{File: "main.tesl", Line: 1}})
		close(done)
	}()
	<-seen
	if !debugger.Step(DebugStepIn) {
		t.Fatal("StepIn() rejected stopped debugger")
	}
	nextDone := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{Function: "inner", Location: SourceLocation{File: "main.tesl", Line: 2}})
		close(nextDone)
	}()
	event := <-seen
	if event.Frame.Function != "inner" {
		t.Fatalf("step event = %#v", event)
	}
	debugger.Continue()
	detach()
	<-done
	<-nextDone
}
