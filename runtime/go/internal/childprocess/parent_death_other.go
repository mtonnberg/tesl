//go:build !linux && !windows

package childprocess

import "syscall"

// stopWithParent has no portable equivalent outside Linux: there the CLI's own signal
// handling and process-group kill are what stop the child.
func stopWithParent(*syscall.SysProcAttr) {}
