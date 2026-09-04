package tooling

import (
	"context"
	"os"
	"strings"
	"testing"
)

func TestClientRunsJSONQueryAndPreservesStderr(t *testing.T) {
	if os.Getenv("TESL_COMPILER_HELPER") == "diagnostics" {
		_, _ = os.Stdout.WriteString(`{"version":1,"diagnostics":[{"severity":"error"}]}`)
		os.Exit(1)
	}
	if os.Getenv("TESL_COMPILER_HELPER") == "1" {
		_, _ = os.Stdout.WriteString(`{"version":1}`)
		_, _ = os.Stderr.WriteString("warning\n")
		os.Exit(0)
	}
	if len(os.Args) == 0 {
		t.Fatal("test executable path unavailable")
	}
	client := Client{
		Executable:  os.Args[0],
		Environment: append(os.Environ(), "TESL_COMPILER_HELPER=1"),
	}
	payload, result, err := client.QueryJSON(context.Background(), "-test.run=TestClientRunsJSONQueryAndPreservesStderr")
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != `{"version":1}` || string(result.Stderr) != "warning\n" {
		t.Fatalf("payload=%s stderr=%q", payload, result.Stderr)
	}
}

func TestClientRejectsInvalidKnownCompilerSchema(t *testing.T) {
	script := t.TempDir() + "/invalid-compiler.sh"
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s' '{\"version\":1}'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	_, _, err := (Client{Executable: script}).QueryJSON(context.Background(), "--check-json", "fixture.tesl")
	if err == nil || !strings.Contains(err.Error(), "missing required field") {
		t.Fatalf("QueryJSON() error = %v", err)
	}
}

func TestClientAcceptsValidJSONFromDiagnosticExit(t *testing.T) {
	if os.Getenv("TESL_COMPILER_HELPER") == "diagnostics" {
		_, _ = os.Stdout.WriteString(`{"version":1,"diagnostics":[{"severity":"error"}]}`)
		os.Exit(1)
	}
	if len(os.Args) == 0 {
		t.Fatal("test executable path unavailable")
	}
	client := Client{
		Executable:  os.Args[0],
		Environment: append(os.Environ(), "TESL_COMPILER_HELPER=diagnostics"),
	}
	payload, result, err := client.QueryJSON(context.Background(), "-test.run=TestClientAcceptsValidJSONFromDiagnosticExit")
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode != 1 || !strings.Contains(string(payload), `"diagnostics"`) {
		t.Fatalf("exit=%d payload=%s", result.ExitCode, payload)
	}
}

func TestWithEnvironmentReplacesDuplicateValues(t *testing.T) {
	got := withEnvironment([]string{"A=1", "TESL_LOGICAL_PATH=old", "TESL_LOGICAL_PATH=stale"}, "TESL_LOGICAL_PATH", "/tmp/new.tesl")
	count := 0
	for _, entry := range got {
		if entry == "TESL_LOGICAL_PATH=/tmp/new.tesl" {
			count++
		}
		if entry == "TESL_LOGICAL_PATH=old" || entry == "TESL_LOGICAL_PATH=stale" {
			t.Fatalf("old environment value retained: %v", got)
		}
	}
	if count != 1 {
		t.Fatalf("environment = %v", got)
	}
}

func TestClientRejectsOutputBomb(t *testing.T) {
	if os.Getenv("TESL_COMPILER_HELPER") == "bomb" {
		_, _ = os.Stdout.WriteString(strings.Repeat("x", 100))
		os.Exit(0)
	}
	if len(os.Args) == 0 {
		t.Fatal("test executable path unavailable")
	}
	client := Client{
		Executable:  os.Args[0],
		MaxOutput:   10,
		Environment: append(os.Environ(), "TESL_COMPILER_HELPER=bomb"),
	}
	_, err := client.Run(context.Background(), "-test.run=TestClientRejectsOutputBomb")
	if err == nil || !strings.Contains(err.Error(), "output exceeds configured limit") {
		t.Fatalf("Run() error = %v", err)
	}
}

func TestClientFormatsTemporarySourceAndSetsLogicalPath(t *testing.T) {
	directory := t.TempDir()
	script := directory + "/compiler-helper.sh"
	if err := os.WriteFile(script, []byte("#!/bin/sh\n[ \"$TESL_LOGICAL_PATH\" = \"/workspace/demo.tesl\" ] || exit 3\nprintf formatted > \"$2\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	client := Client{Executable: script}
	formatted, result, err := client.FormatSource(context.Background(), "/workspace/demo.tesl", "source")
	if err != nil {
		t.Fatal(err)
	}
	if string(formatted) != "formatted" || result.ExitCode != 0 {
		t.Fatalf("formatted=%q exit=%d", formatted, result.ExitCode)
	}
}

func TestValidateCompilerJSONRejectsMissingAndMalformedRequiredFields(t *testing.T) {
	tests := []struct {
		name    string
		flag    string
		payload string
	}{
		{"missing diagnostics", "--check-json", `{"version":1}`},
		{"missing diagnostic fields", "--check-json", `{"version":1,"diagnostics":[{}]}`},
		{"invalid severity", "--check-json", `{"version":1,"diagnostics":[{"file":"/tmp/a.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"fatal","code":"E1","message":"bad","fix":null,"source":"parser"}]}`},
		{"missing nullable result", "--definition-json", `{"version":1}`},
		{"null array", "--completions-json", `{"version":1,"completions":null}`},
		{"incomplete location", "--type-at-json", `{"version":1,"type_at":{"type":"Int"}}`},
		{"agent diagnostic member", "--agent-context-json", `{"version":1,"file":"a.tesl","content_hash":"h","ok":false,"summary":"bad","diagnostics":[{"severity":"error","message":"bad","line":0,"col":0,"end_line":0,"end_col":1}],"symbols":[],"proof_obligations":[]}`},
		{"agent symbol member", "--agent-context-json", `{"version":1,"file":"a.tesl","content_hash":"h","ok":true,"summary":"ok","diagnostics":[],"symbols":[{"name":"f","kind":"fn"}],"proof_obligations":[]}`},
		{"agent obligation member", "--agent-context-json", `{"version":1,"file":"a.tesl","content_hash":"h","ok":false,"summary":"bad","diagnostics":[],"symbols":[],"proof_obligations":[{"code":"P1","message":"prove","line":0}]}`},
		{"semantic record field", "--semantic-json", `{"version":1,"records":[{"name":"R","fields":[{}]}],"adts":[],"functions":[],"local_bindings":[]}`},
		{"semantic variant", "--semantic-json", `{"version":1,"records":[],"adts":[{"name":"Choice","variants":[{"constructor":3}]}],"functions":[],"local_bindings":[]}`},
		{"semantic function location", "--semantic-json", `{"version":1,"records":[],"adts":[],"functions":[{"name":"f","kind":"fn","loc":{"file":"a.tesl","start_line":0,"start_col":0,"end_line":0}}],"local_bindings":[]}`},
		{"semantic binding name", "--semantic-json", `{"version":1,"records":[],"adts":[],"functions":[],"local_bindings":[{"name":"","loc":null}]}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := ValidateCompilerJSON(test.flag, []byte(test.payload)); err == nil {
				t.Fatalf("ValidateCompilerJSON(%s) accepted %s", test.flag, test.payload)
			}
		})
	}
}

func TestValidateCompilerJSONAcceptsNestedAgentAndSemanticMembers(t *testing.T) {
	agent := `{"version":1,"file":"a.tesl","content_hash":"h","ok":false,"summary":"bad","diagnostics":[{"code":"E1","severity":"error","message":"bad","line":0,"col":0,"end_line":0,"end_col":1,"fix":{"kind":"replace_line"}}],"symbols":[{"name":"f","kind":"fn","signature":"Int"}],"proof_obligations":[{"code":"P1","message":"prove","line":0,"col":0}]}`
	if err := ValidateCompilerJSON("--agent-context-json", []byte(agent)); err != nil {
		t.Fatal(err)
	}
	semantic := `{"version":1,"records":[{"name":"R","fields":[{"name":"value"}]}],"adts":[{"name":"Choice","variants":[{"constructor":"Yes"}]}],"functions":[{"name":"f","kind":"fn","loc":{"file":"a.tesl","start_line":0,"start_col":0,"end_line":0,"end_col":1}}],"local_bindings":[{"name":"x","loc":null}]}`
	if err := ValidateCompilerJSON("--semantic-json", []byte(semantic)); err != nil {
		t.Fatal(err)
	}
}

func TestValidateCompilerJSONAcceptsValidDiagnosticEnvelope(t *testing.T) {
	payload := `{"version":1,"diagnostics":[{"file":"/tmp/a.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":null,"source":"parser"}]}`
	if err := ValidateCompilerJSON("--check-json", []byte(payload)); err != nil {
		t.Fatal(err)
	}
}

func TestValidateCompilerJSONLeavesUnknownCommandSchemasAlone(t *testing.T) {
	if err := ValidateCompilerJSON("debug-inspect", []byte(`{"version":2,"stopped":false}`)); err != nil {
		t.Fatal(err)
	}
}
