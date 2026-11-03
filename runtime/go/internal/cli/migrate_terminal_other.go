//go:build !linux

package cli

import (
	"context"
	"fmt"
	"os"
)

// The guarded saved-source writer currently supports Linux only. Do not start
// an interactive session on another platform before it can safely publish edits.
func migrationTerminal(*os.File) bool { return false }
func migrationWaitInput(context.Context, *os.File) error {
	return fmt.Errorf("guided source publication is unavailable on this platform")
}
