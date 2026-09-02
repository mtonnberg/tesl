//go:build !windows

package tooling

import (
	"os/exec"
	"syscall"
)

func configureProcess(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func terminateProcess(command *exec.Cmd) {
	if command.Process == nil {
		return
	}
	// Kill the process group so compiler helpers cannot outlive a cancelled query.
	_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
}
