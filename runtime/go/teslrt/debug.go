package teslrt

import (
	"fmt"
	"path/filepath"
	"reflect"
	goruntime "runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// DebugABIVersion identifies the language-neutral checkpoint metadata contract.
const DebugABIVersion = 1

type SourceLocation struct {
	File   string `json:"file"`
	Line   int    `json:"line"`
	Column int    `json:"column"`
}

type debugValueProvider interface {
	DebugValue(string) DebugValue
}

// DebugValueOf builds the expandable value tree used by the DAP adapter. The evaluator name is
// carried into children so a client can inspect a field using the same expression it sees in the
// Tesl source. Feature-specific values can provide DebugValue without making the core debugger
// depend on an optional runtime file.
func DebugValueOf(value any, evaluateName string) DebugValue {
	if provider, ok := value.(debugValueProvider); ok {
		return provider.DebugValue(evaluateName)
	}
	return debugReflectValue(reflect.ValueOf(value), evaluateName, 0)
}

func debugReflectValue(value reflect.Value, evaluateName string, depth int) DebugValue {
	if !value.IsValid() {
		return DebugValue{Type: "null", Display: "null", EvaluateName: evaluateName}
	}
	for value.Kind() == reflect.Interface || value.Kind() == reflect.Pointer {
		if value.IsNil() {
			return DebugValue{Type: value.Type().String(), Display: "nil", EvaluateName: evaluateName}
		}
		value = value.Elem()
	}
	if value.CanInterface() {
		if provider, ok := value.Interface().(debugValueProvider); ok {
			return provider.DebugValue(evaluateName)
		}
		if integer, ok := value.Interface().(Int); ok {
			return DebugValue{Type: "Int", Display: integer.String(), EvaluateName: evaluateName}
		}
	}
	result := DebugValue{Type: value.Type().String(), Display: fmt.Sprint(value.Interface()), EvaluateName: evaluateName}
	if depth >= 8 {
		return result
	}
	switch value.Kind() {
	case reflect.Struct:
		for index := 0; index < value.NumField(); index++ {
			field := value.Type().Field(index)
			if field.PkgPath != "" || !value.Field(index).CanInterface() {
				continue
			}
			name := strings.ToLower(field.Name[:1]) + field.Name[1:]
			child := debugReflectValue(value.Field(index), joinDebugField(evaluateName, name), depth+1)
			child.Name = name
			result.Children = append(result.Children, child)
		}
	case reflect.Slice, reflect.Array:
		for index := 0; index < value.Len(); index++ {
			name := fmt.Sprintf("[%d]", index)
			child := debugReflectValue(value.Index(index), evaluateName+name, depth+1)
			child.Name = name
			result.Children = append(result.Children, child)
		}
	case reflect.Map:
		keys := value.MapKeys()
		sort.Slice(keys, func(left, right int) bool {
			return fmt.Sprint(keys[left].Interface()) < fmt.Sprint(keys[right].Interface())
		})
		for _, key := range keys {
			name := fmt.Sprint(key.Interface())
			child := debugReflectValue(value.MapIndex(key), joinDebugField(evaluateName, name), depth+1)
			child.Name = name
			result.Children = append(result.Children, child)
		}
	case reflect.Invalid, reflect.Bool,
		reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64,
		reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr,
		reflect.Float32, reflect.Float64, reflect.Complex64, reflect.Complex128,
		reflect.Chan, reflect.Func, reflect.Interface, reflect.Pointer,
		reflect.String, reflect.UnsafePointer:
		// Scalar and opaque values have no expandable children.
	}
	return result
}

func joinDebugField(base, field string) string {
	if base == "" {
		return field
	}
	return base + "." + field
}

// Bounded returns a copy safe for a wire value tree. It limits depth, child count,
// and UTF-8 display bytes while preserving the fact that truncation occurred.
func (value DebugValue) Bounded(maxDepth, maxChildren, maxDisplayBytes int) DebugValue {
	if maxDepth < 0 {
		maxDepth = 0
	}
	if maxChildren < 0 {
		maxChildren = 0
	}
	if maxDisplayBytes > 0 && len(value.Display) > maxDisplayBytes {
		value.Display = truncateDebugDisplay(value.Display, maxDisplayBytes)
		value.Truncated = true
	}
	if maxDepth == 0 {
		if len(value.Children) > 0 {
			value.Children = nil
			value.Truncated = true
		}
		return value
	}
	if len(value.Children) > maxChildren {
		value.Children = value.Children[:maxChildren]
		value.Truncated = true
	}
	for index := range value.Children {
		value.Children[index] = value.Children[index].Bounded(maxDepth-1, maxChildren, maxDisplayBytes)
	}
	return value
}

func truncateDebugDisplay(value string, limit int) string {
	if limit <= 0 {
		return ""
	}
	if utf8.ValidString(value) {
		for len(value) > limit {
			value = value[:len(value)-1]
			for !utf8.ValidString(value) {
				value = value[:len(value)-1]
			}
		}
		return value
	}
	return strings.ToValidUTF8(value[:limit], "")
}

func safeDebugValue(accessor func() DebugValue) (value DebugValue) {
	defer func() {
		if recover() != nil {
			value = DebugValue{Type: "unavailable", Display: "[unavailable]", Truncated: true}
		}
	}()
	return accessor().Bounded(8, 100, 4096)
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
	stopping       bool
	pauseRequested bool
	// PauseTimeout bounds how long ONE stop may hold application goroutines
	// before the debugger auto-resumes. Zero (the default) waits forever —
	// correct while a human is stepping in a live session, because resuming
	// under them would corrupt their mental model of "paused". The attach/DAP
	// servers set this from TESL_DEBUG_PAUSE_TIMEOUT_MS so a client that dies
	// mid-stop (SIGKILL, laptop sleep) cannot wedge a long-running service.
	PauseTimeout time.Duration
	lastFrame    DebugFrame
	lastSnapshot DebugSnapshot
	stepMode     DebugStepMode
	stepOrigin   DebugFrame
	stoppedExec  uint64
	stacks       map[uint64][]DebugFrame
	quiescent    map[uint64]int
	participants map[uint64]struct{}
	parked       map[uint64]struct{}
}

type DebugScope struct {
	debugger  *Debugger
	frameID   string
	execution uint64
	once      sync.Once
}

type DebugQuiescentScope struct {
	debugger  *Debugger
	execution uint64
	once      sync.Once
}

func NewDebugger() *Debugger {
	debugger := &Debugger{
		breakpoints:  make(map[string]*DebugBreakpoint),
		stacks:       make(map[uint64][]DebugFrame),
		quiescent:    make(map[uint64]int),
		participants: make(map[uint64]struct{}),
		parked:       make(map[uint64]struct{}),
	}
	debugger.condition = sync.NewCond(&debugger.mutex)
	return debugger
}

func init() {
	debugLifecycleQuiesce = func() func() {
		quiescent := DebugQuiesce()
		return quiescent.Resume
	}
}

// Quiesce marks the current execution as blocked in runtime lifecycle work.
// Its stack remains available, but it cannot hold a cooperative stop open.
// Resume waits behind an established or collecting stop before returning to
// instrumented Tesl code.
func (debugger *Debugger) Quiesce() *DebugQuiescentScope {
	execution := debugExecutionID()
	debugger.mutex.Lock()
	debugger.quiescent[execution]++
	if debugger.stopping {
		delete(debugger.participants, execution)
		delete(debugger.parked, execution)
		debugger.condition.Broadcast()
	}
	debugger.mutex.Unlock()
	return &DebugQuiescentScope{debugger: debugger, execution: execution}
}

func (scope *DebugQuiescentScope) Resume() {
	if scope == nil {
		return
	}
	scope.once.Do(func() {
		scope.debugger.mutex.Lock()
		if count := scope.debugger.quiescent[scope.execution]; count <= 1 {
			delete(scope.debugger.quiescent, scope.execution)
			scope.debugger.waitAtBarrier(scope.execution)
		} else {
			scope.debugger.quiescent[scope.execution] = count - 1
		}
		scope.debugger.mutex.Unlock()
	})
}

func (debugger *Debugger) Attach(listener DebugListener) func() {
	debugger.mutex.Lock()
	debugger.listener = listener
	debugger.mutex.Unlock()
	return func() { debugger.Detach() }
}

// Detach ends the session: application goroutines resume, and the retained stop
// frame (request-scoped locals) is dropped so a later client cannot read it.
func (debugger *Debugger) Detach() {
	debugger.mutex.Lock()
	debugger.listener = nil
	debugger.paused = false
	debugger.stopping = false
	debugger.pauseRequested = false
	debugger.stepMode = DebugStepNone
	debugger.lastFrame = DebugFrame{}
	debugger.lastSnapshot = DebugSnapshot{}
	debugger.stoppedExec = 0
	clear(debugger.participants)
	clear(debugger.parked)
	debugger.condition.Broadcast()
	debugger.mutex.Unlock()
}

func (debugger *Debugger) Enter(frame DebugFrame) *DebugScope {
	execution := debugExecutionID()
	debugger.mutex.Lock()
	debugger.waitAtBarrier(execution)
	stack := debugger.stacks[execution]
	frame.Depth = len(stack)
	debugger.stacks[execution] = append(stack, frame)
	debugger.mutex.Unlock()
	return &DebugScope{debugger: debugger, frameID: frame.ID, execution: execution}
}

func (scope *DebugScope) Leave() {
	if scope == nil {
		return
	}
	scope.once.Do(func() {
		scope.debugger.mutex.Lock()
		stack := scope.debugger.stacks[scope.execution]
		executionEnded := false
		for index := len(stack) - 1; index >= 0; index-- {
			if stack[index].ID == scope.frameID {
				stack = append(stack[:index], stack[index+1:]...)
				break
			}
		}
		if len(stack) == 0 {
			executionEnded = true
			delete(scope.debugger.stacks, scope.execution)
			delete(scope.debugger.quiescent, scope.execution)
			if scope.debugger.stopping {
				delete(scope.debugger.participants, scope.execution)
				delete(scope.debugger.parked, scope.execution)
				scope.debugger.condition.Broadcast()
			}
		} else {
			scope.debugger.stacks[scope.execution] = stack
		}
		scope.debugger.mutex.Unlock()
		if executionEnded {
			clearDebugSQLCaptureForExecution(scope.execution)
		}
	})
}

func (debugger *Debugger) updateStackFrame(execution uint64, frame DebugFrame) {
	stack, present := debugger.stacks[execution]
	if !present || len(stack) == 0 {
		return
	}
	for index := len(stack); index > 0; index-- {
		frameIndex := index - 1
		if stack[frameIndex].ID == frame.ID {
			frame.Depth = frameIndex
			stack[frameIndex] = frame
			debugger.stacks[execution] = stack
			return
		}
	}
}

// debugExecutionID supplies execution-local storage for debug builds without
// changing the generated checkpoint ABI. Go exposes no goroutine-local API; the
// runtime stack header is therefore read only while debugging is active.
func debugExecutionID() uint64 {
	var buffer [64]byte
	count := goruntime.Stack(buffer[:], false)
	fields := strings.Fields(string(buffer[:count]))
	if len(fields) < 2 {
		return 0
	}
	id, _ := strconv.ParseUint(fields[1], 10, 64)
	return id
}

// waitAtBarrier parks an execution at an instrumentation boundary. Callers hold
// debugger.mutex. Executions already active when a stop begins acknowledge the
// rendezvous; executions starting later wait without extending that finite set.
func (debugger *Debugger) waitAtBarrier(execution uint64) bool {
	waited := false
	for debugger.stopping || debugger.paused {
		waited = true
		if _, participates := debugger.participants[execution]; participates {
			debugger.parked[execution] = struct{}{}
			debugger.condition.Broadcast()
		}
		debugger.condition.Wait()
	}
	return waited
}

func (debugger *Debugger) barrierComplete() bool {
	for execution := range debugger.participants {
		if _, parked := debugger.parked[execution]; !parked {
			return false
		}
	}
	return true
}

func (debugger *Debugger) breakpointHit(frame DebugFrame) bool {
	for _, breakpoint := range debugger.breakpoints {
		if !sameSourceFile(breakpoint.File, frame.Location.File) || breakpoint.Line != frame.Location.Line {
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

func sameSourceFile(left, right string) bool {
	if left == right {
		return true
	}
	leftAbsolute, leftErr := filepath.Abs(left)
	rightAbsolute, rightErr := filepath.Abs(right)
	return leftErr == nil && rightErr == nil && filepath.Clean(leftAbsolute) == filepath.Clean(rightAbsolute)
}

func (debugger *Debugger) Checkpoint(frame DebugFrame) {
	debugger.mutex.Lock()
	listener := debugger.listener
	if listener == nil {
		debugger.mutex.Unlock()
		return
	}
	debugger.mutex.Unlock()
	execution := debugExecutionID()
	for index := range frame.Locals {
		if frame.Locals[index].Accessor != nil {
			frame.Locals[index].Value = safeDebugValue(frame.Locals[index].Accessor)
			frame.Locals[index].Accessor = nil
		}
	}
	debugger.mutex.Lock()
	if debugger.waitAtBarrier(execution) {
		debugger.mutex.Unlock()
		return
	}
	listener = debugger.listener
	stack := debugger.stacks[execution]
	if len(stack) > 0 {
		frame.Depth = len(stack) - 1
		debugger.updateStackFrame(execution, frame)
	}
	stepHit := debugger.stepMode != DebugStepNone && debugger.stepMatches(frame)
	if listener == nil || (!debugger.pauseRequested && !stepHit && !debugger.breakpointHit(frame)) {
		debugger.mutex.Unlock()
		return
	}
	debugger.pauseRequested = false
	debugger.stepMode = DebugStepNone
	debugger.stopping = true
	clear(debugger.participants)
	clear(debugger.parked)
	for active := range debugger.stacks {
		if debugger.quiescent[active] == 0 {
			debugger.participants[active] = struct{}{}
		}
	}
	debugger.participants[execution] = struct{}{}
	debugger.parked[execution] = struct{}{}
	for !debugger.barrierComplete() && debugger.listener != nil {
		debugger.condition.Wait()
	}
	listener = debugger.listener
	if listener == nil || !debugger.stopping {
		debugger.stopping = false
		clear(debugger.participants)
		clear(debugger.parked)
		debugger.condition.Broadcast()
		debugger.mutex.Unlock()
		return
	}
	debugger.stopping = false
	debugger.paused = true
	debugger.stoppedExec = execution
	debugger.lastFrame = frame
	stack = append([]DebugFrame(nil), debugger.stacks[execution]...)
	debugger.lastSnapshot = DebugSnapshot{Paused: true, Frame: frame, Stack: stack}
	debugger.mutex.Unlock()
	runtimeState := debugRuntimeStateSnapshotForExecution(execution)
	debugger.mutex.Lock()
	if debugger.paused && debugger.stoppedExec == execution {
		debugger.lastSnapshot.Runtime = runtimeState
	}
	publish := debugger.paused && debugger.stoppedExec == execution
	listener = debugger.listener
	debugger.mutex.Unlock()
	if !publish || listener == nil {
		return
	}
	listener(DebugEvent{Kind: "stopped", Frame: frame, Stack: stack})
	debugger.mutex.Lock()
	// The auto-resume guard: one timer per stop. It re-checks under the mutex
	// (a human Continue may have won the race) and broadcasts so every waiting
	// checkpoint re-evaluates `paused`. Stopped when the wait ends first.
	if debugger.PauseTimeout > 0 {
		timer := time.AfterFunc(debugger.PauseTimeout, func() {
			debugger.mutex.Lock()
			if debugger.paused {
				debugger.paused = false
				debugger.lastFrame = DebugFrame{}
				debugger.lastSnapshot = DebugSnapshot{}
				debugger.stoppedExec = 0
				clear(debugger.participants)
				clear(debugger.parked)
				debugger.condition.Broadcast()
			}
			debugger.mutex.Unlock()
		})
		defer timer.Stop()
	}
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

// Continue resumes every waiting checkpoint and forgets the stop frame: once the
// program is running again its request state must not stay readable via snapshot.
func (debugger *Debugger) Continue() {
	debugger.mutex.Lock()
	debugger.stepMode = DebugStepNone
	debugger.paused = false
	debugger.stopping = false
	debugger.lastFrame = DebugFrame{}
	debugger.lastSnapshot = DebugSnapshot{}
	debugger.stoppedExec = 0
	clear(debugger.participants)
	clear(debugger.parked)
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
	debugger.lastFrame = DebugFrame{}
	debugger.lastSnapshot = DebugSnapshot{}
	debugger.stoppedExec = 0
	clear(debugger.participants)
	clear(debugger.parked)
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
	if debugger.paused {
		return append([]DebugFrame(nil), debugger.lastSnapshot.Stack...)
	}
	return append([]DebugFrame(nil), debugger.stacks[debugExecutionID()]...)
}

func (debugger *Debugger) SnapshotState() DebugSnapshot {
	debugger.mutex.Lock()
	defer debugger.mutex.Unlock()
	if !debugger.paused {
		return DebugSnapshot{}
	}
	snapshot := debugger.lastSnapshot
	snapshot.Stack = append([]DebugFrame(nil), snapshot.Stack...)
	return snapshot
}

var DefaultDebugger = NewDebugger()

func Checkpoint(frame DebugFrame) { DefaultDebugger.Checkpoint(frame) }

func DebugEnter(frame DebugFrame) *DebugScope { return DefaultDebugger.Enter(frame) }

func DebugQuiesce() *DebugQuiescentScope { return DefaultDebugger.Quiesce() }
