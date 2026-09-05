//go:build windows

package childprocess

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

type persistentObservation struct {
	PID   int    `json:"pid"`
	Flags uint32 `json:"flags"`
}

func TestPersistentWindowsHelper(t *testing.T) {
	mode := os.Getenv("TESL_PERSISTENT_HELPER")
	if mode == "" {
		return
	}
	root := os.Getenv("TESL_PERSISTENT_DIRECTORY")
	if mode == "root" {
		for _, kind := range []string{"ordinary", "persistent"} {
			command := exec.Command(testExecutable(t), "-test.run=^TestPersistentWindowsHelper$")
			command.Env = append(os.Environ(), "TESL_PERSISTENT_HELPER="+kind)
			if kind == "persistent" {
				if err := ConfigurePersistent(command); err != nil {
					_, _ = fmt.Fprintln(os.Stderr, err)
					os.Exit(2)
				}
			}
			if err := command.Start(); err != nil {
				_, _ = fmt.Fprintln(os.Stderr, err)
				os.Exit(2)
			}
			observation := persistentObservation{PID: command.Process.Pid}
			if command.SysProcAttr != nil {
				observation.Flags = command.SysProcAttr.CreationFlags
			}
			data, err := json.Marshal(observation)
			if err != nil || os.WriteFile(filepath.Join(root, kind+".json"), data, 0600) != nil {
				os.Exit(2)
			}
			_ = command.Process.Release()
		}
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			_, ordinary := os.Stat(filepath.Join(root, "ordinary.heartbeat"))
			_, persistent := os.Stat(filepath.Join(root, "persistent.heartbeat"))
			if ordinary == nil && persistent == nil {
				os.Exit(0)
			}
			time.Sleep(10 * time.Millisecond)
		}
		os.Exit(3)
	}
	if mode != "ordinary" && mode != "persistent" {
		os.Exit(2)
	}
	// The timeout also bounds lifetime if the test runner itself is interrupted.
	deadline := time.Now().Add(30 * time.Second)
	for i := 0; time.Now().Before(deadline); i++ {
		if _, err := os.Stat(filepath.Join(root, "stop")); err == nil {
			os.Exit(0)
		}
		if err := os.WriteFile(filepath.Join(root, mode+".heartbeat"), []byte(strconv.Itoa(i)), 0600); err != nil {
			os.Exit(2)
		}
		time.Sleep(20 * time.Millisecond)
	}
	os.Exit(0)
}

func TestPersistentWindowsChildBreaksAwayOnlyFromLauncherJob(t *testing.T) {
	for _, launcher := range []bool{false, true} {
		t.Run(fmt.Sprint("launcher=", launcher), func(t *testing.T) {
			root := t.TempDir()
			command := exec.Command(testExecutable(t), "-test.run=^TestPersistentWindowsHelper$")
			command.Env = append(os.Environ(), "TESL_PERSISTENT_HELPER=root", "TESL_PERSISTENT_DIRECTORY="+root)
			var child *Child
			var err error
			if launcher {
				child, err = StartLauncher(command)
			} else {
				child, err = Start(command)
			}
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				child.Kill()
				_ = os.WriteFile(filepath.Join(root, "stop"), []byte("stop"), 0600)
				for _, kind := range []string{"ordinary", "persistent"} {
					var observation persistentObservation
					data, err := os.ReadFile(filepath.Join(root, kind+".json"))
					if err == nil && json.Unmarshal(data, &observation) == nil && observation.PID > 0 {
						if process, err := os.FindProcess(observation.PID); err == nil {
							_ = process.Kill()
							_ = process.Release()
						}
					}
				}
			})
			if err := child.Wait(); err != nil {
				t.Fatalf("helper failed: %v", err)
			}
			for _, kind := range []string{"ordinary", "persistent"} {
				var observation persistentObservation
				data, err := os.ReadFile(filepath.Join(root, kind+".json"))
				if err != nil || json.Unmarshal(data, &observation) != nil {
					t.Fatalf("child observation: %q %v", data, err)
				}
				shouldSurvive := launcher && kind == "persistent"
				if got := observation.Flags&windows.CREATE_BREAKAWAY_FROM_JOB != 0; got != shouldSurvive {
					t.Fatalf("%s breakaway flag=%v; want %v", kind, got, shouldSurvive)
				}
				time.Sleep(100 * time.Millisecond)
				before, err := os.ReadFile(filepath.Join(root, kind+".heartbeat"))
				if err != nil {
					t.Fatal(err)
				}
				time.Sleep(150 * time.Millisecond)
				after, err := os.ReadFile(filepath.Join(root, kind+".heartbeat"))
				if err != nil {
					t.Fatal(err)
				}
				if got := string(before) != string(after); got != shouldSurvive {
					t.Fatalf("%s survived=%v; want %v", kind, got, shouldSurvive)
				}
			}
		})
	}
}
