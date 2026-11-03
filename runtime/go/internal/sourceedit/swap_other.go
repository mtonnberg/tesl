//go:build !linux

package sourceedit

import (
	"fmt"
	"os"
)

func exchangeSupported() bool { return false }
func (t *tree) exchange(_, _ string) error {
	return fmt.Errorf("atomic source exchange is not implemented on this platform")
}

func lockOwner(_ *os.File) error {
	return fmt.Errorf("source transaction locking is not implemented on this platform")
}

func (t *tree) moveNoReplace(_, _ string) error {
	return fmt.Errorf("atomic no-replace publication is not implemented on this platform")
}
