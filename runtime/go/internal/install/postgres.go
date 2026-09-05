package install

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
)

// ConfigurePostgresLease passes an OS-owned version lease to pg_ctl and its
// postmaster. Closing the caller's copy after pg_ctl exits leaves the server's
// inherited reference alive until the server exits, without PID files or a
// supervisor process. Unmanaged/portable toolchains do not need this lease.
func ConfigurePostgresLease(command *exec.Cmd, toolchainRoot string) (func(), error) {
	noop := func() {}
	if toolchainRoot == "" {
		return noop, nil
	}
	root, err := filepath.EvalSymlinks(toolchainRoot)
	if err != nil {
		return nil, err
	}
	version := filepath.Base(root)
	versions := filepath.Dir(root)
	if filepath.Base(versions) != "versions" || !validVersion(version) {
		return noop, nil
	}
	manager := Manager{Root: filepath.Dir(versions)}
	if _, err := os.Lstat(filepath.Join(manager.Root, ".tesl-install.json")); os.IsNotExist(err) {
		return noop, nil
	} else if err != nil {
		return nil, err
	}
	lock, _, err := manager.open(false, false)
	if err != nil {
		return nil, err
	}
	defer func() { _ = lock.Close() }()
	_, installedRoot, err := manager.loadVersion(version)
	if err != nil {
		return nil, err
	}
	if installedRoot != root {
		return nil, errors.New("PostgreSQL toolchain does not match its managed version")
	}
	return passPostgresLease(filepath.Join(manager.Root, "leases", version+".postgres.lock"), command)
}
