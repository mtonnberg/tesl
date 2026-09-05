//go:build !windows

package install

import (
	"io"
	"os/exec"
)

func passPostgresLease(path string, command *exec.Cmd) (func(), error) {
	lease, err := acquireLock(path, false)
	if err != nil {
		return nil, err
	}
	command.ExtraFiles = append(command.ExtraFiles, lease.file)
	// flock is attached to the shared open file description. Unlocking here
	// would also unlock the daemon's inherited descriptor; close only our copy.
	return func() { _ = lease.file.Close() }, nil
}

func acquirePostgresRemoval(path string) (io.Closer, error) {
	return acquireLock(path, true)
}
