package teslrt

import (
	"os"
	"sync"
	"testing"
	"time"
	"unicode/utf8"
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

func TestDebugValueBoundsAndPanicRecovery(t *testing.T) {
	value := DebugValue{Type: "Record", Display: "😀long", Children: []DebugValue{
		{Name: "a", Type: "Int", Display: "1"},
		{Name: "b", Type: "Int", Display: "2"},
	}}
	bounded := value.Bounded(1, 1, 4)
	if len(bounded.Children) != 1 || !bounded.Truncated || !utf8.ValidString(bounded.Display) {
		t.Fatalf("bounded value = %#v", bounded)
	}
	debugger := NewDebugger()
	debugger.Attach(func(event DebugEvent) { debugger.Continue() })
	debugger.Pause()
	debugger.Checkpoint(DebugFrame{Location: SourceLocation{File: "x", Line: 1}, Locals: []DebugLocal{{
		Name: "bad", Accessor: func() DebugValue { panic("hostile accessor") },
	}}})
	frame, _ := debugger.Snapshot()
	if len(frame.Locals) != 1 || frame.Locals[0].Value.Display != "[unavailable]" {
		t.Fatalf("panic recovery frame = %#v", frame)
	}
}

func TestDebuggerConcurrentCheckpointsDoNotDeadlock(t *testing.T) {
	debugger := NewDebugger()
	debugger.SetBreakpoints([]DebugBreakpoint{{File: "stress.tesl", Line: 7}})
	stops := make(chan struct{}, 32)
	detach := debugger.Attach(func(event DebugEvent) {
		stops <- struct{}{}
		debugger.Continue()
	})
	defer detach()
	var wait sync.WaitGroup
	for worker := 0; worker < 8; worker++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for iteration := 0; iteration < 4; iteration++ {
				debugger.Checkpoint(DebugFrame{Location: SourceLocation{File: "stress.tesl", Line: 7}})
			}
		}()
	}
	done := make(chan struct{})
	go func() { wait.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("concurrent checkpoints deadlocked")
	}
	if len(stops) == 0 {
		t.Fatal("concurrent checkpoints never stopped")
	}
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

func TestDebuggerSnapshotsNestedScopes(t *testing.T) {
	debugger := NewDebugger()
	seen := make(chan DebugEvent, 1)
	debugger.Attach(func(event DebugEvent) { seen <- event })
	debugger.SetBreakpoints([]DebugBreakpoint{{File: "main.tesl", Line: 9}})
	outer := debugger.Enter(DebugFrame{ID: "outer", Function: "outer"})
	inner := debugger.Enter(DebugFrame{ID: "inner", Function: "inner"})
	done := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{ID: "inner", Function: "inner", Location: SourceLocation{File: "main.tesl", Line: 9}})
		close(done)
	}()
	event := <-seen
	if len(event.Stack) != 2 || event.Stack[0].ID != "outer" || event.Stack[1].ID != "inner" {
		t.Fatalf("stack = %#v", event.Stack)
	}
	if event.Stack[1].Location.Line != 9 || event.Stack[1].Depth != 1 {
		t.Fatalf("updated stack frame = %#v", event.Stack[1])
	}
	debugger.Continue()
	inner.Leave()
	outer.Leave()
	<-done
	if stack := debugger.StackSnapshot(); len(stack) != 0 {
		t.Fatalf("stack after leave = %#v", stack)
	}
}

func TestDebuggerSnapshotKeepsCheckpointPositionAndVisibleLocals(t *testing.T) {
	debugger := NewDebugger()
	seen := make(chan DebugEvent, 1)
	debugger.Attach(func(event DebugEvent) { seen <- event })
	debugger.SetBreakpoints([]DebugBreakpoint{{File: "tests.tesl", Line: 23}})
	done := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{
			Version:  DebugABIVersion,
			ID:       "api-statement",
			Function: "TestTeslApi0",
			Test:     "api statements",
			Location: SourceLocation{File: "tests.tesl", Line: 23, Column: 3},
			Locals: []DebugLocal{
				{Name: "response", Type: "ApiResponse", Accessor: func() DebugValue {
					return DebugValue{Type: "ApiResponse", Display: "status=200"}
				}},
				{Name: "attempt", Type: "Int", Accessor: func() DebugValue {
					return DebugValue{Type: "Int", Display: "1"}
				}},
			},
		})
		close(done)
	}()
	event := <-seen
	if event.Frame.Location != (SourceLocation{File: "tests.tesl", Line: 23, Column: 3}) {
		t.Fatalf("location = %#v", event.Frame.Location)
	}
	if event.Frame.Test != "api statements" || len(event.Frame.Locals) != 2 {
		t.Fatalf("frame = %#v", event.Frame)
	}
	if event.Frame.Locals[0].Name != "response" || event.Frame.Locals[0].Value.Display != "status=200" || event.Frame.Locals[0].Accessor != nil {
		t.Fatalf("visible locals = %#v", event.Frame.Locals)
	}
	debugger.Continue()
	<-done
}

// A stop whose client never resumes must not hold application goroutines
// forever: with PauseTimeout set the checkpoint auto-releases after the bound,
// and with it unset (interactive default) the wait stays unbounded.
func TestDebuggerPauseTimeoutAutoResumesAndZeroWaits(t *testing.T) {
	debugger := NewDebugger()
	debugger.PauseTimeout = 80 * time.Millisecond
	seen := make(chan DebugEvent, 1)
	debugger.Attach(func(event DebugEvent) { seen <- event })
	debugger.SetBreakpoints([]DebugBreakpoint{{ID: "bp", File: "m.tesl", Line: 3}})
	released := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{Location: SourceLocation{File: "m.tesl", Line: 3}})
		close(released)
	}()
	event := <-seen
	if event.Kind != "stopped" {
		t.Fatalf("event = %#v", event)
	}
	select {
	case <-released:
	case <-time.After(5 * time.Second):
		t.Fatal("PauseTimeout did not release a stopped checkpoint")
	}
	if _, paused := debugger.Snapshot(); paused {
		t.Fatal("debugger still reports paused after auto-resume")
	}

	// Zero (default): an interactive session waits indefinitely — Continue is
	// the only way out. Prove the wait survives well past the timeout above.
	plain := NewDebugger()
	plain.Attach(func(event DebugEvent) { seen <- event })
	plain.SetBreakpoints([]DebugBreakpoint{{ID: "bp", File: "m.tesl", Line: 3}})
	held := make(chan struct{})
	go func() {
		plain.Checkpoint(DebugFrame{Location: SourceLocation{File: "m.tesl", Line: 3}})
		close(held)
	}()
	<-seen
	select {
	case <-held:
		t.Fatal("checkpoint released without Continue despite zero timeout")
	case <-time.After(250 * time.Millisecond):
	}
	plain.Continue()
	<-held
}

func TestApplyEnvPauseTimeoutParsesMillisOnly(t *testing.T) {
	debugger := NewDebugger()
	t.Setenv("TESL_DEBUG_PAUSE_TIMEOUT_MS", "1500")
	applyEnvPauseTimeout(debugger)
	if debugger.PauseTimeout != 1500*time.Millisecond {
		t.Fatalf("PauseTimeout = %v", debugger.PauseTimeout)
	}
	for _, bad := range []string{"", "abc", "-5", "0"} {
		if bad == "" {
			os.Unsetenv("TESL_DEBUG_PAUSE_TIMEOUT_MS")
		} else {
			t.Setenv("TESL_DEBUG_PAUSE_TIMEOUT_MS", bad)
		}
		fresh := NewDebugger()
		fresh.PauseTimeout = 42 * time.Millisecond
		applyEnvPauseTimeout(fresh)
		if fresh.PauseTimeout != 42*time.Millisecond {
			t.Fatalf("input %q changed PauseTimeout to %v", bad, fresh.PauseTimeout)
		}
	}
}
