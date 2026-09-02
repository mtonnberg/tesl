//go:build !linux

package dap

import "os/exec"

func configureChildProcess(_ *exec.Cmd) {}
