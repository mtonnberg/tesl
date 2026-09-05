//go:build !windows

package teslrt

import "os"

func createPrivateDebugFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
}
