package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/toolchain"
)

// Exercise the actual CLI entrypoint and a child compiler as separate native
// processes. The fixture is also executable on Windows without a shell.
func TestMain(m *testing.M) {
	if code, err := strconv.Atoi(os.Getenv("TESL_CLI_ENTRYPOINT_TEST")); err == nil && len(os.Args) > 1 {
		switch os.Args[1] {
		case "--cli-under-test":
			os.Args = append(os.Args[:1], os.Args[2:]...)
			main()
		case "--check-json":
			fmt.Fprintln(os.Stdout, `{"version":1,"diagnostics":[]}`)
			fmt.Fprintln(os.Stderr, "compiler diagnostic")
			if code < 0 {
				process, err := os.FindProcess(os.Getpid())
				if err != nil {
					os.Exit(111)
				}
				if err := process.Signal(syscall.Signal(-code)); err != nil {
					os.Exit(111)
				}
				time.Sleep(time.Minute)
				os.Exit(111)
			}
			os.Exit(code)
		}
	}
	os.Exit(m.Run())
}

func TestCLIForwardsCompilerStatusAndStreams(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	codes := []int{0, 1, 2, 7, 124, 125, 255}
	if runtime.GOOS != "windows" {
		codes = append(codes, -int(syscall.SIGTERM), -int(syscall.SIGKILL))
	}
	for _, code := range codes {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, executable, "--cli-under-test", "check-json", "source å with spaces.tesl")
			command.Env = toolchain.Setenv(os.Environ(), "TESL_CLI_ENTRYPOINT_TEST", strconv.Itoa(code))
			for _, key := range []string{"TESL_TOOLCHAIN_ROOT", "TESL_STDLIB_DIR"} {
				command.Env = toolchain.Setenv(command.Env, key, "")
			}
			command.Env = toolchain.Setenv(command.Env, "TESL_COMPILER", executable)
			var stdout, stderr bytes.Buffer
			command.Stdout, command.Stderr = &stdout, &stderr
			err := command.Run()
			if ctx.Err() != nil {
				t.Fatal(ctx.Err())
			}
			if command.ProcessState == nil {
				t.Fatalf("CLI did not start: %v", err)
			}
			want := code
			if code < 0 {
				want = 128 - code
			}
			if command.ProcessState.ExitCode() != want || stdout.String() != "{\"version\":1,\"diagnostics\":[]}\n" || stderr.String() != "compiler diagnostic\n" {
				t.Fatalf("exit=%d stdout=%q stderr=%q (%v)", command.ProcessState.ExitCode(), &stdout, &stderr, err)
			}
		})
	}
}

func TestCLIReportsItsOwnErrors(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, "--cli-under-test", "unknown-command")
	command.Env = toolchain.Setenv(os.Environ(), "TESL_CLI_ENTRYPOINT_TEST", "0")
	output, err := command.CombinedOutput()
	if err == nil || !strings.Contains(string(output), "tesl: unknown command: unknown-command") {
		t.Fatalf("missing CLI diagnostic: %q (%v)", output, err)
	}
}
