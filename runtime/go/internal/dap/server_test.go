package dap

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
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
	second, err := Read(reader)
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
	debugger.Enter(teslrt.DebugFrame{
		ID: "frame", Function: "work",
		Location: teslrt.SourceLocation{File: "main.tesl", Line: 12},
	})
	debugger.Pause()
	done := make(chan struct{})
	go func() {
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

	scopesResponse, _, err := server.handle(Request{Seq: 2, Type: "request", Command: "scopes", Arguments: json.RawMessage(`{"frameId":1}`)})
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

	variablesResponse, _, err := server.handle(Request{Seq: 3, Type: "request", Command: "variables", Arguments: mustJSON(variablesArguments{VariablesReference: scopes.Scopes[0].VariablesReference})})
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

	childrenResponse, _, err := server.handle(Request{Seq: 4, Type: "request", Command: "variables", Arguments: mustJSON(variablesArguments{VariablesReference: variables.Variables[0].VariablesReference})})
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
		defer serverConnection.Close()
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
			}
			if err := encoder.Encode(response); err != nil {
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
}
