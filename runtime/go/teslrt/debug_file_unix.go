//go:build !windows

package teslrt

import "os"

func createPrivateDebugFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600) // #nosec G304 -- caller-selected debugger endpoint file; exclusive creation refuses an existing file or symlink.
}
