package main

import (
	"encoding/json"
	"testing"

	"tesl.dev/runtime/go/teslrt"
)

func TestParseBreakpoint(t *testing.T) {
	file, line, err := parseBreakpoint("/tmp/app.tesl:42")
	if err != nil || file != "/tmp/app.tesl" || line != 42 {
		t.Fatalf("parseBreakpoint = %q, %d, %v", file, line, err)
	}
}

func TestParseBreakpointRejectsMalformedValue(t *testing.T) {
	for _, value := range []string{"42", ":42", "/tmp/app.tesl:0", "/tmp/app.tesl:nope"} {
		if _, _, err := parseBreakpoint(value); err == nil {
			t.Fatalf("accepted %q", value)
		}
	}
}

func TestSnapshotOutputReportsMissedBreakpoint(t *testing.T) {
	encoded, err := json.Marshal(snapshotOutput(teslrt.DebugSnapshot{}, "breakpoint-not-hit"))
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["version"] != float64(2) || decoded["stopped"] != false || decoded["reason"] != "breakpoint-not-hit" {
		t.Fatalf("snapshot JSON = %s", encoded)
	}
}

func TestSnapshotOutputUsesHeadlessV2BreakpointAndScalarLocals(t *testing.T) {
	snapshot := teslrt.DebugSnapshot{
		Paused: true,
		Frame: teslrt.DebugFrame{
			Location: teslrt.SourceLocation{File: "fixture.tesl", Line: 12},
			Locals:   []teslrt.DebugLocal{{Name: "n", Type: "Int", Value: teslrt.DebugValue{Type: "Int", Display: "3"}}},
		},
	}
	encoded, err := json.Marshal(snapshotOutput(snapshot, "", &inspectBreakpoint{Line: 12, Condition: "n == 3"}))
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Breakpoint *inspectBreakpoint `json:"breakpoint"`
		Locals     []inspectLocal     `json:"locals"`
	}
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Breakpoint == nil || decoded.Breakpoint.Line != 12 || len(decoded.Locals) != 1 || decoded.Locals[0].Value != "3" {
		t.Fatalf("snapshot JSON = %s", encoded)
	}
}
