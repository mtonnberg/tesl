//go:build linux

package dap

import (
	"os/exec"
	"syscall"
)

func configureChildProcess(command *exec.Cmd) {
	// Closing the editor can kill the adapter without a DAP disconnect. Ensure
	// the launched server cannot survive as an orphan and retain its port/socket.
	command.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}
