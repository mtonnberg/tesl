//go:build !windows

package install

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

type fileLock struct{ file *os.File }

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
	operation := unix.LOCK_SH
	if exclusive {
		operation = unix.LOCK_EX
	}
	if err := unix.Flock(int(file.Fd()), operation|unix.LOCK_NB); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("installation or version is busy: %w", err)
	}
	return &fileLock{file: file}, nil
}
func (lock *fileLock) Close() error {
	return errors.Join(unix.Flock(int(lock.file.Fd()), unix.LOCK_UN), lock.file.Close())
}
func (lock *fileLock) inherit() error {
	flags, err := unix.FcntlInt(lock.file.Fd(), unix.F_GETFD, 0)
	if err != nil {
		return err
	}
	_, err = unix.FcntlInt(lock.file.Fd(), unix.F_SETFD, flags & ^unix.FD_CLOEXEC)
	return err
}
func syncDirectory(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	err = file.Sync()
	if errors.Is(err, unix.EINVAL) || errors.Is(err, unix.ENOTSUP) {
		err = nil
	}
	return errors.Join(err, file.Close())
}
