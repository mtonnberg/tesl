package dap

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/teslrt"
)

type Server struct {
	backend     DebugBackend
	target      Target
	reader      *protocol.Reader
	writer      *protocol.Writer
	session     *Session
	detach      func()
	close       sync.Once
	mutex       sync.Mutex
	frames      map[int]teslrt.DebugFrame
	values      map[int]variableReference
	nextRef     int
	runtime     teslrt.DebugRuntimeState
	breakpoints []teslrt.DebugBreakpointSpec
}

type DebugBackend interface {
	Attach(teslrt.DebugListener) func()
	ClearBreakpoints() error
	Pause() error
	Continue() error
	Step(teslrt.DebugStepMode) error
	SnapshotState() (teslrt.DebugSnapshot, error)
}

type localBackend struct {
	debugger *teslrt.Debugger
}

func (backend *localBackend) Attach(listener teslrt.DebugListener) func() {
	return backend.debugger.Attach(listener)
}

func (backend *localBackend) ClearBreakpoints() error {
	backend.debugger.ClearBreakpoints()
	return nil
}

func (backend *localBackend) Pause() error {
	backend.debugger.Pause()
	return nil
}

func (backend *localBackend) Continue() error {
	backend.debugger.Continue()
	return nil
}

func (backend *localBackend) Step(mode teslrt.DebugStepMode) error {
	if !backend.debugger.Step(mode) {
		return errors.New("step requires a stopped debugger")
	}
	return nil
}

func (backend *localBackend) SnapshotState() (teslrt.DebugSnapshot, error) {
	return backend.debugger.SnapshotState(), nil
}

func (backend *localBackend) SetBreakpoints(breakpoints []teslrt.DebugBreakpoint) []teslrt.DebugBreakpointResult {
	return backend.debugger.SetBreakpoints(breakpoints)
}

// Target supplies process-specific launch/attach behavior without making the
// protocol server depend on a particular compiler or executable layout.
type Target interface {
	Launch(json.RawMessage) error
	Attach(json.RawMessage) error
}

type BackendTarget interface {
	Target
	LaunchBackend(json.RawMessage) (DebugBackend, error)
	AttachBackend(json.RawMessage) (DebugBackend, error)
	Close() error
}

type TargetEvent struct {
	Event string
	Body  any
}

type TargetEventListener interface {
	SetEventListener(func(TargetEvent))
}

func NewServer(input io.Reader, output io.Writer, debugger *teslrt.Debugger) *Server {
	return NewServerWithTarget(input, output, debugger, nil)
}

func NewServerWithTarget(input io.Reader, output io.Writer, debugger *teslrt.Debugger, target Target) *Server {
	if debugger == nil {
		debugger = teslrt.NewDebugger()
	}
	return NewServerWithBackendAndTarget(input, output, &localBackend{debugger: debugger}, target)
}

func NewServerWithBackend(input io.Reader, output io.Writer, backend DebugBackend) *Server {
	return NewServerWithBackendAndTarget(input, output, backend, nil)
}

func NewServerWithBackendAndTarget(input io.Reader, output io.Writer, backend DebugBackend, target Target) *Server {
	server := &Server{
		backend: backend,
		target:  target,
		reader:  protocol.NewReader(input),
		writer:  protocol.NewWriter(output),
		session: NewSession(),
		frames:  make(map[int]teslrt.DebugFrame),
		values:  make(map[int]variableReference),
		nextRef: 1,
	}
	server.detach = backend.Attach(server.stopped)
	if eventTarget, ok := target.(TargetEventListener); ok {
		eventTarget.SetEventListener(server.targetEvent)
	}
	return server
}

func (server *Server) Close() {
	server.close.Do(func() {
		if server.detach != nil {
			server.detach()
		}
		if eventTarget, ok := server.target.(TargetEventListener); ok {
			eventTarget.SetEventListener(nil)
		}
		if target, ok := server.target.(BackendTarget); ok {
			_ = target.Close()
		}
	})
}

func (server *Server) Serve() error {
	defer server.Close()
	for {
		message, err := Read(server.reader)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		request, ok := message.(Request)
		if !ok {
			return errors.New("dap: client message is not a request")
		}
		response, closeAfter, err := server.handle(request)
		if err != nil {
			return err
		}
		if err := Write(server.writer, response); err != nil {
			return err
		}
		if response.Success && request.Command == "initialize" {
			initialized, eventErr := server.session.Event("initialized", nil)
			if eventErr != nil {
				return eventErr
			}
			if err := Write(server.writer, initialized); err != nil {
				return err
			}
		}
		if closeAfter {
			return nil
		}
	}
}

type initializeArguments struct {
	AdapterID string `json:"adapterID"`
}

type capabilities struct {
	SupportsConfigurationDoneRequest  bool `json:"supportsConfigurationDoneRequest"`
	SupportsVariablesRequest          bool `json:"supportsVariablesRequest"`
	SupportsSingleStepRequest         bool `json:"supportsSingleStepRequest"`
	SupportsStepInTargetsRequest      bool `json:"supportsStepInTargetsRequest"`
	SupportsConditionalBreakpoints    bool `json:"supportsConditionalBreakpoints"`
	SupportsHitConditionalBreakpoints bool `json:"supportsHitConditionalBreakpoints"`
	SupportsEvaluateForHovers         bool `json:"supportsEvaluateForHovers"`
	SupportsClipboardContext          bool `json:"supportsClipboardContext"`
	SupportsSteppingGranularity       bool `json:"supportsSteppingGranularity"`
}

type source struct {
	Name string `json:"name,omitempty"`
	Path string `json:"path,omitempty"`
}

type setBreakpointsArguments struct {
	Source      source              `json:"source"`
	Breakpoints []breakpointRequest `json:"breakpoints,omitempty"`
}

type breakpointRequest struct {
	Line         int    `json:"line"`
	Condition    string `json:"condition,omitempty"`
	HitCondition string `json:"hitCondition,omitempty"`
}

type breakpoint struct {
	ID       int    `json:"id,omitempty"`
	Verified bool   `json:"verified"`
	Message  string `json:"message,omitempty"`
	Source   source `json:"source,omitempty"`
	Line     int    `json:"line,omitempty"`
}

type breakpointsBody struct {
	Breakpoints []breakpoint `json:"breakpoints"`
}

type thread struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

type threadsBody struct {
	Threads []thread `json:"threads"`
}

type stackTraceArguments struct {
	ThreadID   int `json:"threadId"`
	StartFrame int `json:"startFrame,omitempty"`
	Levels     int `json:"levels,omitempty"`
}

type stackFrame struct {
	ID                 int     `json:"id"`
	Name               string  `json:"name"`
	Source             *source `json:"source,omitempty"`
	Line               int     `json:"line"`
	Column             int     `json:"column"`
	VariablesReference int     `json:"variablesReference,omitempty"`
}

type stackTraceBody struct {
	StackFrames []stackFrame `json:"stackFrames"`
	TotalFrames int          `json:"totalFrames"`
}

type stoppedBody struct {
	Reason            string `json:"reason"`
	ThreadID          int    `json:"threadId"`
	AllThreadsStopped bool   `json:"allThreadsStopped"`
}

const maxDAPSourceBytes = 2 << 20

type evaluateArguments struct {
	Expression string `json:"expression"`
	FrameID    int    `json:"frameId,omitempty"`
	Context    string `json:"context,omitempty"`
}

type evaluateBody struct {
	Result             string `json:"result"`
	Type               string `json:"type,omitempty"`
	VariablesReference int    `json:"variablesReference"`
}

type sourceArguments struct {
	Source          source `json:"source"`
	SourceReference int    `json:"sourceReference,omitempty"`
}

type sourceBody struct {
	Content  string `json:"content"`
	MimeType string `json:"mimeType,omitempty"`
}

type scopesArguments struct {
	FrameID int `json:"frameId"`
}

type scope struct {
	Name               string `json:"name"`
	VariablesReference int    `json:"variablesReference"`
	Expensive          bool   `json:"expensive"`
}

type scopesBody struct {
	Scopes []scope `json:"scopes"`
}

type variablesArguments struct {
	VariablesReference int `json:"variablesReference"`
	Start              int `json:"start,omitempty"`
	Count              int `json:"count,omitempty"`
}

type variable struct {
	Name               string `json:"name"`
	Value              string `json:"value"`
	Type               string `json:"type,omitempty"`
	EvaluateName       string `json:"evaluateName,omitempty"`
	VariablesReference int    `json:"variablesReference"`
}

type variablesBody struct {
	Variables []variable `json:"variables"`
}

type variableReference struct {
	Locals   []teslrt.DebugLocal
	Entries  []variableEntry
	Value    teslrt.DebugValue
	HasValue bool
}

type variableEntry struct {
	Name  string
	Type  string
	Value teslrt.DebugValue
}

func (server *Server) handle(request Request) (Response, bool, error) {
	switch request.Command {
	case "initialize":
		var arguments initializeArguments
		if err := decodeArguments(request.Arguments, &arguments); err != nil {
			return server.failure(request, err.Error())
		}
		return server.success(request, capabilities{
			SupportsConfigurationDoneRequest:  true,
			SupportsVariablesRequest:          true,
			SupportsSingleStepRequest:         true,
			SupportsStepInTargetsRequest:      false,
			SupportsConditionalBreakpoints:    true,
			SupportsHitConditionalBreakpoints: true,
			SupportsEvaluateForHovers:         true,
			SupportsClipboardContext:          true,
			SupportsSteppingGranularity:       true,
		})
	case "configurationDone":
		return server.success(request, map[string]bool{})
	case "setExceptionBreakpoints":
		return server.success(request, map[string]bool{})
	case "setBreakpoints":
		return server.setBreakpoints(request)
	case "threads":
		return server.success(request, threadsBody{Threads: []thread{{ID: 1, Name: "main"}}})
	case "stackTrace":
		return server.stackTrace(request)
	case "scopes":
		return server.scopes(request)
	case "variables":
		return server.variables(request)
	case "continue":
		if err := server.backend.Continue(); err != nil {
			return server.failure(request, err.Error())
		}
		return server.success(request, map[string]bool{"allThreadsContinued": true})
	case "pause":
		if err := server.backend.Pause(); err != nil {
			return server.failure(request, err.Error())
		}
		return server.success(request, map[string]bool{})
	case "next":
		return server.step(request, teslrt.DebugStepOver)
	case "stepIn":
		return server.step(request, teslrt.DebugStepIn)
	case "stepOut":
		return server.step(request, teslrt.DebugStepOut)
	case "disconnect":
		if err := server.backend.Continue(); err != nil {
			return server.failure(request, err.Error())
		}
		response, _, err := server.success(request, map[string]bool{})
		return response, true, err
	case "launch":
		if server.target == nil {
			return server.failure(request, "launch target is not configured")
		}
		if target, ok := server.target.(BackendTarget); ok {
			backend, err := target.LaunchBackend(request.Arguments)
			if err != nil {
				return server.failure(request, "launch failed: "+err.Error())
			}
			if err := server.replaceBackend(backend); err != nil {
				return server.failure(request, "launch failed: "+err.Error())
			}
			return server.success(request, map[string]bool{})
		}
		if err := server.target.Launch(request.Arguments); err != nil {
			return server.failure(request, "launch failed: "+err.Error())
		}
		return server.success(request, map[string]bool{})
	case "attach":
		if server.target == nil {
			return server.failure(request, "attach target is not configured")
		}
		if target, ok := server.target.(BackendTarget); ok {
			backend, err := target.AttachBackend(request.Arguments)
			if err != nil {
				return server.failure(request, "attach failed: "+err.Error())
			}
			if err := server.replaceBackend(backend); err != nil {
				return server.failure(request, "attach failed: "+err.Error())
			}
			return server.success(request, map[string]bool{})
		}
		if err := server.target.Attach(request.Arguments); err != nil {
			return server.failure(request, "attach failed: "+err.Error())
		}
		return server.success(request, map[string]bool{})
	case "source":
		return server.source(request)
	case "evaluate":
		return server.evaluate(request)
	default:
		return server.failure(request, "unsupported DAP command: "+request.Command)
	}
}

func (server *Server) replaceBackend(backend DebugBackend) error {
	if server.detach != nil {
		server.detach()
	}
	server.backend = backend
	server.detach = backend.Attach(server.stopped)
	server.mutex.Lock()
	breakpoints := append([]teslrt.DebugBreakpointSpec(nil), server.breakpoints...)
	server.frames = make(map[int]teslrt.DebugFrame)
	server.values = make(map[int]variableReference)
	server.nextRef = 1
	server.runtime = teslrt.DebugRuntimeState{}
	server.mutex.Unlock()
	if setter, ok := backend.(interface {
		SetBreakpointSpecs([]teslrt.DebugBreakpointSpec) ([]teslrt.DebugBreakpointResult, error)
	}); ok && len(breakpoints) > 0 {
		_, err := setter.SetBreakpointSpecs(breakpoints)
		if err != nil {
			return err
		}
	}
	return nil
}

func (server *Server) success(request Request, body any) (Response, bool, error) {
	response, err := server.session.Response(request, true, body, "")
	return response, false, err
}

func (server *Server) failure(request Request, message string) (Response, bool, error) {
	response, err := server.session.Response(request, false, nil, message)
	return response, false, err
}

func decodeArguments(data json.RawMessage, destination any) error {
	if len(data) == 0 {
		return nil
	}
	if err := json.Unmarshal(data, destination); err != nil {
		return fmt.Errorf("invalid arguments: %w", err)
	}
	return nil
}

func (server *Server) setBreakpoints(request Request) (Response, bool, error) {
	var arguments setBreakpointsArguments
	if err := decodeArguments(request.Arguments, &arguments); err != nil {
		return server.failure(request, err.Error())
	}
	var results []teslrt.DebugBreakpointResult
	specifications := make([]teslrt.DebugBreakpointSpec, 0, len(arguments.Breakpoints))
	for index, specification := range arguments.Breakpoints {
		specifications = append(specifications, teslrt.DebugBreakpointSpec{
			ID: fmt.Sprintf("dap-bp-%d", index+1), File: arguments.Source.Path, Line: specification.Line,
			Condition: specification.Condition, Hit: specification.HitCondition,
		})
	}
	if backend, ok := server.backend.(interface {
		SetBreakpointSpecs([]teslrt.DebugBreakpointSpec) ([]teslrt.DebugBreakpointResult, error)
	}); ok {
		var err error
		results, err = backend.SetBreakpointSpecs(specifications)
		if err != nil {
			return server.failure(request, err.Error())
		}
	} else {
		backend, ok := server.backend.(interface {
			SetBreakpoints([]teslrt.DebugBreakpoint) []teslrt.DebugBreakpointResult
		})
		if !ok {
			return server.failure(request, "debug backend does not support breakpoints")
		}
		debugBreakpoints := make([]teslrt.DebugBreakpoint, 0, len(arguments.Breakpoints))
		for index, specification := range arguments.Breakpoints {
			condition, err := teslrt.CompileDebugCondition(specification.Condition)
			if err != nil {
				return server.failure(request, "invalid condition: "+err.Error())
			}
			hitCondition, err := teslrt.ParseHitCondition(specification.HitCondition)
			if err != nil {
				return server.failure(request, "invalid hit condition: "+err.Error())
			}
			debugBreakpoints = append(debugBreakpoints, teslrt.DebugBreakpoint{
				ID: fmt.Sprintf("dap-bp-%d", index+1), File: arguments.Source.Path, Line: specification.Line,
				Condition: condition, HitCondition: hitCondition,
			})
		}
		results = backend.SetBreakpoints(debugBreakpoints)
	}
	server.mutex.Lock()
	server.breakpoints = append([]teslrt.DebugBreakpointSpec(nil), specifications...)
	server.mutex.Unlock()
	body := breakpointsBody{Breakpoints: make([]breakpoint, len(results))}
	for index, result := range results {
		line := 0
		if index < len(arguments.Breakpoints) {
			line = arguments.Breakpoints[index].Line
		}
		body.Breakpoints[index] = breakpoint{
			ID: index + 1, Verified: result.Verified, Message: result.Message,
			Source: arguments.Source, Line: line,
		}
	}
	return server.success(request, body)
}

func (server *Server) stackTrace(request Request) (Response, bool, error) {
	var arguments stackTraceArguments
	if err := decodeArguments(request.Arguments, &arguments); err != nil {
		return server.failure(request, err.Error())
	}
	if arguments.ThreadID != 0 && arguments.ThreadID != 1 {
		return server.failure(request, "unknown thread")
	}
	snapshot, err := server.backend.SnapshotState()
	if err != nil {
		return server.failure(request, err.Error())
	}
	frames := snapshot.Stack
	last := snapshot.Frame
	paused := snapshot.Paused
	if !paused {
		frames = []teslrt.DebugFrame{}
	} else if len(frames) == 0 {
		frames = []teslrt.DebugFrame{last}
	}
	all := make([]stackFrame, 0, len(frames))
	server.mutex.Lock()
	server.frames = make(map[int]teslrt.DebugFrame)
	server.values = make(map[int]variableReference)
	server.nextRef = 1
	server.runtime = snapshot.Runtime
	for index := len(frames) - 1; index >= 0; index-- {
		frame := frames[index]
		frameID := len(frames) - index
		server.frames[frameID] = frame
		entry := stackFrame{ID: frameID, Name: frame.Function, Line: frame.Location.Line, Column: frame.Location.Column}
		if frame.Location.File != "" {
			entry.Source = &source{Path: frame.Location.File}
		}
		if len(frame.Locals) > 0 {
			entry.VariablesReference = server.newReferenceLocked(variableReference{Locals: frame.Locals})
		}
		all = append(all, entry)
	}
	server.mutex.Unlock()
	start := arguments.StartFrame
	if start < 0 {
		start = 0
	}
	if start > len(all) {
		start = len(all)
	}
	end := len(all)
	if arguments.Levels > 0 && start+arguments.Levels < end {
		end = start + arguments.Levels
	}
	return server.success(request, stackTraceBody{StackFrames: all[start:end], TotalFrames: len(all)})
}

func (server *Server) scopes(request Request) (Response, bool, error) {
	var arguments scopesArguments
	if err := decodeArguments(request.Arguments, &arguments); err != nil {
		return server.failure(request, err.Error())
	}
	server.mutex.Lock()
	frame, ok := server.frames[arguments.FrameID]
	if !ok {
		server.mutex.Unlock()
		return server.failure(request, "unknown or expired stack frame")
	}
	variablesReference := 0
	if len(frame.Locals) > 0 {
		variablesReference = server.newReferenceLocked(variableReference{Locals: frame.Locals})
	}
	scopes := []scope{{Name: "Locals", VariablesReference: variablesReference, Expensive: false}}
	if entries := domainEntries(server.runtime.Domain); len(entries) > 0 {
		scopes = append(scopes, scope{Name: "Domain", VariablesReference: server.newReferenceLocked(variableReference{Entries: entries}), Expensive: false})
	}
	if server.runtime.SQL != nil {
		scopes = append(scopes, scope{Name: sqlScopeName(*server.runtime.SQL), VariablesReference: server.newReferenceLocked(variableReference{Entries: sqlEntries(*server.runtime.SQL)}), Expensive: false})
	}
	server.mutex.Unlock()
	return server.success(request, scopesBody{Scopes: scopes})
}

func (server *Server) variables(request Request) (Response, bool, error) {
	var arguments variablesArguments
	if err := decodeArguments(request.Arguments, &arguments); err != nil {
		return server.failure(request, err.Error())
	}
	server.mutex.Lock()
	reference, ok := server.values[arguments.VariablesReference]
	if !ok {
		server.mutex.Unlock()
		return server.failure(request, "unknown or expired variables reference")
	}
	variables := make([]variable, 0)
	if reference.Locals != nil {
		for _, local := range reference.Locals {
			variables = append(variables, server.variableLocked(local.Name, local.Type, local.Value))
		}
	} else if reference.Entries != nil {
		for _, entry := range reference.Entries {
			variables = append(variables, server.variableLocked(entry.Name, entry.Type, entry.Value))
		}
	} else if reference.HasValue {
		for index, child := range reference.Value.Children {
			name := fmt.Sprintf("[%d]", index)
			if child.Name != "" {
				name = child.Name
			}
			variables = append(variables, server.variableLocked(name, child.Type, child))
		}
	}
	server.mutex.Unlock()
	start := arguments.Start
	if start < 0 {
		start = 0
	}
	if start > len(variables) {
		start = len(variables)
	}
	end := len(variables)
	if arguments.Count > 0 && start+arguments.Count < end {
		end = start + arguments.Count
	}
	return server.success(request, variablesBody{Variables: variables[start:end]})
}

func (server *Server) newReferenceLocked(reference variableReference) int {
	ref := server.nextRef
	server.nextRef++
	server.values[ref] = reference
	return ref
}

func domainEntries(domain teslrt.DebugDomainState) []variableEntry {
	entries := make([]variableEntry, 0)
	appendItems := func(items []teslrt.DebugDomainItem) {
		for _, item := range items {
			name := item.Name
			if name == "" {
				name = item.Kind
			}
			entries = append(entries, variableEntry{Name: name, Type: item.Type, Value: item.Value})
		}
	}
	appendItems(domain.Queues)
	appendItems(domain.Caches)
	appendItems(domain.SSE)
	appendItems(domain.Email)
	appendItems(domain.Workers)
	return entries
}

func sqlScopeName(sql teslrt.DebugSQLCapture) string {
	name := "SQL"
	if sql.Operation != "" {
		name += " · " + sql.Operation
	}
	if sql.Table != "" {
		name += " " + sql.Table
	}
	return name
}

func sqlEntries(sql teslrt.DebugSQLCapture) []variableEntry {
	entries := []variableEntry{
		{Name: "sql", Type: "String", Value: teslrt.DebugValue{Type: "String", Display: sql.SQL}},
		{Name: "preview", Type: "String", Value: teslrt.DebugValue{Type: "String", Display: sql.Preview}},
		{Name: "row-count", Type: "Int", Value: teslrt.DebugValue{Type: "Int", Display: strconv.Itoa(sql.RowCount)}},
	}
	if sql.Operation != "" {
		entries = append(entries, variableEntry{Name: "operation", Type: "String", Value: teslrt.DebugValue{Type: "String", Display: sql.Operation}})
	}
	if sql.Table != "" {
		entries = append(entries, variableEntry{Name: "table", Type: "String", Value: teslrt.DebugValue{Type: "String", Display: sql.Table}})
	}
	if len(sql.Params) > 0 {
		entries = append(entries, variableEntry{Name: "params", Type: "List", Value: teslrt.DebugValue{Type: "List", Display: fmt.Sprintf("[%d params]", len(sql.Params)), Children: sql.Params}})
	}
	return entries
}

func (server *Server) variableLocked(name, valueType string, value teslrt.DebugValue) variable {
	variablesReference := 0
	if len(value.Children) > 0 {
		variablesReference = server.newReferenceLocked(variableReference{Value: value, HasValue: true})
	}
	if valueType == "" {
		valueType = value.Type
	}
	evaluateName := value.EvaluateName
	if evaluateName == "" {
		evaluateName = name
	}
	return variable{
		Name: name, Value: value.Display, Type: valueType,
		EvaluateName: evaluateName, VariablesReference: variablesReference,
	}
}

func (server *Server) evaluate(request Request) (Response, bool, error) {
	var arguments evaluateArguments
	if err := decodeArguments(request.Arguments, &arguments); err != nil {
		return server.failure(request, err.Error())
	}
	if len(arguments.Expression) == 0 || len(arguments.Expression) > 256 {
		return server.failure(request, "evaluate supports a non-empty expression up to 256 bytes")
	}
	server.mutex.Lock()
	frame, ok := server.frames[arguments.FrameID]
	if arguments.FrameID == 0 && !ok {
		frame, ok = server.frames[1]
	}
	if !ok {
		server.mutex.Unlock()
		return server.failure(request, "unknown or expired stack frame")
	}
	name, value, valueType, ok := evaluateFrameValue(frame, arguments.Expression)
	if !ok {
		server.mutex.Unlock()
		if arguments.Context == "hover" {
			return server.failure(request, "")
		}
		return server.failure(request, "evaluate supports locals and indexed child values only")
	}
	result := evaluateBody{Result: value.Display, Type: valueType}
	if arguments.Context != "clipboard" && len(value.Children) > 0 {
		result.VariablesReference = server.newReferenceLocked(variableReference{Value: value, HasValue: true})
	}
	server.mutex.Unlock()
	_ = name
	return server.success(request, result)
}

func evaluateFrameValue(frame teslrt.DebugFrame, expression string) (string, teslrt.DebugValue, string, bool) {
	baseEnd := strings.IndexByte(expression, '[')
	if baseEnd < 0 {
		baseEnd = len(expression)
	}
	name := expression[:baseEnd]
	if name == "" {
		return "", teslrt.DebugValue{}, "", false
	}
	var value teslrt.DebugValue
	valueType := ""
	found := false
	for _, local := range frame.Locals {
		if local.Name == name {
			value = local.Value
			valueType = local.Type
			found = true
			break
		}
	}
	if !found {
		return "", teslrt.DebugValue{}, "", false
	}
	remaining := expression[baseEnd:]
	for remaining != "" {
		if remaining[0] != '[' {
			return "", teslrt.DebugValue{}, "", false
		}
		end := strings.IndexByte(remaining, ']')
		if end < 2 {
			return "", teslrt.DebugValue{}, "", false
		}
		index, err := strconv.Atoi(remaining[1:end])
		if err != nil || index < 0 || index >= len(value.Children) {
			return "", teslrt.DebugValue{}, "", false
		}
		value = value.Children[index]
		valueType = value.Type
		remaining = remaining[end+1:]
	}
	return name, value, valueType, true
}

func (server *Server) source(request Request) (Response, bool, error) {
	var arguments sourceArguments
	if err := decodeArguments(request.Arguments, &arguments); err != nil {
		return server.failure(request, err.Error())
	}
	if arguments.SourceReference != 0 {
		return server.failure(request, "source references are not supported")
	}
	path := arguments.Source.Path
	if path == "" {
		return server.failure(request, "source path is empty")
	}
	file, err := os.Open(path) // #nosec G304 -- DAP source path is an explicit local debug request.
	if err != nil {
		return server.failure(request, "cannot open source: "+err.Error())
	}
	defer func() { _ = file.Close() }()
	if info, err := file.Stat(); err != nil {
		return server.failure(request, "cannot stat source: "+err.Error())
	} else if !info.Mode().IsRegular() {
		return server.failure(request, "source is not a regular file")
	}
	content, err := io.ReadAll(io.LimitReader(file, maxDAPSourceBytes+1))
	if err != nil {
		return server.failure(request, "cannot read source: "+err.Error())
	}
	if len(content) > maxDAPSourceBytes {
		return server.failure(request, "source exceeds the 2 MiB limit")
	}
	mimeType := "text/plain"
	if strings.HasSuffix(path, ".tesl") {
		mimeType = "text/x-tesl"
	}
	return server.success(request, sourceBody{Content: string(content), MimeType: mimeType})
}

func (server *Server) step(request Request, mode teslrt.DebugStepMode) (Response, bool, error) {
	if err := server.backend.Step(mode); err != nil {
		return server.failure(request, err.Error())
	}
	return server.success(request, map[string]bool{})
}

func (server *Server) stopped(event teslrt.DebugEvent) {
	server.mutex.Lock()
	server.frames = make(map[int]teslrt.DebugFrame)
	server.values = make(map[int]variableReference)
	server.nextRef = 1
	server.runtime = teslrt.DebugRuntimeState{}
	server.mutex.Unlock()
	message, err := server.session.Event("stopped", stoppedBody{Reason: "breakpoint", ThreadID: 1, AllThreadsStopped: true})
	if err == nil {
		_ = Write(server.writer, message)
	}
}

func (server *Server) targetEvent(event TargetEvent) {
	message, err := server.session.Event(event.Event, event.Body)
	if err == nil {
		_ = Write(server.writer, message)
	}
}
