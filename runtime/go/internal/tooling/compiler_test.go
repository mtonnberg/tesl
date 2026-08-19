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

func TestClientAcceptsValidJSONFromDiagnosticExit(t *testing.T) {
	if os.Getenv("TESL_COMPILER_HELPER") == "diagnostics" {
		_, _ = os.Stdout.WriteString(`{"version":1,"diagnostics":[{"severity":"error"}]}`)
		os.Exit(1)
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
