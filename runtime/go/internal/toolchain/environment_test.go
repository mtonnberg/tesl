package toolchain

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOfflineGoEnvironmentUsesBundledProxyAndWritableCaches(t *testing.T) {
	r, _, root := fixture(t)
	writeFixture(t, root, "libexec/go/bin/go", "go", 0755)
	proxy := filepath.Join(root, "share", "tesl", "go proxy")
	if err := os.MkdirAll(proxy, 0755); err != nil {
		t.Fatal(err)
	}
	m := Manifest{Version: 1, ToolchainVersion: "test", SourceRevision: "test", Components: map[string]Component{
		"go": {Path: "libexec/go/bin/go", Version: "test"}, "go-modules": {Path: "share/tesl/go proxy", Version: "test"},
	}}
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	writeFixture(t, root, "share/tesl/toolchain.json", string(data), 0644)
	env, err := r.GoEnvironment([]string{"GOTOOLCHAIN=auto", "GOPROXY=https://proxy.example", "GOWORK=somewhere", "PATH=untouched",
		"GOENV=/custom/go/env", "GO111MODULE=off", "GOPRIVATE=*", "GONOPROXY=*", "GOVCS=*:all", "CGO_ENABLED=1"})
	if err != nil {
		t.Fatal(err)
	}
	values := map[string]string{}
	for _, entry := range env {
		key, value, _ := strings.Cut(entry, "=")
		values[key] = value
	}
	if values["GOTOOLCHAIN"] != "local" || values["GOWORK"] != "off" || values["GOSUMDB"] != "off" || !strings.HasPrefix(values["GOPROXY"], "file:///") || !strings.Contains(values["GOPROXY"], "go%20proxy") {
		t.Fatalf("not offline: %v", env)
	}
	if strings.HasPrefix(values["GOCACHE"], root) || strings.HasPrefix(values["GOMODCACHE"], root) || values["PATH"] != "untouched" {
		t.Fatalf("incorrect cache environment: %v", env)
	}
	for key, want := range map[string]string{"GOENV": "off", "GO111MODULE": "on", "GOPRIVATE": "", "GONOPROXY": "none", "GOVCS": "*:off", "CGO_ENABLED": "0"} {
		if got := values[key]; got != want {
			t.Fatalf("installed %s = %q, want %q", key, got, want)
		}
	}
}

func TestDevelopmentGoEnvironmentKeepsUserConfiguration(t *testing.T) {
	r, _, _ := fixture(t)
	for key, value := range map[string]string{"GOENV": "/custom/env", "CGO_ENABLED": "1", "GONOPROXY": "private.example", "GOPRIVATE": "private.example", "GOVCS": "*:all"} {
		env, err := r.GoEnvironment([]string{key + "=" + value})
		if err != nil || !strings.Contains(strings.Join(env, "\n"), key+"="+value) {
			t.Fatalf("development override %s changed: %v (%v)", key, env, err)
		}
	}
}

func TestEnvironmentReplacementRemovesDuplicates(t *testing.T) {
	env := Setenv([]string{"GoToolchain=auto", "GOTOOLCHAIN=go1.0", "X=a=b"}, "GOTOOLCHAIN", "local")
	if strings.Join(env, "\n") != "X=a=b\nGOTOOLCHAIN=local" {
		t.Fatalf("replacement = %v", env)
	}
}

func TestCompilerEnvironmentSelectsInstalledStdlib(t *testing.T) {
	r, env, root := fixture(t)
	directory := filepath.Join(root, "share/tesl/stdlib")
	if err := os.MkdirAll(directory, 0755); err != nil {
		t.Fatal(err)
	}
	manifest := Manifest{Version: 1, ToolchainVersion: "test", SourceRevision: "test", Components: map[string]Component{"stdlib": {Path: "share/tesl/stdlib", Version: "test"}}}
	data, _ := json.Marshal(manifest)
	writeFixture(t, root, "share/tesl/toolchain.json", string(data), 0644)
	selected, err := r.CompilerEnvironment([]string{"PATH=preserved", "TESL_REPO_ROOT=unrelated-checkout"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(selected, "\n"), "TESL_STDLIB_DIR="+directory) {
		t.Fatalf("stdlib not selected: %v", selected)
	}
	override := t.TempDir()
	env["TESL_STDLIB_DIR"] = override
	selected, err = r.CompilerEnvironment(nil)
	if err != nil || !strings.Contains(strings.Join(selected, "\n"), "TESL_STDLIB_DIR="+override) {
		t.Fatalf("override failed: %v, %v", selected, err)
	}
	delete(env, "TESL_STDLIB_DIR")
	if err := os.RemoveAll(directory); err != nil {
		t.Fatal(err)
	}
	if _, err := r.CompilerEnvironment(nil); err == nil {
		t.Fatal("missing installed stdlib silently ignored")
	}
}
