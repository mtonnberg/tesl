package tooling

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCompilerPipesDrainAndCloseWithDescendants(t *testing.T) {
	switch os.Getenv("TESL_COMPILER_PIPE_HELPER") {
	case "leaf":
		if err := os.WriteFile(os.Getenv("TESL_COMPILER_PIPE_READY"), []byte("ready"), 0600); err != nil {
			os.Exit(2)
		}
		time.Sleep(30 * time.Second)
		os.Exit(0)
	case "root":
		child := exec.Command(testExecutable(t), "-test.run=TestCompilerPipesDrainAndCloseWithDescendants")
		child.Env = append(os.Environ(), "TESL_COMPILER_PIPE_HELPER=leaf")
		child.Stdout, child.Stderr = os.Stdout, os.Stderr
		if err := child.Start(); err != nil {
			os.Exit(2)
		}
		for i := 0; i < 200; i++ {
			if _, err := os.Stat(os.Getenv("TESL_COMPILER_PIPE_READY")); err == nil {
				_, _ = os.Stdout.WriteString(strings.Repeat("x", 256*1024) + "last byte")
				_, _ = os.Stderr.WriteString("last diagnostic")
				os.Exit(0)
			}
			time.Sleep(10 * time.Millisecond)
		}
		os.Exit(3)
	}
	client := Client{Executable: testExecutable(t), Timeout: 5 * time.Second, MaxOutput: 1 << 20,
		Environment: append(os.Environ(), "TESL_COMPILER_PIPE_HELPER=root", "TESL_COMPILER_PIPE_READY="+filepath.Join(t.TempDir(), "ready"))}
	result, err := client.Run(context.Background(), "-test.run=TestCompilerPipesDrainAndCloseWithDescendants")
	if err != nil {
		t.Fatalf("descendant held query pipes open: %v", err)
	}
	if string(result.Stdout) != strings.Repeat("x", 256*1024)+"last byte" || string(result.Stderr) != "last diagnostic" {
		t.Fatal("output was truncated at parent exit")
	}
}

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
		Executable:  testExecutable(t),
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
		Executable:  testExecutable(t),
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
		Executable:  testExecutable(t),
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

func TestClientQueriesBoundedOverlayProjectAndMapsPaths(t *testing.T) {
	project := t.TempDir()
	entry := filepath.Join(project, "A.tesl")
	dependency := filepath.Join(project, "B.tesl")
	for path, contents := range map[string]string{
		filepath.Join(project, "tesl.toml"): "[project]\nname = \"overlay-test\"\n",
		entry:                               "disk entry",
		dependency:                          "disk dependency",
	} {
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	marker := filepath.Join(t.TempDir(), "shadow-path")
	script := filepath.Join(t.TempDir(), "compiler-helper.sh")
	program := `#!/bin/sh
test -z "$TESL_LOGICAL_PATH" || exit 3
shadow=$(dirname "$2")
printf '%s' "$shadow" > "$OVERLAY_MARKER"
test "$(cat "$shadow/B.tesl")" = "unsaved dependency" || exit 4
printf '{"version":1,"diagnostics":[{"file":"%s","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":null,"source":"type"}]}' "$shadow/B.tesl"
`
	if err := os.WriteFile(script, []byte(program), 0o700); err != nil {
		t.Fatal(err)
	}
	client := Client{
		Executable:  script,
		Environment: append(os.Environ(), "TESL_LOGICAL_PATH=stale", "OVERLAY_MARKER="+marker),
	}
	payload, _, err := client.QuerySourcesJSON(context.Background(), "--check-json", entry, []SourceOverlay{
		{Path: entry, Source: "open entry"},
		{Path: dependency, Source: "unsaved dependency"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payload), dependency) || strings.Contains(string(payload), "tesl-overlay-") {
		t.Fatalf("mapped payload = %s", payload)
	}
	shadowBytes, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(string(shadowBytes)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("shadow directory was not cleaned up: %q, err=%v", shadowBytes, err)
	}
}

func TestClientRejectsOverlayBounds(t *testing.T) {
	entry := filepath.Join(t.TempDir(), "A.tesl")
	tooMany := make([]SourceOverlay, DefaultMaxOverlayDocuments+1)
	for index := range tooMany {
		tooMany[index] = SourceOverlay{Path: filepath.Join(filepath.Dir(entry), fmt.Sprintf("%d.tesl", index))}
	}
	client := Client{Executable: "unused"}
	if _, _, err := client.QuerySourcesJSON(context.Background(), "--check-json", entry, tooMany); err == nil {
		t.Fatal("QuerySourcesJSON accepted too many overlays")
	}
	if _, _, err := client.QuerySourcesJSON(context.Background(), "--check-json", entry, []SourceOverlay{{
		Path: entry, Source: strings.Repeat("x", DefaultMaxOverlayBytes+1),
	}}); err == nil {
		t.Fatal("QuerySourcesJSON accepted an oversized overlay")
	}
	if _, _, err := client.QuerySourcesJSON(context.Background(), "--check-json", strings.Repeat("x", DefaultMaxOverlayPathBytes+1), []SourceOverlay{{
		Path: entry,
	}}); err == nil {
		t.Fatal("QuerySourcesJSON accepted an oversized path")
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
		{"unknown diagnostic fix", "--check-json", `{"version":1,"diagnostics":[{"file":"/tmp/a.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":{"kind":"erase","title":"Erase"},"source":"parser"}]}`},
		{"missing diagnostic replacement", "--check-json", `{"version":1,"diagnostics":[{"file":"/tmp/a.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":{"kind":"replace_line","line":0,"title":"Replace"},"source":"parser"}]}`},
		{"inverted diagnostic fix range", "--check-json", `{"version":1,"diagnostics":[{"file":"/tmp/a.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":{"kind":"replace_range","start_line":1,"start_col":0,"end_line":0,"end_col":0,"replacement":"","title":"Replace"},"source":"parser"}]}`},
		{"malformed nested diagnostic fix", "--check-json", `{"version":1,"diagnostics":[{"file":"/tmp/a.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":{"kind":"multi","title":"Fix all","edits":[{"kind":"insert_line","line":0}]},"source":"parser"}]}`},
		{"empty multi diagnostic fix", "--check-json", `{"version":1,"diagnostics":[{"file":"/tmp/a.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":{"kind":"multi","title":"Fix all","edits":[]},"source":"parser"}]}`},
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
	agent := `{"version":1,"file":"a.tesl","content_hash":"h","ok":false,"summary":"bad","diagnostics":[{"code":"E1","severity":"error","message":"bad","line":0,"col":0,"end_line":0,"end_col":1,"fix":{"kind":"replace_line","line":0,"replacement":"fixed","title":"Replace line"}}],"symbols":[{"name":"f","kind":"fn","signature":"Int"}],"proof_obligations":[{"code":"P1","message":"prove","line":0,"col":0}]}`
	if err := ValidateCompilerJSON("--agent-context-json", []byte(agent)); err != nil {
		t.Fatal(err)
	}
	semantic := `{"version":1,"records":[{"name":"R","fields":[{"name":"value"}]}],"adts":[{"name":"Choice","variants":[{"constructor":"Yes"}]}],"functions":[{"name":"f","kind":"fn","loc":{"file":"a.tesl","start_line":0,"start_col":0,"end_line":0,"end_col":1}}],"local_bindings":[{"name":"x","loc":null}]}`
	if err := ValidateCompilerJSON("--semantic-json", []byte(semantic)); err != nil {
		t.Fatal(err)
	}
}

func TestValidateCompilerJSONAcceptsValidDiagnosticEnvelope(t *testing.T) {
	payload := `{"version":1,"diagnostics":[{"file":"/tmp/a.tesl","start":{"line":0,"col":0},"end":{"line":0,"col":1},"severity":"error","code":"E1","message":"bad","fix":{"kind":"multi","title":"Apply fixes","edits":[{"kind":"insert_line","line":0,"text":"import B"},{"kind":"replace_range","start_line":1,"start_col":0,"end_line":1,"end_col":3,"replacement":"new"}]},"source":"parser"}]}`
	if err := ValidateCompilerJSON("--check-json", []byte(payload)); err != nil {
		t.Fatal(err)
	}
}

func TestValidateCompilerJSONLeavesUnknownCommandSchemasAlone(t *testing.T) {
	if err := ValidateCompilerJSON("debug-inspect", []byte(`{"version":2,"stopped":false}`)); err != nil {
		t.Fatal(err)
	}
}
