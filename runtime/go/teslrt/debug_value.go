package teslrt

// Debug builds replace this no-op from debug.go. DebugValue remains available
// in release emission, so HTTP lifecycle code can call the hook without taking
// a dependency on debug-only runtime files.
var debugLifecycleQuiesce = func() func() { return func() {} }

// DebugValue is the bounded, language-neutral value tree exchanged with debug clients.
// The type is available to api-test runtime code without shipping the debug control machinery.
type DebugValue struct {
	Name         string       `json:"name,omitempty"`
	EvaluateName string       `json:"evaluateName,omitempty"`
	Type         string       `json:"type"`
	Display      string       `json:"display"`
	Children     []DebugValue `json:"children,omitempty"`
	Truncated    bool         `json:"truncated,omitempty"`
}
