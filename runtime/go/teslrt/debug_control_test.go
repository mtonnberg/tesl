package teslrt

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestDebugControlHandshakeAndContinue(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix control endpoint")
	}
	directory := t.TempDir()
	path := filepath.Join(directory, "debug.sock")
	debugger := NewDebugger()
	server, err := debugger.StartDebugControl(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode = %o", info.Mode().Perm())
	}
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = connection.Close() }()
	reader := bufio.NewReader(connection)
	send := func(request DebugControlRequest) map[string]any {
		if err := json.NewEncoder(connection).Encode(request); err != nil {
			t.Fatal(err)
		}
		var response map[string]any
		if err := json.NewDecoder(reader).Decode(&response); err != nil {
			t.Fatal(err)
		}
		return response
	}
	response := send(DebugControlRequest{ID: "1", Command: "handshake"})
	if response["error"] != nil {
		t.Fatalf("handshake response = %#v", response)
	}
	response = send(DebugControlRequest{ID: "2", Command: "set-breakpoints", Breakpoints: []DebugBreakpointSpec{{
		ID: "bp", File: "main.tesl", Line: 4, Hit: "==2",
	}}})
	if response["error"] != nil {
		t.Fatalf("breakpoint response = %#v", response)
	}
	debugger.Checkpoint(DebugFrame{Location: SourceLocation{File: "main.tesl", Line: 4}})
	done := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{Location: SourceLocation{File: "main.tesl", Line: 4}})
		close(done)
	}()
	var stopped DebugStoppedEvent
	if err := json.NewDecoder(reader).Decode(&stopped); err != nil {
		t.Fatal(err)
	}
	if stopped.Event != "stopped" {
		t.Fatalf("event = %#v", stopped)
	}
	response = send(DebugControlRequest{ID: "3", Command: "snapshot"})
	if response["error"] != nil {
		t.Fatalf("snapshot response = %#v", response)
	}
	send(DebugControlRequest{ID: "4", Command: "step-in"})
	nextDone := make(chan struct{})
	go func() {
		debugger.Checkpoint(DebugFrame{Function: "next", Location: SourceLocation{File: "main.tesl", Line: 5}})
		close(nextDone)
	}()
	var nextStopped DebugStoppedEvent
	if err := json.NewDecoder(reader).Decode(&nextStopped); err != nil {
		t.Fatal(err)
	}
	if nextStopped.Event != "stopped" || nextStopped.Frame.Function != "next" {
		t.Fatalf("step event = %#v", nextStopped)
	}
	send(DebugControlRequest{ID: "5", Command: "continue"})
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("continue did not release checkpoint")
	}
	<-nextDone
}

func TestDebugControlWaitsForConfiguration(t *testing.T) {
	server, err := NewDebugger().StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	done := make(chan struct{})
	go func() {
		server.WaitForConfiguration()
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("configuration wait returned before breakpoints")
	case <-time.After(20 * time.Millisecond):
	}
	connection, err := net.Dial("tcp", server.Endpoint())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = connection.Close() }()
	reader := bufio.NewReader(connection)
	encoder := json.NewEncoder(connection)
	if err := encoder.Encode(DebugControlRequest{ID: "1", Command: "set-breakpoints"}); err != nil {
		t.Fatal(err)
	}
	var response DebugControlResponse
	if err := json.NewDecoder(reader).Decode(&response); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("configuration wait did not return")
	}
}

func TestDebugControlEvaluatesWireConditions(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix control endpoint")
	}
	path := filepath.Join(t.TempDir(), "debug.sock")
	server, err := NewDebugger().StartDebugControl(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = connection.Close() }()
	if err := json.NewEncoder(connection).Encode(DebugControlRequest{
		ID: "1", Command: "set-breakpoints", Breakpoints: []DebugBreakpointSpec{{File: "main.tesl", Line: 1, Condition: "n == 1"}},
	}); err != nil {
		t.Fatal(err)
	}
	var response DebugControlResponse
	if err := json.NewDecoder(connection).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.Error != nil {
		t.Fatalf("accepted condition response = %#v", response)
	}
	if err := json.NewEncoder(connection).Encode(DebugControlRequest{
		ID: "2", Command: "set-breakpoints", Breakpoints: []DebugBreakpointSpec{{File: "main.tesl", Line: 1, Condition: "n === 1"}},
	}); err != nil {
		t.Fatal(err)
	}
	if err := json.NewDecoder(connection).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.Error == nil || response.Error.Code != "invalid-condition" {
		t.Fatalf("response = %#v", response)
	}
}

func TestDebugControlTCPBindsLoopback(t *testing.T) {
	debugger := NewDebugger()
	server, err := debugger.StartDebugControlTCP(0)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	if server.Endpoint() == "" {
		t.Fatal("Endpoint() returned empty address")
	}
	connection, err := net.Dial("tcp", server.Endpoint())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = connection.Close() }()
	if err := json.NewEncoder(connection).Encode(DebugControlRequest{ID: "1", Command: "handshake"}); err != nil {
		t.Fatal(err)
	}
	var response DebugControlResponse
	if err := json.NewDecoder(connection).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.Error != nil {
		t.Fatalf("TCP handshake response = %#v", response)
	}
}

func TestDebugControlEnvironmentDiscovery(t *testing.T) {
	t.Setenv("TESL_DEBUG", "")
	t.Setenv("TESL_DEBUG_SOCKET", "")
	t.Setenv("TESL_DEBUG_PORT", "")
	server, err := StartDebugControlFromEnvironment()
	if err != nil || server != nil {
		t.Fatalf("disabled discovery = server %v, error %v", server, err)
	}
	root := t.TempDir()
	t.Setenv("TESL_DEBUG", "1")
	t.Setenv("TESL_DEBUG_ROOT", root)
	server, err = StartDebugControlFromEnvironment()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = server.Close() }()
	if _, err := os.Stat(filepath.Join(root, ".tesl-stuff", "debug.sock")); err != nil {
		t.Fatalf("discovered socket: %v", err)
	}
}

func TestDebugConditionReadsLocalsAndLogicalOperators(t *testing.T) {
	condition, err := compileDebugCondition(`n == 2 && function == "work"`)
	if err != nil {
		t.Fatal(err)
	}
	frame := DebugFrame{
		Function: "work",
		Locals:   []DebugLocal{{Name: "n", Value: DebugValue{Display: "2"}}},
	}
	if !condition(frame) {
		t.Fatal("condition rejected matching frame")
	}
	frame.Function = "other"
	if condition(frame) {
		t.Fatal("condition accepted non-matching frame")
	}
}
