package tooling

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// The direct compiler is an agent/editor entry point. Running only the first
// generated package would silently omit imported compatibility suites.
func TestBuiltCompilerTestCommand(t *testing.T) {
	_, testFile, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(testFile), "../../../.."))
	compiler := filepath.Join(root, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("compiler build unavailable")
	}
	goTool, err := exec.LookPath("go")
	if err != nil {
		t.Skip("Go toolchain unavailable")
	}
	dir := t.TempDir()
	entry := filepath.Join(dir, "entry.tesl")
	dependency := filepath.Join(dir, "dependency.tesl")
	write := func(path, source string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(dependency, "module Dependency exposing [double]\nimport Tesl.Prelude exposing [Int]\nfn double(n: Int) -> Int = n * 2\ntest \"dependency fails\" {\n  expect (double 2) == 5\n}\n")
	write(entry, "module Entry exposing [value]\nimport Tesl.Prelude exposing [Int]\nimport Dependency exposing [double]\nfn value() -> Int = double 2\ntest \"entry passes\" {\n  expect (value ()) == 4\n}\n")
	run := func(args ...string) (string, error) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, compiler, args...)
		cmd.Dir = dir
		cmd.Env = withEnvironment(os.Environ(), "TESL_REPO_ROOT", root)
		cmd.Env = withEnvironment(cmd.Env, "TESL_GO", goTool)
		// The explicit CLI request must override stale editor/debugger filters.
		cmd.Env = withEnvironment(cmd.Env, "TESL_TEST_NAME", "inherited-filter")
		cmd.Env = withEnvironment(cmd.Env, "TESL_TEST_KIND", "load-test")
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	if out, err := run("test", "--test-name", "entry passes", entry); err != nil {
		t.Fatalf("named test failed: %v\n%s", err, out)
	}
	if out, err := run("test", entry); err == nil || !strings.Contains(out, "FAIL") {
		t.Fatalf("dependency test failure disappeared: %v\n%s", err, out)
	}
	if out, err := run("test", "--test-name", "typo", entry); err == nil || !strings.Contains(out, "no generated tests") {
		t.Fatalf("unknown selection passed: %v\n%s", err, out)
	}
	if out, err := run("test", "--test-name", "STUB-01: a canned response answers without touching the network", "--test-kind", "api-test", filepath.Join(root, "tests", "http-stub-tests.tesl")); err == nil || !strings.Contains(out, "no generated tests") {
		t.Fatalf("name and kind matched different tests in the same package: %v\n%s", err, out)
	}
	for _, args := range [][]string{{"test"}, {"test", "--test-name"}, {"test", "--test-kind", "bogus", entry}, {"test", "--unknown", entry}} {
		if out, err := run(args...); err == nil || !strings.Contains(out, "usage:") {
			t.Fatalf("invalid arguments passed: %v\n%s", err, out)
		}
	}
	// A second invocation with changed source must execute again, not use Go's
	// test cache. Both input compilation and assertion failures must propagate.
	write(dependency, "module Dependency exposing [double]\nimport Tesl.Prelude exposing [Int]\nfn double(n: Int) -> Int = n * 2\ntest \"dependency passes\" {\n  expect (double 2) == 4\n}\n")
	if out, err := run("test", entry); err != nil {
		t.Fatalf("full project failed: %v\n%s", err, out)
	}
	write(entry, "module Entry exposing [bad]\nfn bad() -> Missing = 1\n")
	if out, err := run("test", entry); err == nil {
		t.Fatalf("invalid program passed:\n%s", out)
	}
	entries, err := os.ReadDir(filepath.Join(dir, ".tesl-stuff"))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "go-emit-") {
			t.Fatalf("test command leaked build directory %s", entry.Name())
		}
	}
}
