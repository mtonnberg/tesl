//go:build !windows

package install

import (
	"syscall"
)

func Launch(executable, frontend string, arguments []string) error {
	selected, lease, err := selectedFrontend(executable, frontend)
	if err != nil {
		return err
	}
	defer func() { _ = lease.Close() }()
	if err := lease.inherit(); err != nil {
		return err
	}
	return syscall.Exec(selected, append([]string{selected}, arguments...), launcherEnvironment(selected))
}
