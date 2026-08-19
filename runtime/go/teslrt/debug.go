package teslrt

import "sync"

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
	Name  string     `json:"name"`
	Type  string     `json:"type"`
	Value DebugValue `json:"value"`
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
	Kind  string     `json:"kind"`
	Frame DebugFrame `json:"frame"`
}

type DebugListener func(DebugEvent)

// Debugger receives checkpoints only while a listener is attached. Unattached debug
// programs therefore execute the same application code as release programs.
type Debugger struct {
	mutex    sync.RWMutex
	listener DebugListener
}

func NewDebugger() *Debugger { return &Debugger{} }

func (debugger *Debugger) Attach(listener DebugListener) func() {
	debugger.mutex.Lock()
	debugger.listener = listener
	debugger.mutex.Unlock()
	return func() { debugger.Detach() }
}

func (debugger *Debugger) Detach() {
	debugger.mutex.Lock()
	debugger.listener = nil
	debugger.mutex.Unlock()
}

func (debugger *Debugger) Checkpoint(frame DebugFrame) {
	debugger.mutex.RLock()
	listener := debugger.listener
	debugger.mutex.RUnlock()
	if listener != nil {
		listener(DebugEvent{Kind: "stopped", Frame: frame})
	}
}

var DefaultDebugger = NewDebugger()

func Checkpoint(frame DebugFrame) { DefaultDebugger.Checkpoint(frame) }
