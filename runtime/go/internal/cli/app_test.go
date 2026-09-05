package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/toolchain"
)

func fakeApp(t *testing.T) (*App, *[]Invocation) {
	t.Helper()
	root := t.TempDir()
	executable := filepath.Join(root, "tesl")
	if err := os.WriteFile(executable, []byte("tool"), 0755); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"TESL_COMPILER": executable, "TESL_GO": executable}
	resolver := toolchain.Resolver{Executable: executable, GOOS: runtime.GOOS, Getenv: func(key string) string { return env[key] }, LookPath: func(string) (string, error) { return executable, nil }}
	calls := []Invocation{}
	app := &App{Resolver: resolver, Directory: root, Stdin: strings.NewReader(""), Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}, Environment: []string{"PATH=/explicit/tools"}}
	app.Execute = func(_ context.Context, inv Invocation) error { calls = append(calls, inv); return nil }
	return app, &calls
}

func writeProjectFile(t *testing.T, root, name, source string) {
	t.Helper()
	path := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestCompilerCommandParity(t *testing.T) {
	for _, sample := range []struct{ args, want []string }{
		{[]string{"check", "a file.tesl"}, []string{"--check", "a file.tesl"}},
		{[]string{"format", "a.tesl"}, []string{"--fmt", "a.tesl"}},
		{[]string{"emit", "go", "a.tesl", "--out", "a directory"}, []string{"a.tesl", "--out", "a directory"}},
		{[]string{"compile", "--backend", "go", "a.tesl", "--out", "generated"}, []string{"a.tesl", "--out", "generated"}},
		{[]string{"agent-context", "a.tesl"}, []string{"agent-context", "a.tesl"}},
		{[]string{"completions-json", "a.tesl", "3", "4"}, []string{"--completions-json", "a.tesl", "3", "4"}},
		{[]string{"--type-definition-json", "a.tesl", "3", "4"}, []string{"--type-definition-json", "a.tesl", "3", "4"}},
		{[]string{"generate", "ts", "a.tesl", "--out", "a.ts"}, []string{"--generate-ts", "a.tesl", "--out", "a.ts"}},
		{[]string{"mutate", "a.tesl", "b.tesl"}, []string{"--mutate", "a.tesl", "b.tesl"}},
		{[]string{"help", "manual", "proofs"}, []string{"--help", "manual", "proofs"}},
	} {
		t.Run(strings.Join(sample.args, " "), func(t *testing.T) {
			app, calls := fakeApp(t)
			if err := app.Run(context.Background(), sample.args); err != nil {
				t.Fatal(err)
			}
			if len(*calls) != 1 || !reflect.DeepEqual((*calls)[0].Args, sample.want) {
				t.Fatalf("forwarded: %+v", *calls)
			}
		})
	}
}

func TestValidateStopsAtFirstFailure(t *testing.T) {
	for fail := 0; fail < 3; fail++ {
		app, calls := fakeApp(t)
		execute := app.Execute
		app.Execute = func(ctx context.Context, inv Invocation) error {
			_ = execute(ctx, inv)
			if len(*calls) == fail+1 {
				return fmt.Errorf("phase failed")
			}
			return nil
		}
		if err := app.Run(context.Background(), []string{"validate", "a.tesl"}); err == nil {
			t.Fatal("ignored compiler failure")
		}
		if len(*calls) != fail+1 {
			t.Fatalf("ran after failure: %v", *calls)
		}
	}
}

func TestManifestEntrypointFromNestedWorkingDirectory(t *testing.T) {
	app, calls := fakeApp(t)
	root := app.Directory
	writeProjectFile(t, root, "tesl.toml", "[project]\nentrypoint = \"src/my app.tesl\"\n")
	writeProjectFile(t, root, "src/my app.tesl", "module App exposing []\n")
	app.Directory = filepath.Join(root, "src")
	if err := app.Run(context.Background(), []string{"check"}); err != nil {
		t.Fatal(err)
	}
	if got := (*calls)[0].Args[1]; got != filepath.Join(root, "src/my app.tesl") {
		t.Fatal(got)
	}
	if !strings.Contains(app.Stderr.(*bytes.Buffer).String(), "using") {
		t.Fatal("implicit entrypoint not reported")
	}
}

func TestManifestValuesAndRejections(t *testing.T) {
	manifest, err := ParseManifest("# heading\r\n[project] # note\r\nname = \"å # = value\" # note\r\nentrypoint = app.tesl\r\n[env]\r\nPORT = 8080\r\nEMPTY = \"\"\r\n")
	if err != nil || manifest.value("project", "name", "") != "å # = value" || manifest.value("env", "EMPTY", "wrong") != "" {
		t.Fatalf("manifest: %v, %v", manifest, err)
	}
	for _, source := range []string{"a = 1", "[project", "[project]\na = \"unterminated", "[project]\na = [1,2]", "[project]\na = 1\na = 2", "[project]\na = \"x\"junk"} {
		if _, err := ParseManifest(source); err == nil {
			t.Fatalf("accepted malformed manifest: %s", source)
		}
	}
}

func TestDotenvIsDataAndProcessEnvironmentWins(t *testing.T) {
	app, _ := fakeApp(t)
	app.Environment = append(app.Environment, "A=process", "EMPTY=")
	writeProjectFile(t, app.Directory, ".env", "A=file\nEMPTY=must-not-replace\nSECRET='literal $(never execute); & # test'\nexport B=two words\nnot valid\n")
	env, err := app.projectEnvironment(context.Background(), app.Directory, false)
	if err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{"A": "process", "EMPTY": "", "SECRET": "literal $(never execute); & # test", "B": "two words"} {
		if got, _ := environmentValue(env, key); got != want {
			t.Fatalf("%s = %q", key, got)
		}
	}
	app.Environment = append(app.Environment, "TESL_NO_DOTENV=1")
	env, err = app.projectEnvironment(context.Background(), app.Directory, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, found := environmentValue(env, "SECRET"); found {
		t.Fatal("dotenv opt-out ignored")
	}
}

func TestCleanPreservesProjectDataAndUnrelatedFiles(t *testing.T) {
	app, _ := fakeApp(t)
	for _, name := range []string{".tesl-stuff/build/a", ".tesl-stuff/tesl.abc/a", ".tesl-stuff/go-build/a", ".tesl-stuff/debug.token", ".tesl-stuff/notes", ".tesl-postgres/data/important", "app.tesl", ".env"} {
		writeProjectFile(t, app.Directory, name, "keep")
	}
	if err := app.Run(context.Background(), []string{"clean"}); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{".tesl-stuff/build", ".tesl-stuff/tesl.abc", ".tesl-stuff/go-build", ".tesl-stuff/debug.token"} {
		if _, err := os.Stat(filepath.Join(app.Directory, name)); !os.IsNotExist(err) {
			t.Fatalf("not cleaned: %s", name)
		}
	}
	for _, name := range []string{".tesl-stuff/notes", ".tesl-postgres/data/important", "app.tesl", ".env"} {
		if _, err := os.Stat(filepath.Join(app.Directory, name)); err != nil {
			t.Fatalf("removed user data %s", name)
		}
	}
}

func TestScaffoldRealTemplatesAndDoesNotOverwrite(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	repo := filepath.Clean(filepath.Join(filepath.Dir(file), "../../../.."))
	for _, template := range []string{"minimal", "api"} {
		app, _ := fakeApp(t)
		getenv := app.Resolver.Getenv
		app.Resolver.Getenv = func(key string) string {
			if key == "TESL_TEMPLATES_DIR" {
				return filepath.Join(repo, "templates")
			}
			return getenv(key)
		}
		args := []string{"init", "new app å", "--template", template, "--postgres", "existing", "--yes", "--no-git"}
		if err := app.Run(context.Background(), args); err != nil {
			t.Fatal(err)
		}
		root := filepath.Join(app.Directory, "new app å")
		manifest, err := readManifest(root)
		if err != nil {
			t.Fatal(err)
		}
		if manifest.value("project", "name", "") != "new app å" || manifest.value("database", "mode", "") != "existing" {
			t.Fatalf("manifest: %v", manifest)
		}
		data, err := os.ReadFile(filepath.Join(root, ".vscode", "launch.json"))
		if err != nil {
			t.Fatal(err)
		}
		var launch struct {
			Configurations []map[string]any `json:"configurations"`
		}
		if err := json.Unmarshal(data, &launch); err != nil {
			t.Fatal(err)
		}
		if len(launch.Configurations) != 2 {
			t.Fatal("missing debugger profiles")
		}
		writeProjectFile(t, root, "app.tesl", "user changes")
		if err := app.Run(context.Background(), args); err == nil {
			t.Fatal("overwrote existing project")
		}
		data, _ = os.ReadFile(filepath.Join(root, "app.tesl"))
		if string(data) != "user changes" {
			t.Fatal("lost existing source")
		}
	}
}

func TestTemporaryCompilationCleansAfterCompilerFailure(t *testing.T) {
	app, _ := fakeApp(t)
	app.Execute = func(context.Context, Invocation) error { return fmt.Errorf("compiler error") }
	if err := app.Run(context.Background(), []string{"run", "app.tesl"}); err == nil {
		t.Fatal("ignored compilation failure")
	}
	entries, err := os.ReadDir(filepath.Join(app.Directory, ".tesl-stuff"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("temporary output leaked: %v", entries)
	}
}
