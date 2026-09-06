//go:build unix

package sourceedit

import (
	"os"
	"syscall"
)

// Nonblocking prevents a concurrently substituted FIFO from hanging a guarded
// read; fstat must still establish a regular file/directory before reading it.
func openRegular(root *os.Root, path string) (*os.File, error) {
	return root.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW, 0)
}
