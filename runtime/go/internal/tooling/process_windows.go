//go:build windows

package tooling

import "os/exec"

func configureProcess(command *exec.Cmd) {}

func terminateProcess(command *exec.Cmd) {
	if command.Process != nil {
		_ = command.Process.Kill()
	}
}
