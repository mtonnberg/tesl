//go:build linux

package sourceedit

import (
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

func exchangeSupported() bool { return true }

// Exchange retains the displaced inode, including a save that raced the last
// hash check. Both parents are opened through Root before the kernel operation;
// raw multi-component renameat paths must never bypass Root's traversal checks.
func (t *tree) renameFlags(left, right string, flags uint) error {
	openParent := func(path string) (*os.File, string, error) {
		parent := filepath.Dir(path)
		info, err := t.kind(parent)
		if err != nil {
			return nil, "", err
		}
		if !info.IsDir() {
			return nil, "", fmt.Errorf("source parent is not a directory: %s", parent)
		}
		relative, err := t.relative(parent)
		if err != nil {
			return nil, "", err
		}
		file, err := openRegular(t.root, relative)
		if err != nil {
			return nil, "", err
		}
		opened, err := file.Stat()
		if err != nil || !os.SameFile(info, opened) {
			_ = file.Close()
			if err == nil {
				err = fmt.Errorf("source parent changed while opening: %s", parent)
			}
			return nil, "", err
		}
		return file, filepath.Base(path), nil
	}
	a, an, err := openParent(left)
	if err != nil {
		return err
	}
	defer func() { _ = a.Close() }()
	b, bn, err := openParent(right)
	if err != nil {
		return err
	}
	defer func() { _ = b.Close() }()
	return unix.Renameat2(int(a.Fd()), an, int(b.Fd()), bn, flags)
}

func lockOwner(file *os.File) error {
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return fmt.Errorf("source transaction is active or cannot be locked: %w", err)
	}
	return nil
}

func (t *tree) exchange(left, right string) error {
	return t.renameFlags(left, right, unix.RENAME_EXCHANGE)
}
func (t *tree) moveNoReplace(left, right string) error {
	return t.renameFlags(left, right, unix.RENAME_NOREPLACE)
}
