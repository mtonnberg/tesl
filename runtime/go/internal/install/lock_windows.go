//go:build windows

package install

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/windows"
)

type fileLock struct {
	file    *os.File
	overlap windows.Overlapped
}

func acquireLock(path string, exclusive bool) (*fileLock, error) {
	if info, err := os.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return nil, fmt.Errorf("lock path is not a regular file: %s", path)
	} else if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	lock := &fileLock{file: file}
	flags := uint32(windows.LOCKFILE_FAIL_IMMEDIATELY)
	if exclusive {
		flags |= windows.LOCKFILE_EXCLUSIVE_LOCK
	}
	if err := windows.LockFileEx(windows.Handle(file.Fd()), flags, 0, 1, 0, &lock.overlap); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("installation or version is busy: %w", err)
	}
	return lock, nil
}
func (lock *fileLock) Close() error {
	return errors.Join(windows.UnlockFileEx(windows.Handle(lock.file.Fd()), 0, 1, 0, &lock.overlap), lock.file.Close())
}
func syncDirectory(string) error { return nil }
