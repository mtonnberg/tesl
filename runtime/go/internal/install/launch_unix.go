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
	return syscall.Exec(selected, append([]string{selected}, arguments...), launcherEnvironment(selected)) // #nosec G204 -- selectedFrontend validates the immutable managed frontend and holds its lease; arguments are literal argv.
}
