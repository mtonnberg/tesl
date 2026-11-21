//go:build linux

package childprocess

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

// The "owner" plays the CLI: it starts a long-running leaf through Start and records the
// leaf's pid. The test then SIGKILLs the owner — no cleanup runs — and the leaf must stop.
func TestParentDeathHelper(t *testing.T) {
	if os.Getenv("TESL_PARENT_DEATH_HELPER") != "owner" {
		return
	}
	leaf := exec.Command(testExecutable(t), "-test.run=TestProcessHelper")
	leaf.Env = append(os.Environ(), "TESL_PROCESS_HELPER=leaf")
	child, err := Start(leaf)
	if err != nil {
		os.Exit(2)
	}
	pid := strconv.Itoa(child.Command.Process.Pid)
	if err := os.WriteFile(os.Getenv("TESL_PARENT_DEATH_PID"), []byte(pid), 0600); err != nil {
		os.Exit(2)
	}
	_ = child.Wait()
}

func TestChildStopsWhenItsOwnerIsKilled(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "leaf.pid")
	owner := exec.Command(testExecutable(t), "-test.run=TestParentDeathHelper")
	owner.Env = append(os.Environ(), "TESL_PARENT_DEATH_HELPER=owner",
		"TESL_PARENT_DEATH_PID="+pidFile, "TESL_PROCESS_HEARTBEAT="+filepath.Join(dir, "heartbeat"))
	if err := owner.Start(); err != nil {
		t.Fatal(err)
	}
	var leaf int
	for deadline := time.Now().Add(5 * time.Second); leaf == 0; {
		if data, err := os.ReadFile(pidFile); err == nil && len(data) > 0 {
			leaf, _ = strconv.Atoi(string(data))
		}
		if time.Now().After(deadline) {
			_ = owner.Process.Kill()
			t.Fatal("owner never started its child")
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = owner.Process.Kill()
	_ = owner.Wait()
	for deadline := time.Now().Add(5 * time.Second); ; {
		if err := syscall.Kill(leaf, 0); err != nil {
			return
		}
		if time.Now().After(deadline) {
			_ = syscall.Kill(leaf, syscall.SIGKILL)
			t.Fatal("the child kept running after its owner was SIGKILLed")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
