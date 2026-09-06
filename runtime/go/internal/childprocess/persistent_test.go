package childprocess

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestPersistentOutputHelper(t *testing.T) {
	mode := os.Getenv("TESL_PERSISTENT_OUTPUT_MODE")
	if mode == "" {
		return
	}
	root := os.Getenv("TESL_PERSISTENT_OUTPUT_ROOT")
	if mode == "daemon" {
		input, err := io.ReadAll(os.Stdin)
		if err != nil || os.WriteFile(filepath.Join(root, "stdin"), input, 0600) != nil {
			os.Exit(2)
		}
		deadline := time.Now().Add(30 * time.Second)
		for i := 0; time.Now().Before(deadline); i++ {
			if err := os.WriteFile(filepath.Join(root, "heartbeat"), []byte(strconv.Itoa(i)), 0600); err != nil {
				os.Exit(2)
			}
			time.Sleep(20 * time.Millisecond)
		}
		os.Exit(0)
	}
	next := "starter"
	if mode == "starter" {
		next = "daemon"
	} else if mode != "caller" {
		os.Exit(2)
	}
	command := exec.Command(testExecutable(t), "-test.run=^TestPersistentOutputHelper$")
	command.Env = append(os.Environ(), "TESL_PERSISTENT_OUTPUT_MODE="+next)
	// Real file handles reproduce a CLI invoked with captured output; using
	// bytes.Buffer here would conceal the inherited caller-pipe regression.
	command.Stdin, command.Stdout, command.Stderr = os.Stdin, os.Stdout, os.Stderr
	if mode == "caller" {
		if err := RunPersistent(command); err != nil {
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				os.Exit(exit.ExitCode())
			}
			_, _ = fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		os.Exit(0)
	}
	if err := command.Start(); err != nil {
		os.Exit(2)
	}
	if err := os.WriteFile(filepath.Join(root, "pid"), []byte(strconv.Itoa(command.Process.Pid)), 0600); err != nil {
		_ = command.Process.Kill()
		os.Exit(2)
	}
	_ = command.Process.Release()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(root, "heartbeat")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			os.Exit(3)
		}
		time.Sleep(10 * time.Millisecond)
	}
	_, _ = fmt.Fprintln(os.Stdout, "starter stdout")
	_, _ = fmt.Fprintln(os.Stderr, "starter stderr")
	code, _ := strconv.Atoi(os.Getenv("TESL_PERSISTENT_OUTPUT_EXIT"))
	os.Exit(code)
}

func TestPersistentStarterReleasesCallerPipesAndPreservesStatus(t *testing.T) {
	for _, code := range []int{0, 7} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			root := t.TempDir()
			t.Cleanup(func() {
				data, err := os.ReadFile(filepath.Join(root, "pid"))
				if err != nil {
					return
				}
				pid, err := strconv.Atoi(string(data))
				if err == nil && pid > 0 {
					if process, err := os.FindProcess(pid); err == nil {
						_ = process.Kill()
						_, _ = process.Wait()
						_ = process.Release()
					}
				}
			})
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, testExecutable(t), "-test.run=^TestPersistentOutputHelper$")
			command.Env = append(os.Environ(), "TESL_PERSISTENT_OUTPUT_MODE=caller",
				"TESL_PERSISTENT_OUTPUT_ROOT="+root, "TESL_PERSISTENT_OUTPUT_EXIT="+strconv.Itoa(code))
			command.Stdin = strings.NewReader("caller's input must not reach the daemon")
			command.WaitDelay = 3 * time.Second
			output, err := command.CombinedOutput()
			var exit *exec.ExitError
			if (code == 0 && err != nil) || (code != 0 && (!errors.As(err, &exit) || exit.ExitCode() != code)) {
				t.Fatalf("starter status %d: %v\n%s", code, err, output)
			}
			for _, message := range []string{"starter stdout", "starter stderr"} {
				if !strings.Contains(string(output), message) {
					t.Fatalf("lost startup output %q: %s", message, output)
				}
			}
			input, err := os.ReadFile(filepath.Join(root, "stdin"))
			if err != nil || len(input) != 0 {
				t.Fatalf("daemon inherited caller stdin: %q, %v", input, err)
			}
			before, err := os.ReadFile(filepath.Join(root, "heartbeat"))
			if err != nil {
				t.Fatal(err)
			}
			deadline := time.Now().Add(3 * time.Second)
			for {
				after, err := os.ReadFile(filepath.Join(root, "heartbeat"))
				if err == nil && len(after) > 0 && string(after) != string(before) {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("daemon did not survive starter and caller exit")
				}
				time.Sleep(20 * time.Millisecond)
			}
		})
	}
}

func TestPersistentStarterPreservesStartAndCancellationErrors(t *testing.T) {
	command := exec.Command(filepath.Join(t.TempDir(), "missing starter"))
	if err := RunPersistent(command); err == nil {
		t.Fatal("missing starter reported success")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	command = exec.CommandContext(ctx, testExecutable(t), "-test.run=^TestPersistentOutputHelper$")
	if err := RunPersistent(command); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled starter: %v", err)
	}
}
