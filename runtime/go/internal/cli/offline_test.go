package cli

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/toolchain"
)

// This exercises the module-bundle slice of installation, using a copy of the
// runner's SDK/compiler. Native dependency relocation and managed PostgreSQL
// distribution are separate gates; this test must not claim to prove them.
func TestOfflineModuleBundleWorkflow(t *testing.T) {
	bundle := os.Getenv("TESL_TEST_MODULE_BUNDLE")
	if bundle == "" {
		t.Skip("set TESL_TEST_MODULE_BUNDLE to the generated module bundle")
	}
	_, source, _, _ := runtime.Caller(0)
	repo := filepath.Clean(filepath.Join(filepath.Dir(source), "../../../.."))
	work := t.TempDir()
	// Go marks extracted module directories read-only, including failed runs.
	t.Cleanup(func() {
		_ = filepath.WalkDir(work, func(path string, entry fs.DirEntry, err error) error {
			if err == nil && entry.IsDir() {
				return os.Chmod(path, 0755)
			}
			return err
		})
	})
	install := filepath.Join(work, "installation å with spaces")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	goRoot, err := exec.CommandContext(ctx, "go", "env", "GOROOT").Output()
	if err != nil {
		t.Fatalf("locate runner Go SDK: %v", err)
	}
	suffix := ""
	if runtime.GOOS == "windows" {
		suffix = ".exe"
	}
	copyFile := func(from, to string, mode os.FileMode) {
		t.Helper()
		data, err := os.ReadFile(from)
		if err != nil {
			t.Fatal(err)
		}
		writeProjectFile(t, install, to, string(data))
		if err := os.Chmod(filepath.Join(install, to), mode); err != nil {
			t.Fatal(err)
		}
	}
	copyFile(filepath.Join(repo, "compiler/_build/default/bin/main.exe"), "libexec/tesl/compiler"+suffix, 0755)
	for destination, from := range map[string]string{
		"libexec/tesl/go": strings.TrimSpace(string(goRoot)), "share/tesl/templates": filepath.Join(repo, "templates"),
		"share/tesl/stdlib": filepath.Join(repo, "tesl"), "share/tesl/go-modules": filepath.Join(bundle, "proxy"),
	} {
		if err := os.CopyFS(filepath.Join(install, destination), os.DirFS(from)); err != nil {
			t.Fatal(err)
		}
	}
	manifest := toolchain.Manifest{Version: 1, ToolchainVersion: "offline-test", SourceRevision: "test", Components: map[string]toolchain.Component{
		"compiler":   {Path: "libexec/tesl/compiler" + suffix, Version: "test"},
		"go":         {Path: "libexec/tesl/go/bin/go" + suffix, Version: "test"},
		"templates":  {Path: "share/tesl/templates", Version: "test"},
		"stdlib":     {Path: "share/tesl/stdlib", Version: "test"},
		"go-modules": {Path: "share/tesl/go-modules", Version: "test"},
	}}
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	writeProjectFile(t, install, "share/tesl/toolchain.json", string(data))
	if runtime.GOOS != "windows" {
		if err := filepath.WalkDir(install, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			return os.Chmod(path, info.Mode().Perm()&0555)
		}); err != nil {
			t.Fatal(err)
		}
	}
	before := installationFiles(t, install)
	app := New()
	app.Directory = filepath.Join(work, "projects")
	if err := os.MkdirAll(app.Directory, 0755); err != nil {
		t.Fatal(err)
	}
	projectRoot := app.Directory
	output := &synchronizedOutput{}
	app.Stdout, app.Stderr = output, output
	// Keep the runner's loader environment for its native compiler, while
	// removing every discovery override that could mask missing installed files.
	environment := []string{}
	for _, value := range os.Environ() {
		if !strings.HasPrefix(strings.ToUpper(value), "TESL_") {
			environment = append(environment, value)
		}
	}
	for key, value := range map[string]string{
		"TESL_TOOLCHAIN_ROOT": install, "TESL_NO_DB_AUTOSTART": "1", "HOME": filepath.Join(work, "home"),
		"USERPROFILE": filepath.Join(work, "home"), "GOCACHE": filepath.Join(work, "build cache"),
		"APPDATA": filepath.Join(work, "config"), "LOCALAPPDATA": filepath.Join(work, "local"),
		"XDG_CONFIG_HOME": filepath.Join(work, "config"), "XDG_CACHE_HOME": filepath.Join(work, "cache"),
		"GOPROXY": "https://invalid.invalid", "GONOPROXY": "*", "GOPRIVATE": "*",
		"HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1", "NO_PROXY": "",
		"CGO_ENABLED": "1", "CC": "missing-host-C-compiler", "CXX": "missing-host-CXX-compiler",
		"GOENV": filepath.Join(work, "unrelated-go-env"),
	} {
		environment = toolchain.Setenv(environment, key, value)
	}
	app.Environment = environment
	app.Resolver.Getenv = func(key string) string { value, _ := environmentValue(app.Environment, key); return value }
	freshModules := func(name string) {
		app.Environment = toolchain.Setenv(app.Environment, "GOMODCACHE", filepath.Join(work, "module caches", name))
	}
	run := func(t *testing.T, args ...string) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		if err := app.Run(ctx, args); err != nil {
			t.Fatalf("%v: %v\n%s", args, err, output.String())
		}
	}
	for _, template := range []string{"minimal", "api"} {
		t.Run(template, func(t *testing.T) {
			freshModules(template)
			app.Directory = projectRoot
			run(t, "init", template, "--template", template, "--postgres", "existing", "--yes", "--no-git")
			app.Directory = filepath.Join(projectRoot, template)
			run(t, "agent-context", "app.tesl")
			run(t, "check")
			run(t, "test")
			run(t, "build", "--local")
		})
	}
	app.Directory = projectRoot
	writeProjectFile(t, projectRoot, "password.tesl", `module Password exposing []
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.Crypto exposing [Crypto.hashPassword, Crypto.needsRehash]
import Tesl.Random exposing [random]
secret Password = String
test "bundled password dependency" requires [random] {
  let plaintext = Password "correct-horse-battery"
  let hash = Crypto.hashPassword plaintext
  expect Crypto.needsRehash hash == False
}
`)
	run(t, "agent-context", "password.tesl")
	t.Run("password", func(t *testing.T) {
		freshModules("password")
		run(t, "test", "password.tesl")
	})
	t.Run("windows-debug-build", func(t *testing.T) {
		freshModules("windows-debug")
		out := filepath.Join(projectRoot, "debug output")
		run(t, "--debug", "password.tesl", "--out", out)
		env, err := app.Resolver.GoEnvironment(app.Environment)
		if err != nil {
			t.Fatal(err)
		}
		env = toolchain.Setenv(toolchain.Setenv(env, "GOOS", "windows"), "GOARCH", "amd64")
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		if err := app.invoke(ctx, "go", out, env, "build", "./..."); err != nil {
			t.Fatalf("debug build: %v\n%s", err, output.String())
		}
	})
	archives, err := filepath.Glob(filepath.Join(install, "share/tesl/go-modules/golang.org/x/crypto/@v/*.zip"))
	if err != nil || len(archives) != 1 {
		t.Fatalf("expected the locked password module archive: %v %v", archives, err)
	}
	archive := archives[0]
	original, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Dir(archive), 0755); err != nil {
		t.Fatal(err)
	}
	for _, failure := range []string{"missing", "corrupt"} {
		t.Run(failure, func(t *testing.T) {
			if err := os.Remove(archive); err != nil {
				t.Fatal(err)
			}
			defer func() {
				if err := os.WriteFile(archive, original, 0644); err != nil {
					t.Error(err)
				}
			}()
			if failure == "corrupt" {
				if err := os.WriteFile(archive, []byte("corrupt zip"), 0644); err != nil {
					t.Fatal(err)
				}
			}
			freshModules(failure)
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			previousOutput := len(output.String())
			if err := app.Run(ctx, []string{"test", "password.tesl"}); err == nil || ctx.Err() != nil {
				t.Fatalf("bad bundled module must fail promptly without downloading: %v", err)
			}
			diagnostic := output.String()[previousOutput:]
			if !strings.Contains(diagnostic, "golang.org/x/crypto") || !strings.Contains(diagnostic, ".zip") && !strings.Contains(diagnostic, "zip:") {
				t.Fatalf("failure must identify the unavailable bundled archive: %s", diagnostic)
			}
		})
	}
	after := installationFiles(t, install)
	if len(before) != len(after) {
		t.Fatalf("installation file count changed: %d to %d", len(before), len(after))
	}
	for path, hash := range before {
		if after[path] != hash {
			t.Fatalf("installed file changed: %s", path)
		}
	}
}

func installationFiles(t *testing.T, root string) map[string]string {
	t.Helper()
	files := map[string]string{}
	if err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		data, err := os.ReadFile(path)
		if err == nil {
			files[path] = fmt.Sprintf("%x", sha256.Sum256(data))
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return files
}
