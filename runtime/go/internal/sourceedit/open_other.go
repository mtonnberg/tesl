//go:build !unix

package sourceedit

import (
	"fmt"
	"os"
)

// A platform-specific no-follow, nonblocking open is required before enabling
// mutation here. Decoding remains available to editor clients on every platform.
func openRegular(_ *os.Root, _ string) (*os.File, error) {
	return nil, fmt.Errorf("guarded source filesystem operations are not implemented on this platform")
}
