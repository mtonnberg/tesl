package dap

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/teslrt"
)

func TestServerHandlesCoreRequests(t *testing.T) {
	var input bytes.Buffer
	inputWriter := protocol.NewWriter(&input)
	requests := []Request{
		{Seq: 1, Type: "request", Command: "initialize"},
		{Seq: 2, Type: "request", Command: "threads"},
		{Seq: 3, Type: "request", Command: "disconnect"},
	}
	for _, request := range requests {
		if err := Write(inputWriter, request); err != nil {
			t.Fatal(err)
		}
	}
	var output bytes.Buffer
	if err := NewServer(&input, &output, teslrt.NewDebugger()).Serve(); err != nil {
		t.Fatal(err)
	}
	reader := protocol.NewReader(&output)
	first, err := Read(reader)
	if err != nil {
		t.Fatal(err)
	}
	response, ok := first.(Response)
	if !ok || !response.Success || response.Command != "initialize" {
		t.Fatalf("initialize response = %#v", first)
	}
	var advertised capabilities
	if err := json.Unmarshal(response.Body, &advertised); err != nil {
		t.Fatal(err)
	}
	if !advertised.SupportsConfigurationDoneRequest || !advertised.SupportsVariablesRequest || !advertised.SupportsSingleStepRequest || !advertised.SupportsConditionalBreakpoints || !advertised.SupportsHitConditionalBreakpoints || !advertised.SupportsEvaluateForHovers || !advertised.SupportsClipboardContext || advertised.SupportsStepInTargetsRequest {
		t.Fatalf("capabilities = %#v", advertised)
	}
	second, err := Read(reader)
	if err != nil {
		t.Fatal(err)
	}
	if event, ok := second.(Event); !ok || event.Event != "initialized" {
		t.Fatalf("initialized event = %#v", second)
	}
	second, err = Read(reader)
	if err != nil {
		t.Fatal(err)
	}
	if response, ok := second.(Response); !ok || !response.Success || response.Command != "threads" {
		t.Fatalf("threads response = %#v", second)
	}
	third, err := Read(reader)
	if err != nil {
		t.Fatal(err)
	}
	if response, ok := third.(Response); !ok || !response.Success || response.Command != "disconnect" {
		t.Fatalf("disconnect response = %#v", third)
	}
}

func TestServerReportsUnsupportedCommand(t *testing.T) {
	var input bytes.Buffer
	if err := Write(protocol.NewWriter(&input), Request{Seq: 1, Type: "request", Command: "evaluate"}); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := NewServer(&input, &output, teslrt.NewDebugger()).Serve(); err != nil {
		t.Fatal(err)
	}
	message, err := Read(protocol.NewReader(&output))
	if err != nil {
		t.Fatal(err)
	}
	response, ok := message.(Response)
	if !ok || response.Success || response.Message == "" {
		t.Fatalf("unsupported response = %#v", message)
	}
}

type recordingTarget struct {
	launched bool
	attached bool
}

type recordingBackend struct {
	specifications []teslrt.DebugBreakpointSpec
	continued      int
	configured     int
}

func (backend *recordingBackend) Attach(teslrt.DebugListener) func() { return func() {} }
func (backend *recordingBackend) ClearBreakpoints() error            { return nil }
func (backend *recordingBackend) Pause() error                       { return nil }
func (backend *recordingBackend) Continue() error {
	backend.continued++
	return nil
}
func (backend *recordingBackend) ConfigurationDone() error {
	backend.configured++
	return nil
}
func (backend *recordingBackend) Step(teslrt.DebugStepMode) error { return nil }
func (backend *recordingBackend) SnapshotState() (teslrt.DebugSnapshot, error) {
	return teslrt.DebugSnapshot{}, nil
}
func (backend *recordingBackend) SetBreakpointSpecs(specifications []teslrt.DebugBreakpointSpec) ([]teslrt.DebugBreakpointResult, error) {
	backend.specifications = append([]teslrt.DebugBreakpointSpec(nil), specifications...)
	results := make([]teslrt.DebugBreakpointResult, len(specifications))
	for index, specification := range specifications {
		results[index] = teslrt.DebugBreakpointResult{ID: specification.ID, Verified: true}
	}
	return results, nil
}

type recordingBackendTarget struct{ backend *recordingBackend }

func (target *recordingBackendTarget) Launch(json.RawMessage) error { return nil }
func (target *recordingBackendTarget) Attach(json.RawMessage) error { return nil }
func (target *recordingBackendTarget) LaunchBackend(json.RawMessage) (DebugBackend, error) {
	return target.backend, nil
}
func (target *recordingBackendTarget) AttachBackend(json.RawMessage) (DebugBackend, error) {
	return target.backend, nil
}
func (target *recordingBackendTarget) Close() error { return nil }

func (target *recordingTarget) Launch(json.RawMessage) error {
	target.launched = true
	return nil
}

func (target *recordingTarget) Attach(json.RawMessage) error {
	target.attached = true
	return nil
}

func TestServerUsesExplicitLaunchAttachTarget(t *testing.T) {
	target := &recordingTarget{}
	server := NewServerWithTarget(strings.NewReader(""), io.Discard, teslrt.NewDebugger(), target)
	defer server.Close()
	launch, _, err := server.handle(Request{Seq: 1, Type: "request", Command: "launch"})
	if err != nil || !launch.Success || !target.launched {
		t.Fatalf("launch = %#v, target = %#v, error = %v", launch, target, err)
	}
	attach, _, err := server.handle(Request{Seq: 2, Type: "request", Command: "attach"})
	if err != nil || !attach.Success || !target.attached {
		t.Fatalf("attach = %#v, target = %#v, error = %v", attach, target, err)
	}
}

func TestServerCompletesLaunchHandshake(t *testing.T) {
	var input bytes.Buffer
	inputWriter := protocol.NewWriter(&input)
	for _, request := range []Request{
		{Seq: 1, Type: "request", Command: "initialize"},
		{Seq: 2, Type: "request", Command: "launch"},
		{Seq: 3, Type: "request", Command: "configurationDone"},
	} {
		if err := Write(inputWriter, request); err != nil {
			t.Fatal(err)
		}
	}
	backend := &recordingBackend{}
	target := &recordingBackendTarget{backend: backend}
	var output bytes.Buffer
	if err := NewServerWithTarget(&input, &output, teslrt.NewDebugger(), target).Serve(); err != nil {
		t.Fatal(err)
	}
	reader := protocol.NewReader(&output)
	message, err := Read(reader)
	if err != nil {
		t.Fatal(err)
	}
	if response, ok := message.(Response); !ok || !response.Success || response.Command != "initialize" {
		t.Fatalf("initialize response = %#v", message)
	}
	message, err = Read(reader)
	if err != nil {
		t.Fatal(err)
	}
	if event, ok := message.(Event); !ok || event.Event != "initialized" {
		t.Fatalf("initialized event = %#v", message)
	}
	for _, command := range []string{"launch"} {
		message, err = Read(reader)
		if err != nil {
			t.Fatal(err)
		}
		response, ok := message.(Response)
		if !ok || !response.Success || response.Command != command {
			t.Fatalf("%s response = %#v", command, message)
		}
	}
	message, err = Read(reader)
	if err != nil {
		t.Fatal(err)
	}
	if response, ok := message.(Response); !ok || !response.Success || response.Command != "configurationDone" {
		t.Fatalf("configurationDone response = %#v", message)
	}
	if backend.continued != 0 {
		t.Fatalf("configurationDone continued backend %d times, want 0", backend.continued)
	}
	if backend.configured != 1 {
		t.Fatalf("configurationDone notified backend %d times, want 1", backend.configured)
	}
}

func TestServerAppliesPreLaunchBreakpointsToNewBackend(t *testing.T) {
	target := &recordingBackendTarget{backend: &recordingBackend{}}
	server := NewServerWithTarget(strings.NewReader(""), io.Discard, teslrt.NewDebugger(), target)
	defer server.Close()
	set, _, err := server.handle(Request{Seq: 1, Type: "request", Command: "setBreakpoints", Arguments: mustJSON(setBreakpointsArguments{
		Source: source{Path: "main.tesl"}, Breakpoints: []breakpointRequest{{Line: 19, Condition: "n == 3"}},
	})})
	if err != nil || !set.Success {
		t.Fatalf("setBreakpoints = %#v, error = %v", set, err)
	}
	launch, _, err := server.handle(Request{Seq: 2, Type: "request", Command: "launch"})
	if err != nil || !launch.Success {
		t.Fatalf("launch = %#v, error = %v", launch, err)
	}
	if len(target.backend.specifications) != 1 || target.backend.specifications[0].File != "main.tesl" || target.backend.specifications[0].Line != 19 || target.backend.specifications[0].Condition != "n == 3" {
		t.Fatalf("applied breakpoints = %#v", target.backend.specifications)
	}
}

func TestServerKeepsBreakpointsForEachSource(t *testing.T) {
	target := &recordingBackendTarget{backend: &recordingBackend{}}
	server := NewServerWithTarget(strings.NewReader(""), io.Discard, teslrt.NewDebugger(), target)
	defer server.Close()
	for _, request := range []Request{
		{Seq: 1, Type: "request", Command: "setBreakpoints", Arguments: mustJSON(setBreakpointsArguments{
			Source: source{Path: "first.tesl"}, Breakpoints: []breakpointRequest{{Line: 10}},
		})},
		{Seq: 2, Type: "request", Command: "setBreakpoints", Arguments: mustJSON(setBreakpointsArguments{
			Source: source{Path: "second.tesl"}, Breakpoints: []breakpointRequest{{Line: 20}},
		})},
	} {
		response, _, err := server.handle(request)
		if err != nil || !response.Success {
			t.Fatalf("setBreakpoints = %#v, error = %v", response, err)
		}
	}
	if response, _, err := server.handle(Request{Seq: 3, Type: "request", Command: "launch"}); err != nil || !response.Success {
		t.Fatalf("launch = %#v, error = %v", response, err)
	}
	if len(target.backend.specifications) != 2 ||
		target.backend.specifications[0].File != "first.tesl" ||
		target.backend.specifications[1].File != "second.tesl" {
		t.Fatalf("aggregated breakpoints = %#v", target.backend.specifications)
	}
}

func TestServerSetBreakpointsUsesRuntimeGrammar(t *testing.T) {
	arguments, err := json.Marshal(setBreakpointsArguments{
		Source:      source{Path: "main.tesl"},
		Breakpoints: []breakpointRequest{{Line: 7, Condition: "n == 2", HitCondition: "==2"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	var input bytes.Buffer
	writer := protocol.NewWriter(&input)
	if err := Write(writer, Request{Seq: 1, Type: "request", Command: "setBreakpoints", Arguments: arguments}); err != nil {
		t.Fatal(err)
	}
	if err := Write(writer, Request{Seq: 2, Type: "request", Command: "disconnect"}); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := NewServer(&input, &output, teslrt.NewDebugger()).Serve(); err != nil {
		t.Fatal(err)
	}
	message, err := Read(protocol.NewReader(&output))
	if err != nil {
		t.Fatal(err)
	}
	response := message.(Response)
	var body breakpointsBody
	if err := json.Unmarshal(response.Body, &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Breakpoints) != 1 || !body.Breakpoints[0].Verified || body.Breakpoints[0].Line != 7 {
		t.Fatalf("breakpoints = %#v", body.Breakpoints)
	}
}

func TestServerScopesAndVariablesAreStopScoped(t *testing.T) {
	debugger := teslrt.NewDebugger()
	outputReader, outputWriter := io.Pipe()
	server := NewServer(strings.NewReader(""), outputWriter, debugger)
	defer server.Close()
	debugger.Pause()
	done := make(chan struct{})
	go func() {
		scope := debugger.Enter(teslrt.DebugFrame{
			ID: "frame", Function: "work",
			Location: teslrt.SourceLocation{File: "main.tesl", Line: 12},
		})
		defer scope.Leave()
		debugger.Checkpoint(teslrt.DebugFrame{
			ID: "frame", Function: "work",
			Location: teslrt.SourceLocation{File: "main.tesl", Line: 12},
			Locals: []teslrt.DebugLocal{{
				Name: "point", Type: "Point",
				Value: teslrt.DebugValue{Type: "Point", Display: "{...}", Children: []teslrt.DebugValue{{Type: "Int", Display: "42"}}},
			}},
		})
		close(done)
	}()
	if _, err := Read(protocol.NewReader(outputReader)); err != nil {
		t.Fatal(err)
	}

	stackResponse, _, err := server.handle(Request{Seq: 1, Type: "request", Command: "stackTrace", Arguments: json.RawMessage(`{"threadId":1}`)})
	if err != nil {
		t.Fatal(err)
	}
	var stack stackTraceBody
	if err := json.Unmarshal(stackResponse.Body, &stack); err != nil {
		t.Fatal(err)
	}
	if len(stack.StackFrames) != 1 || stack.StackFrames[0].ID == 0 {
		t.Fatalf("stack = %#v", stack)
	}
	evaluateResponse, _, err := server.handle(Request{Seq: 2, Type: "request", Command: "evaluate", Arguments: mustJSON(evaluateArguments{Expression: "point[0]", FrameID: 1})})
	if err != nil {
		t.Fatal(err)
	}
	var evaluated evaluateBody
	if err := json.Unmarshal(evaluateResponse.Body, &evaluated); err != nil {
		t.Fatal(err)
	}
	if evaluated.Result != "42" || evaluated.Type != "Int" {
		t.Fatalf("evaluate = %#v", evaluated)
	}
	clipboardResponse, _, err := server.handle(Request{Seq: 6, Type: "request", Command: "evaluate", Arguments: mustJSON(evaluateArguments{Expression: "point[0]", FrameID: 1, Context: "clipboard"})})
	if err != nil {
		t.Fatal(err)
	}
	var clipboard evaluateBody
	if err := json.Unmarshal(clipboardResponse.Body, &clipboard); err != nil {
		t.Fatal(err)
	}
	if clipboard.Result != "42" || clipboard.VariablesReference != 0 {
		t.Fatalf("clipboard evaluate = %#v", clipboard)
	}
	hoverResponse, _, err := server.handle(Request{Seq: 7, Type: "request", Command: "evaluate", Arguments: mustJSON(evaluateArguments{Expression: "missing", FrameID: 1, Context: "hover"})})
	if err != nil {
		t.Fatal(err)
	}
	if hoverResponse.Success || hoverResponse.Message != "" {
		t.Fatalf("unknown hover = %#v", hoverResponse)
	}

	scopesResponse, _, err := server.handle(Request{Seq: 3, Type: "request", Command: "scopes", Arguments: json.RawMessage(`{"frameId":1}`)})
	if err != nil {
		t.Fatal(err)
	}
	var scopes scopesBody
	if err := json.Unmarshal(scopesResponse.Body, &scopes); err != nil {
		t.Fatal(err)
	}
	if len(scopes.Scopes) != 1 || scopes.Scopes[0].VariablesReference == 0 {
		t.Fatalf("scopes = %#v", scopes)
	}

	variablesResponse, _, err := server.handle(Request{Seq: 4, Type: "request", Command: "variables", Arguments: mustJSON(variablesArguments{VariablesReference: scopes.Scopes[0].VariablesReference})})
	if err != nil {
		t.Fatal(err)
	}
	var variables variablesBody
	if err := json.Unmarshal(variablesResponse.Body, &variables); err != nil {
		t.Fatal(err)
	}
	if len(variables.Variables) != 1 || variables.Variables[0].Name != "point" || variables.Variables[0].VariablesReference == 0 {
		t.Fatalf("variables = %#v", variables)
	}
	childrenResponse, _, err := server.handle(Request{Seq: 5, Type: "request", Command: "variables", Arguments: mustJSON(variablesArguments{VariablesReference: variables.Variables[0].VariablesReference})})
	if err != nil {
		t.Fatal(err)
	}
	var children variablesBody
	if err := json.Unmarshal(childrenResponse.Body, &children); err != nil {
		t.Fatal(err)
	}
	if len(children.Variables) != 1 || children.Variables[0].Name != "[0]" || children.Variables[0].Value != "42" {
		t.Fatalf("children = %#v", children)
	}
	var childrenWire struct {
		Variables []map[string]json.RawMessage `json:"variables"`
	}
	if err := json.Unmarshal(childrenResponse.Body, &childrenWire); err != nil {
		t.Fatal(err)
	}
	if _, ok := childrenWire.Variables[0]["variablesReference"]; !ok {
		t.Fatal("leaf DAP variable is missing variablesReference")
	}

	debugger.Continue()
	<-done
}

func TestServerAddsDomainAndSQLScopes(t *testing.T) {
	server := NewServer(strings.NewReader(""), io.Discard, teslrt.NewDebugger())
	defer server.Close()
	server.frames[1] = teslrt.DebugFrame{ID: "frame", Locals: nil}
	server.runtime = teslrt.DebugRuntimeState{
		Domain: teslrt.DebugDomainState{Queues: []teslrt.DebugDomainItem{{
			Name: "jobs", Type: "Queue", Value: teslrt.DebugValue{Type: "Queue", Display: "1 pending"},
		}}},
		SQL: &teslrt.DebugSQLCapture{Operation: "select", SQL: "select 1", Table: "items", RowCount: 1},
	}
	response, _, err := server.handle(Request{Seq: 1, Type: "request", Command: "scopes", Arguments: json.RawMessage(`{"frameId":1}`)})
	if err != nil {
		t.Fatal(err)
	}
	var body scopesBody
	if err := json.Unmarshal(response.Body, &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Scopes) != 3 || body.Scopes[1].Name != "Domain" || body.Scopes[2].Name != "SQL · select items" {
		t.Fatalf("scopes = %#v", body.Scopes)
	}
	variablesResponse, _, err := server.handle(Request{Seq: 2, Type: "request", Command: "variables", Arguments: mustJSON(variablesArguments{VariablesReference: body.Scopes[2].VariablesReference})})
	if err != nil {
		t.Fatal(err)
	}
	var variables variablesBody
	if err := json.Unmarshal(variablesResponse.Body, &variables); err != nil {
		t.Fatal(err)
	}
	if len(variables.Variables) == 0 || variables.Variables[0].Name != "sql" {
		t.Fatalf("SQL variables = %#v", variables.Variables)
	}
}

func TestEvaluateFrameValueTraversesNamedChildren(t *testing.T) {
	frame := teslrt.DebugFrame{Locals: []teslrt.DebugLocal{{
		Name: "echoResp", Type: "Response", Value: teslrt.DebugValue{
			Type: "Response", Display: "{...}", Children: []teslrt.DebugValue{{
				Name: "body", Type: "JsonValue", Display: "{...}", Children: []teslrt.DebugValue{{
					Name: "message", Type: "String", Display: "hello",
				}},
			}},
		},
	}}}
	name, value, valueType, ok := evaluateFrameValue(frame, "echoResp.body.message")
	if !ok || name != "echoResp" || value.Display != "hello" || valueType != "String" {
		t.Fatalf("named evaluation = %q, %#v, %q, %t", name, value, valueType, ok)
	}
}

func TestServerReadsBoundedTeslSource(t *testing.T) {
	path := t.TempDir() + "/sample.tesl"
	if err := os.WriteFile(path, []byte("fn main() -> Unit = ()\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	server := NewServer(strings.NewReader(""), io.Discard, teslrt.NewDebugger())
	defer server.Close()
	response, _, err := server.handle(Request{Seq: 1, Type: "request", Command: "source", Arguments: mustJSON(sourceArguments{Source: source{Path: path}})})
	if err != nil {
		t.Fatal(err)
	}
	var body sourceBody
	if err := json.Unmarshal(response.Body, &body); err != nil {
		t.Fatal(err)
	}
	if body.Content != "fn main() -> Unit = ()\n" || body.MimeType != "text/x-tesl" {
		t.Fatalf("source = %#v", body)
	}
}

func mustJSON(value any) json.RawMessage {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return encoded
}

func TestControlClientBridgesRuntimeProtocol(t *testing.T) {
	clientConnection, serverConnection := net.Pipe()
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		defer func() { _ = serverConnection.Close() }()
		scanner := bufio.NewScanner(serverConnection)
		encoder := json.NewEncoder(serverConnection)
		for scanner.Scan() {
			var request teslrt.DebugControlRequest
			if json.Unmarshal(scanner.Bytes(), &request) != nil {
				return
			}
			response := teslrt.DebugControlResponse{ID: request.ID, Result: json.RawMessage(`{}`)}
			switch request.Command {
			case "handshake":
				response.Result = mustJSON(teslrt.DebugHandshake{Version: teslrt.DebugProtocolVersion, Runtime: "go", ABIVersion: teslrt.DebugABIVersion})
			case "set-breakpoints":
				response.Result = json.RawMessage(`[{"id":"bp","verified":true}]`)
			case "snapshot":
				response.Result = mustJSON(map[string]any{
					"paused": true,
					"frame":  teslrt.DebugFrame{ID: "frame", Function: "work"},
					"stack":  []teslrt.DebugFrame{{ID: "frame", Function: "work"}},
				})
			case "continue":
				if err := encoder.Encode(teslrt.DebugStoppedEvent{Event: "stopped", Frame: teslrt.DebugFrame{ID: "frame"}}); err != nil {
					return
				}
			case "ping":
				response.Result = json.RawMessage(`{"ok":true}`)
			}
			if err := encoder.Encode(response); err != nil {
				return
			}
			if request.Command == "detach" {
				return
			}
		}
	}()
	client, err := NewControlClient(clientConnection)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		client.Close()
		<-serverDone
	}()
	if err := client.Ping(); err != nil {
		t.Fatal(err)
	}

	breakpoints, err := client.SetBreakpointSpecs([]teslrt.DebugBreakpointSpec{{ID: "bp", File: "main.tesl", Line: 7}})
	if err != nil || len(breakpoints) != 1 || !breakpoints[0].Verified {
		t.Fatalf("breakpoints = %#v, error = %v", breakpoints, err)
	}
	frame, paused, err := client.Snapshot()
	if err != nil || !paused || frame.ID != "frame" {
		t.Fatalf("snapshot = %#v, paused = %v, error = %v", frame, paused, err)
	}
	stack, err := client.StackSnapshot()
	if err != nil || len(stack) != 1 || stack[0].Function != "work" {
		t.Fatalf("stack = %#v, error = %v", stack, err)
	}
	stopped := make(chan teslrt.DebugEvent, 1)
	client.Attach(func(event teslrt.DebugEvent) { stopped <- event })
	if err := client.Continue(); err != nil {
		t.Fatal(err)
	}
	select {
	case event := <-stopped:
		if event.Kind != "stopped" || event.Frame.ID != "frame" {
			t.Fatalf("event = %#v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("stopped event not delivered")
	}
	if err := client.Detach(); err != nil {
		t.Fatal(err)
	}
}
