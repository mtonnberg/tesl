package teslrt

import (
	"fmt"
	"sync"
)

// DebugABIVersion identifies the language-neutral checkpoint metadata contract.
const DebugABIVersion = 1

type SourceLocation struct {
	File   string `json:"file"`
	Line   int    `json:"line"`
	Column int    `json:"column"`
}

type DebugValue struct {
	Type     string       `json:"type"`
	Display  string       `json:"display"`
	Children []DebugValue `json:"children,omitempty"`
}

type DebugLocal struct {
	Name     string            `json:"name"`
	Type     string            `json:"type"`
	Value    DebugValue        `json:"value"`
	Accessor func() DebugValue `json:"-"`
}

// DebugFrame is emitted at a checkpoint. IDs are compiler-generated and remain stable
// across runs for the same module/function/source location.
type DebugFrame struct {
	Version  int            `json:"version"`
	ID       string         `json:"id"`
	Function string         `json:"function"`
	Location SourceLocation `json:"location"`
	Test     string         `json:"test,omitempty"`
	Depth    int            `json:"depth"`
	Locals   []DebugLocal   `json:"locals,omitempty"`
}

type DebugEvent struct {
	Kind  string       `json:"kind"`
	Frame DebugFrame   `json:"frame"`
	Stack []DebugFrame `json:"stack,omitempty"`
}

type DebugSnapshot struct {
	Paused  bool              `json:"paused"`
	Frame   DebugFrame        `json:"frame"`
	Stack   []DebugFrame      `json:"stack"`
	Runtime DebugRuntimeState `json:"runtime"`
}

type DebugListener func(DebugEvent)

type DebugStepMode string

const (
	DebugStepNone DebugStepMode = ""
	DebugStepIn   DebugStepMode = "in"
	DebugStepOver DebugStepMode = "over"
	DebugStepOut  DebugStepMode = "out"
)

type DebugBreakpoint struct {
	ID           string
	File         string
	Line         int
	Condition    func(DebugFrame) bool
	HitCondition func(int) bool
	hitCount     int
}

type DebugBreakpointResult struct {
	ID       string
	Verified bool
	Message  string
}

// Debugger receives checkpoints only while a listener is attached. Unattached debug
// programs therefore execute the same application code as release programs.
type Debugger struct {
	mutex          sync.Mutex
	condition      *sync.Cond
	listener       DebugListener
	breakpoints    map[string]*DebugBreakpoint
	paused         bool
	pauseRequested bool
	lastFrame      DebugFrame
	stepMode       DebugStepMode
	stepOrigin     DebugFrame
	stack          []DebugFrame
}

type DebugScope struct {
	debugger *Debugger
	frameID  string
	once     sync.Once
}

func NewDebugger() *Debugger {
	debugger := &Debugger{breakpoints: make(map[string]*DebugBreakpoint)}
	debugger.condition = sync.NewCond(&debugger.mutex)
	return debugger
}

func (debugger *Debugger) Attach(listener DebugListener) func() {
	debugger.mutex.Lock()
	debugger.listener = listener
	debugger.mutex.Unlock()
	return func() { debugger.Detach() }
}

func (debugger *Debugger) Detach() {
	debugger.mutex.Lock()
	debugger.listener = nil
	debugger.paused = false
	debugger.pauseRequested = false
	debugger.condition.Broadcast()
	debugger.mutex.Unlock()
}

func (debugger *Debugger) Enter(frame DebugFrame) *DebugScope {
	debugger.mutex.Lock()
	frame.Depth = len(debugger.stack)
	debugger.stack = append(debugger.stack, frame)
	debugger.mutex.Unlock()
	return &DebugScope{debugger: debugger, frameID: frame.ID}
}

func (scope *DebugScope) Leave() {
	if scope == nil {
		return
	}
	scope.once.Do(func() {
		scope.debugger.mutex.Lock()
		for index := len(scope.debugger.stack) - 1; index >= 0; index-- {
			if scope.debugger.stack[index].ID == scope.frameID {
				scope.debugger.stack = append(scope.debugger.stack[:index], scope.debugger.stack[index+1:]...)
				break
			}
		}
		scope.debugger.mutex.Unlock()
	})
}

func (debugger *Debugger) updateStackFrame(frame DebugFrame) {
	for index := len(debugger.stack) - 1; index >= 0; index-- {
		if debugger.stack[index].ID == frame.ID {
			frame.Depth = index
			debugger.stack[index] = frame
			return
		}
	}
}

func (debugger *Debugger) breakpointHit(frame DebugFrame) bool {
	for _, breakpoint := range debugger.breakpoints {
		if breakpoint.File != frame.Location.File || breakpoint.Line != frame.Location.Line {
			continue
		}
		breakpoint.hitCount++
		if breakpoint.Condition != nil && !breakpoint.Condition(frame) {
			continue
		}
		if breakpoint.HitCondition != nil && !breakpoint.HitCondition(breakpoint.hitCount) {
			continue
		}
		return true
	}
	return false
}

func (debugger *Debugger) Checkpoint(frame DebugFrame) {
	debugger.mutex.Lock()
	listener := debugger.listener
	if listener == nil {
		debugger.mutex.Unlock()
		return
	}
	debugger.mutex.Unlock()
	for index := range frame.Locals {
		if frame.Locals[index].Accessor != nil {
			frame.Locals[index].Value = frame.Locals[index].Accessor()
			frame.Locals[index].Accessor = nil
		}
	}
	debugger.mutex.Lock()
	listener = debugger.listener
	if len(debugger.stack) > 0 {
		frame.Depth = len(debugger.stack) - 1
		debugger.updateStackFrame(frame)
	}
	stepHit := debugger.stepMode != DebugStepNone && debugger.stepMatches(frame)
	if listener == nil || (!debugger.pauseRequested && !stepHit && !debugger.breakpointHit(frame)) {
		debugger.mutex.Unlock()
		return
	}
	debugger.pauseRequested = false
	debugger.stepMode = DebugStepNone
	debugger.paused = true
	debugger.lastFrame = frame
	stack := append([]DebugFrame(nil), debugger.stack...)
	debugger.mutex.Unlock()
	listener(DebugEvent{Kind: "stopped", Frame: frame, Stack: stack})
	debugger.mutex.Lock()
	for debugger.paused && debugger.listener != nil {
		debugger.condition.Wait()
	}
	debugger.mutex.Unlock()
}

func (debugger *Debugger) stepMatches(frame DebugFrame) bool {
	switch debugger.stepMode {
	case DebugStepIn:
		return true
	case DebugStepOver:
		return frame.Function == debugger.stepOrigin.Function
	case DebugStepOut:
		return frame.Function != debugger.stepOrigin.Function
	case DebugStepNone:
		return false
	default:
		return false
	}
}

func (debugger *Debugger) SetBreakpoints(breakpoints []DebugBreakpoint) []DebugBreakpointResult {
	debugger.mutex.Lock()
	defer debugger.mutex.Unlock()
	debugger.breakpoints = make(map[string]*DebugBreakpoint, len(breakpoints))
	results := make([]DebugBreakpointResult, 0, len(breakpoints))
	for index := range breakpoints {
		breakpoint := breakpoints[index]
		if breakpoint.ID == "" {
			breakpoint.ID = fmt.Sprintf("bp-%d", index+1)
		}
		breakpoint.hitCount = 0
		copy := breakpoint
		debugger.breakpoints[breakpoint.ID] = &copy
		results = append(results, DebugBreakpointResult{ID: breakpoint.ID, Verified: breakpoint.File != "" && breakpoint.Line >= 0})
	}
	return results
}

func (debugger *Debugger) ClearBreakpoints() {
	debugger.mutex.Lock()
	debugger.breakpoints = make(map[string]*DebugBreakpoint)
	debugger.mutex.Unlock()
}

func (debugger *Debugger) Pause() {
	debugger.mutex.Lock()
	debugger.stepMode = DebugStepNone
	debugger.pauseRequested = true
	debugger.mutex.Unlock()
}

func (debugger *Debugger) Continue() {
	debugger.mutex.Lock()
	debugger.stepMode = DebugStepNone
	debugger.paused = false
	debugger.condition.Broadcast()
	debugger.mutex.Unlock()
}

func (debugger *Debugger) Step(mode DebugStepMode) bool {
	if mode != DebugStepIn && mode != DebugStepOver && mode != DebugStepOut {
		return false
	}
	debugger.mutex.Lock()
	defer debugger.mutex.Unlock()
	if !debugger.paused {
		return false
	}
	debugger.stepMode = mode
	debugger.stepOrigin = debugger.lastFrame
	debugger.paused = false
	debugger.condition.Broadcast()
	return true
}

func (debugger *Debugger) Snapshot() (DebugFrame, bool) {
	debugger.mutex.Lock()
	defer debugger.mutex.Unlock()
	return debugger.lastFrame, debugger.paused
}

func (debugger *Debugger) StackSnapshot() []DebugFrame {
	debugger.mutex.Lock()
	defer debugger.mutex.Unlock()
	return append([]DebugFrame(nil), debugger.stack...)
}

func (debugger *Debugger) SnapshotState() DebugSnapshot {
	debugger.mutex.Lock()
	defer debugger.mutex.Unlock()
	return DebugSnapshot{
		Paused:  debugger.paused,
		Frame:   debugger.lastFrame,
		Stack:   append([]DebugFrame(nil), debugger.stack...),
		Runtime: DebugRuntimeStateSnapshot(),
	}
}

var DefaultDebugger = NewDebugger()

func Checkpoint(frame DebugFrame) { DefaultDebugger.Checkpoint(frame) }

func DebugEnter(frame DebugFrame) *DebugScope { return DefaultDebugger.Enter(frame) }
