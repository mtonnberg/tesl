//go:build !windows

package childprocess

import (
	"os/exec"
	"syscall"
)

func configure(command *exec.Cmd) {
	if command.SysProcAttr == nil {
		command.SysProcAttr = &syscall.SysProcAttr{}
	}
	command.SysProcAttr.Setpgid = true
}

func attach(command *exec.Cmd, _ bool) (func(), func(), error) {
	kill := func() { _ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	return kill, kill, nil
}

func ConfigurePersistent(_ *exec.Cmd) error { return nil }
