//go:build windows

package install

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

func openPostgresLease(path string, exclusive bool) (*os.File, error) {
	if info, err := os.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return nil, fmt.Errorf("PostgreSQL lease is not a regular file: %s", path)
	} else if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	access := uint32(windows.GENERIC_READ)
	sharing := uint32(windows.FILE_SHARE_READ)
	attributes := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), InheritHandle: 1}
	if exclusive {
		access |= windows.GENERIC_WRITE
		sharing = 0
		attributes.InheritHandle = 0
	}
	handle, err := windows.CreateFile(name, access, sharing, &attributes, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(handle), path), nil
}

func passPostgresLease(path string, command *exec.Cmd) (func(), error) {
	file, err := openPostgresLease(path, false)
	if err != nil {
		return nil, err
	}
	if command.SysProcAttr == nil {
		command.SysProcAttr = &syscall.SysProcAttr{}
	}
	command.SysProcAttr.AdditionalInheritedHandles = append(command.SysProcAttr.AdditionalInheritedHandles, syscall.Handle(file.Fd()))
	return func() { _ = file.Close() }, nil
}

func acquirePostgresRemoval(path string) (io.Closer, error) {
	return openPostgresLease(path, true)
}
