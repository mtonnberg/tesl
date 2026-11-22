//go:build linux

package childprocess

import "syscall"

// stopWithParent asks the kernel to send the child SIGTERM when the CLI that started it dies.
// A CLI that is SIGKILLed (or crashes) runs no cleanup, and `tesl run`'s server then kept
// serving — and holding its port — with no parent. SIGTERM rather than SIGKILL so a server
// still shuts down gracefully.
func stopWithParent(attributes *syscall.SysProcAttr) {
	attributes.Pdeathsig = syscall.SIGTERM
}
