package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/toolchain"
)

func TestNativeProcessRunnerHelper(t *testing.T) {
	switch os.Getenv("TESL_NATIVE_RUNNER_TEST") {
	case "echo":
		for i, arg := range os.Args {
			if arg == "--" {
				_ = json.NewEncoder(os.Stdout).Encode(os.Args[i+1:])
				os.Exit(0)
			}
		}
	case "exit":
		_, _ = os.Stderr.WriteString("failed child")
		os.Exit(7)
	case "sleep":
		time.Sleep(time.Minute)
		os.Exit(0)
	case "flood":
		_, _ = os.Stdout.WriteString(strings.Repeat("x", 9<<20))
		os.Exit(0)
	}
}

func TestNativeProcessRunner(t *testing.T) {
	for _, mode := range []string{"echo", "exit", "sleep", "flood"} {
		t.Run(mode, func(t *testing.T) {
			app := New()
			var stdout, stderr bytes.Buffer
			app.Stdout, app.Stderr = &stdout, &stderr
			app.Environment = toolchain.Setenv(os.Environ(), "TESL_NATIVE_RUNNER_TEST", mode)
			args := []string{"--internal-run-process", "2", t.TempDir(), testExecutable(t), "-test.run=TestNativeProcessRunnerHelper", "--", "space value", "räksmörgås😀", "$(echo nope)", `quoted"\tail`, ""}
			err := app.Run(context.Background(), args)
			switch mode {
			case "echo":
				if err != nil {
					t.Fatal(err)
				}
				var got []string
				if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
					t.Fatal(err)
				}
				if strings.Join(got, "\x00") != strings.Join(args[6:], "\x00") {
					t.Fatalf("argv changed: %q", got)
				}
			case "exit":
				if ExitCode(err) != 7 || stderr.String() != "failed child" {
					t.Fatalf("exit=%d stderr=%s", ExitCode(err), &stderr)
				}
			case "sleep":
				if ExitCode(err) != 124 {
					t.Fatalf("timeout classification: %v (%d)", err, ExitCode(err))
				}
			case "flood":
				if err == nil || stdout.Len() != 0 {
					t.Fatal("unbounded output accepted")
				}
			}
		})
	}
	app := New()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := app.Run(ctx, []string{"--internal-run-process", "1", t.TempDir(), testExecutable(t)}); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	for _, args := range [][]string{nil, {"0", ".", "go"}, {"-1", ".", "go"}, {"86401", ".", "go"}, {"bad", ".", "go"}} {
		if err := app.runProcess(context.Background(), args); err == nil {
			t.Fatalf("accepted invalid arguments %v", args)
		}
	}
}

func testExecutable(t testing.TB) string {
	t.Helper()
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func TestNativeRunnerRejectsMissingWorkingDirectory(t *testing.T) {
	app := New()
	var output bytes.Buffer
	app.Stdout, app.Stderr = &output, &output
	err := app.runProcess(context.Background(), []string{"1", filepath.Join(t.TempDir(), "absent"), testExecutable(t)})
	if err == nil {
		t.Fatal("accepted missing cwd")
	}
}
