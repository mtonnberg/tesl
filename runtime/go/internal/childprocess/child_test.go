package childprocess

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func testExecutable(t testing.TB) string {
	t.Helper()
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProcessHelper(t *testing.T) {
	mode := os.Getenv("TESL_PROCESS_HELPER")
	if mode == "" {
		return
	}
	if mode == "args" {
		if len(os.Args) < 2 {
			t.Fatal("missing helper arguments")
		}
		data, err := json.Marshal(os.Args[2:])
		if err != nil {
			os.Exit(2)
		}
		if err := os.WriteFile(os.Getenv("TESL_PROCESS_HEARTBEAT"), data, 0600); err != nil {
			os.Exit(2)
		}
		os.Exit(0)
	}
	if mode == "root" {
		child := exec.Command(testExecutable(t), "-test.run=TestProcessHelper")
		child.Env = append(os.Environ(), "TESL_PROCESS_HELPER=leaf")
		if err := child.Start(); err != nil {
			os.Exit(2)
		}
		defer func() { _ = child.Process.Kill(); _ = child.Wait() }()
		if os.Getenv("TESL_PROCESS_ROOT_EXIT") == "1" {
			for i := 0; i < 500; i++ {
				if _, err := os.Stat(os.Getenv("TESL_PROCESS_HEARTBEAT")); err == nil {
					os.Exit(0)
				}
				time.Sleep(10 * time.Millisecond)
			}
			os.Exit(3)
		}
		_ = child.Wait()
		return
	}
	if mode != "leaf" {
		os.Exit(2)
	}
	for i := 0; ; i++ {
		if err := os.WriteFile(os.Getenv("TESL_PROCESS_HEARTBEAT"), []byte(fmt.Sprint(i)), 0600); err != nil {
			os.Exit(2)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestDescendantsStopOnCancellationAndParentExit(t *testing.T) {
	for _, exit := range []bool{false, true} {
		t.Run(fmt.Sprint("exit=", exit), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "heartbeat")
			command := exec.Command(testExecutable(t), "-test.run=TestProcessHelper")
			command.Env = append(os.Environ(), "TESL_PROCESS_HELPER=root", "TESL_PROCESS_HEARTBEAT="+path)
			if exit {
				command.Env = append(command.Env, "TESL_PROCESS_ROOT_EXIT=1")
			}
			child, err := Start(command)
			if err != nil {
				t.Fatal(err)
			}
			defer child.Kill()
			deadline := time.Now().Add(5 * time.Second)
			for {
				if _, err := os.Stat(path); err == nil {
					break
				}
				if time.Now().After(deadline) {
					child.Kill()
					_ = child.Wait()
					t.Fatal("descendant never started")
				}
				time.Sleep(10 * time.Millisecond)
			}
			if !exit {
				child.Kill()
			}
			done := make(chan error, 1)
			go func() { done <- child.Wait() }()
			select {
			case err := <-done:
				if exit && err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("child did not terminate")
			}
			time.Sleep(100 * time.Millisecond)
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			time.Sleep(100 * time.Millisecond)
			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(before) != string(after) {
				t.Fatal("descendant survived process ownership cleanup")
			}
		})
	}
}

func TestArgumentsRemainLiteral(t *testing.T) {
	path := filepath.Join(t.TempDir(), "arguments")
	literal := "literal argument $() ; & å😀"
	command := exec.Command(testExecutable(t), "-test.run=TestProcessHelper", literal)
	command.Env = append(os.Environ(), "TESL_PROCESS_HELPER=args", "TESL_PROCESS_HEARTBEAT="+path)
	child, err := Start(command)
	if err != nil {
		t.Fatal(err)
	}
	if err := child.Wait(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var args []string
	if err := json.Unmarshal(data, &args); err != nil {
		t.Fatal(err)
	}
	if len(args) != 1 || args[0] != literal {
		t.Fatalf("arguments altered: %q", args)
	}
}
