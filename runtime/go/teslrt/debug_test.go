package teslrt

import (
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

func TestDebuggerBreakpointsMatchRelativeAndAbsoluteSourcePaths(t *testing.T) {
	debugger := NewDebugger()
	seen := make(chan DebugEvent, 1)
	detach := debugger.Attach(func(event DebugEvent) { seen <- event })
	defer detach()
	workingDirectory, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	absoluteFile := filepath.Join(workingDirectory, "relative-source.tesl")
	debugger.SetBreakpoints([]DebugBreakpoint{{File: absoluteFile, Line: 7}})
	done := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{Location: SourceLocation{File: "relative-source.tesl", Line: 7}})
		close(done)
	}()
	select {
	case event := <-seen:
		if event.Frame.Location.File != "relative-source.tesl" {
			t.Fatalf("event = %#v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("relative source breakpoint did not stop")
	}
	debugger.Continue()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("checkpoint did not resume")
	}
}

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

func TestRunningDebuggerSnapshotDoesNotExposeExecutionState(t *testing.T) {
	debugger := NewDebugger()
	SetDebugSQLCapture(&DebugSQLCapture{SQL: "select request_secret"})
	defer ClearDebugSQLCapture()
	snapshot := debugger.SnapshotState()
	if snapshot.Paused || snapshot.Frame.ID != "" || len(snapshot.Stack) != 0 || snapshot.Runtime.SQL != nil {
		t.Fatalf("running snapshot exposed execution state: %#v", snapshot)
	}
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
	var frame DebugFrame
	debugger.Attach(func(event DebugEvent) {
		// The stop frame is readable while stopped; Continue drops it (request
		// state must not outlive the stop), so capture it here.
		frame, _ = debugger.Snapshot()
		debugger.Continue()
	})
	debugger.Pause()
	debugger.Checkpoint(DebugFrame{Location: SourceLocation{File: "x", Line: 1}, Locals: []DebugLocal{{
		Name: "bad", Accessor: func() DebugValue { panic("hostile accessor") },
	}}})
	if len(frame.Locals) != 1 || frame.Locals[0].Value.Display != "[unavailable]" {
		t.Fatalf("panic recovery frame = %#v", frame)
	}
	if after, paused := debugger.Snapshot(); paused || len(after.Locals) != 0 {
		t.Fatalf("frame retained after continue = %#v", after)
	}
}

func TestDebugValueOfExposesApiResponseAndJSONFields(t *testing.T) {
	value := DebugValueOf(ApiResponse{
		Status: FromInt64(200),
		Body:   JsonOf(map[string]any{"message": "hello from api-test"}),
	}, "echoResp")
	if len(value.Children) != 3 {
		t.Fatalf("api response children = %#v", value.Children)
	}
	if value.Children[0].Name != "status" || value.Children[1].Name != "body" || value.Children[2].Name != "headers" {
		t.Fatalf("api response fields = %#v", value.Children)
	}
	body := value.Children[1]
	if len(body.Children) != 1 || body.Children[0].Name != "message" || body.Children[0].Type != "String" || body.Children[0].EvaluateName != "echoResp.body.message" {
		t.Fatalf("JSON body tree = %#v", body)
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
	done := make(chan struct{})
	go func() {
		outer := debugger.Enter(DebugFrame{ID: "outer", Function: "outer"})
		defer outer.Leave()
		inner := debugger.Enter(DebugFrame{ID: "inner", Function: "inner"})
		defer inner.Leave()
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
	<-done
	if stack := debugger.StackSnapshot(); len(stack) != 0 {
		t.Fatalf("stack after leave = %#v", stack)
	}
}

func TestDebuggerStopBarrierAndStacksAreExecutionIsolated(t *testing.T) {
	debugger := NewDebugger()
	stopped := make(chan DebugEvent, 1)
	debugger.Attach(func(event DebugEvent) { stopped <- event })
	debugger.SetBreakpoints([]DebugBreakpoint{{File: "main.tesl", Line: 10}})

	workerEntered := make(chan struct{})
	workerBoundary := make(chan struct{})
	workerDone := make(chan struct{})
	var progress atomic.Int64
	go func() {
		scope := debugger.Enter(DebugFrame{ID: "worker", Function: "worker"})
		defer scope.Leave()
		SetDebugSQLCapture(&DebugSQLCapture{SQL: "select worker"})
		close(workerEntered)
		<-workerBoundary
		progress.Add(1)
		debugger.Checkpoint(DebugFrame{ID: "worker", Function: "worker", Location: SourceLocation{File: "worker.tesl", Line: 20}})
		progress.Add(1)
		close(workerDone)
	}()
	<-workerEntered

	requestDone := make(chan struct{})
	go func() {
		scope := debugger.Enter(DebugFrame{ID: "request", Function: "request"})
		defer scope.Leave()
		SetDebugSQLCapture(&DebugSQLCapture{SQL: "select request"})
		debugger.Checkpoint(DebugFrame{ID: "request", Function: "request", Location: SourceLocation{File: "main.tesl", Line: 10}})
		close(requestDone)
	}()

	select {
	case event := <-stopped:
		t.Fatalf("stop published before active worker reached the barrier: %#v", event)
	case <-time.After(80 * time.Millisecond):
	}
	close(workerBoundary)
	var event DebugEvent
	select {
	case event = <-stopped:
	case <-time.After(time.Second):
		t.Fatal("stop was not published after every active execution reached a boundary")
	}
	if event.Rendezvous != DebugRendezvousComplete {
		t.Fatalf("rendezvous = %q, want complete", event.Rendezvous)
	}
	if len(event.Stack) != 1 || event.Stack[0].ID != "request" {
		t.Fatalf("stopped request stack contains another execution: %#v", event.Stack)
	}
	if snapshot := debugger.SnapshotState(); snapshot.Runtime.SQL == nil || snapshot.Runtime.SQL.SQL != "select request" {
		t.Fatalf("stopped request snapshot contains another execution's SQL: %#v", snapshot.Runtime.SQL)
	}
	if progress.Load() != 1 {
		t.Fatalf("worker progressed through its checkpoint while paused: %d", progress.Load())
	}
	select {
	case <-workerDone:
		t.Fatal("worker passed the cooperative barrier before Continue")
	default:
	}
	debugger.Continue()
	select {
	case <-workerDone:
	case <-time.After(time.Second):
		t.Fatal("Continue did not release the worker execution")
	}
	<-requestDone
	if progress.Load() != 2 {
		t.Fatalf("worker did not resume after Continue: %d", progress.Load())
	}
}

func TestDebuggerPublishesPartialStopWhenExecutionCannotRendezvous(t *testing.T) {
	debugger := NewDebugger()
	debugger.rendezvousTimeout = 60 * time.Millisecond
	stopped := make(chan DebugEvent, 1)
	debugger.Attach(func(event DebugEvent) { stopped <- event })
	debugger.SetBreakpoints([]DebugBreakpoint{{File: "request.tesl", Line: 10}})

	blocked := make(chan struct{})
	blockedReady := make(chan struct{})
	blockedAtBoundary := make(chan struct{})
	blockedDone := make(chan struct{})
	go func() {
		scope := debugger.Enter(DebugFrame{ID: "blocked", Function: "blocked"})
		defer scope.Leave()
		close(blockedReady)
		<-blocked
		close(blockedAtBoundary)
		debugger.Checkpoint(DebugFrame{ID: "blocked", Location: SourceLocation{File: "blocked.tesl", Line: 20}})
		close(blockedDone)
	}()
	<-blockedReady

	triggerDone := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{ID: "request", Location: SourceLocation{File: "request.tesl", Line: 10}})
		close(triggerDone)
	}()
	var event DebugEvent
	select {
	case event = <-stopped:
	case <-time.After(time.Second):
		t.Fatal("blocked external work prevented stop publication")
	}
	if event.Rendezvous != DebugRendezvousTimedOut {
		t.Fatalf("rendezvous = %q, want timed-out", event.Rendezvous)
	}
	snapshot := debugger.SnapshotState()
	if !snapshot.Paused || snapshot.Rendezvous != DebugRendezvousTimedOut {
		t.Fatalf("partial snapshot = %#v", snapshot)
	}
	select {
	case <-triggerDone:
		t.Fatal("partial stop did not hold the triggering execution")
	default:
	}

	close(blocked)
	<-blockedAtBoundary
	select {
	case <-blockedDone:
		t.Fatal("late rendezvous passed the partial stop before Continue")
	case <-time.After(50 * time.Millisecond):
	}
	debugger.Continue()
	select {
	case <-blockedDone:
	case <-time.After(time.Second):
		t.Fatal("Continue did not release the late rendezvous")
	}
	select {
	case <-triggerDone:
	case <-time.After(time.Second):
		t.Fatal("Continue did not release the triggering execution")
	}
}

func TestDebuggerQuiescentLifecycleScopeDoesNotHoldStopBarrier(t *testing.T) {
	debugger := NewDebugger()
	stopped := make(chan DebugEvent, 1)
	debugger.Attach(func(event DebugEvent) { stopped <- event })
	debugger.SetBreakpoints([]DebugBreakpoint{{File: "handler.tesl", Line: 8}})

	lifecycleReady := make(chan struct{})
	lifecycleExit := make(chan struct{})
	lifecycleDone := make(chan struct{})
	go func() {
		scope := debugger.Enter(DebugFrame{ID: "main", Function: "main"})
		defer scope.Leave()
		quiescent := debugger.Quiesce()
		close(lifecycleReady)
		<-lifecycleExit
		quiescent.Resume()
		close(lifecycleDone)
	}()
	<-lifecycleReady

	handlerDone := make(chan struct{})
	go func() {
		scope := debugger.Enter(DebugFrame{ID: "handler", Function: "handler"})
		defer scope.Leave()
		debugger.Checkpoint(DebugFrame{ID: "handler", Function: "handler", Location: SourceLocation{File: "handler.tesl", Line: 8}})
		close(handlerDone)
	}()
	select {
	case event := <-stopped:
		if event.Frame.ID != "handler" {
			t.Fatalf("stopped event = %#v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("quiescent lifecycle scope held the handler stop barrier")
	}
	close(lifecycleExit)
	select {
	case <-lifecycleDone:
		t.Fatal("quiescent lifecycle scope resumed through an established stop")
	case <-time.After(50 * time.Millisecond):
	}
	debugger.Continue()
	<-handlerDone
	select {
	case <-lifecycleDone:
	case <-time.After(time.Second):
		t.Fatal("quiescent lifecycle scope did not resume")
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
			_ = os.Unsetenv("TESL_DEBUG_PAUSE_TIMEOUT_MS")
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
