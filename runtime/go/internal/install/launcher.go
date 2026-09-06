package install

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

func IsFrontend(name string) bool {
	name = strings.TrimSuffix(filepath.Base(name), ".exe")
	for _, frontend := range Frontends {
		if name == frontend {
			return true
		}
	}
	return false
}

// RootForExecutable finds an installed manager when invoked from a custom
// prefix. Downloaded standalone installers otherwise use the per-user default.
func RootForExecutable(executable string) (string, error) {
	resolved, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return "", err
	}
	root := filepath.Dir(filepath.Dir(resolved))
	var mark marker
	if err := readJSON(filepath.Join(root, ".tesl-install.json"), &mark, 4096); err == nil && mark.Version == 1 && mark.Kind == "tesl-managed-installation" {
		return root, nil
	}
	return DefaultRoot()
}

func copyExecutable(source, destination, digest string) error {
	input, err := os.Open(source) // #nosec G304 -- read the caller's selected installer; the copied native prefix is checked against the managed SHA-256 before rename.
	if err != nil {
		return err
	}
	defer func() { _ = input.Close() }()
	var sourceReader io.Reader = input
	embedded, err := FindEmbedded(source)
	if err != nil {
		return err
	}
	if embedded != nil {
		sourceReader = io.LimitReader(input, embedded.Offset)
	}
	output, err := os.CreateTemp(filepath.Dir(destination), ".launcher-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(output.Name()) }()
	_, err = io.Copy(output, sourceReader)
	if err == nil {
		err = output.Chmod(0755)
	}
	if err == nil {
		err = output.Sync()
	}
	err = errors.Join(err, output.Close())
	if err != nil {
		return err
	}
	actual, err := hashFile(output.Name())
	if err != nil {
		return err
	}
	if actual != digest {
		return errors.New("installer executable differs from the managed launcher checksum")
	}
	return os.Rename(output.Name(), destination)
}

func (m *Manager) ensureLaunchers(mark marker) error {
	directory := filepath.Join(m.Root, "bin")
	bootstrap := filepath.Join(directory, "tesl-install"+binarySuffix())
	if info, err := os.Lstat(bootstrap); err == nil {
		if !info.Mode().IsRegular() {
			return errors.New("installer launcher is not a regular file")
		}
		digest, err := hashFile(bootstrap)
		if err != nil {
			return err
		}
		if digest != mark.LauncherSHA256 {
			return errors.New("managed installer launcher has been modified")
		}
	} else if !os.IsNotExist(err) {
		return err
	} else if err := copyExecutable(m.Executable, bootstrap, mark.LauncherSHA256); err != nil {
		return err
	}
	for _, frontend := range Frontends {
		name := filepath.Join(directory, frontend+binarySuffix())
		info, err := os.Lstat(name)
		if os.IsNotExist(err) {
			if runtime.GOOS == "windows" {
				if err := copyExecutable(bootstrap, name, mark.LauncherSHA256); err != nil {
					return err
				}
			} else {
				if err := os.Symlink("tesl-install", name); err != nil {
					return err
				}
			}
			continue
		}
		if err != nil {
			return err
		}
		if runtime.GOOS == "windows" {
			if !info.Mode().IsRegular() {
				return fmt.Errorf("managed launcher is not a regular file: %s", name)
			}
			digest, err := hashFile(name)
			if err != nil {
				return err
			}
			if digest != mark.LauncherSHA256 {
				return fmt.Errorf("managed launcher was modified: %s", name)
			}
		} else {
			target, err := os.Readlink(name)
			if err != nil || target != "tesl-install" {
				return fmt.Errorf("refusing to replace an unmanaged launcher: %s", name)
			}
		}
	}
	return syncDirectory(directory)
}

func selectedFrontend(executable, frontend string) (string, *fileLock, error) {
	if !IsFrontend(frontend) {
		return "", nil, errors.New("unrecognized frontend launcher")
	}
	resolved, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return "", nil, err
	}
	m := Manager{Root: filepath.Dir(filepath.Dir(resolved)), Executable: executable}
	lock, _, err := m.open(false, false)
	if err != nil {
		return "", nil, err
	}
	defer func() { _ = lock.Close() }()
	state, err := m.readState()
	if err != nil {
		return "", nil, err
	}
	version := os.Getenv("TESL_INSTALL_VERSION")
	if version == "" {
		version = state.Active
	}
	if version == "" {
		return "", nil, errors.New("no Tesl version is selected; run tesl-install install or select")
	}
	_, root, err := m.loadVersion(version)
	if err != nil {
		return "", nil, err
	}
	lease, err := acquireLock(filepath.Join(m.Root, "leases", version+".lock"), false)
	if err != nil {
		return "", nil, err
	}
	return filepath.Join(root, "bin", strings.TrimSuffix(filepath.Base(frontend), ".exe")+binarySuffix()), lease, nil
}

func launcherEnvironment(selected string) []string {
	environment := []string{}
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if !strings.EqualFold(key, "TESL_INSTALL_VERSION") && !strings.EqualFold(key, "TESL_TOOLCHAIN_ROOT") {
			environment = append(environment, entry)
		}
	}
	return append(environment, "TESL_TOOLCHAIN_ROOT="+filepath.Dir(filepath.Dir(selected)))
}
