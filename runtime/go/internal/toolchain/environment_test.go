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
	env, err := r.GoEnvironment([]string{"GOTOOLCHAIN=auto", "GOPROXY=https://proxy.example", "GOWORK=somewhere", "PATH=untouched"})
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
}

func TestEnvironmentReplacementRemovesDuplicates(t *testing.T) {
	env := Setenv([]string{"GoToolchain=auto", "GOTOOLCHAIN=go1.0", "X=a=b"}, "GOTOOLCHAIN", "local")
	if strings.Join(env, "\n") != "X=a=b\nGOTOOLCHAIN=local" {
		t.Fatalf("replacement = %v", env)
	}
}
