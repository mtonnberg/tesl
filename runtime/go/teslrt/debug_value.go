package teslrt

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
