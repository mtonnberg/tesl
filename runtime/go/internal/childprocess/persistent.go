package childprocess

import (
	"io"
	"os/exec"
	"time"
)

// startupOutput deliberately hides *os.File from os/exec. This gives the
// starter its own output pipes instead of inheriting the caller's handles.
type startupOutput struct{ io.Writer }

// RunPersistent runs a non-interactive daemon starter such as pg_ctl. The
// daemon has its own log and may outlive both the starter and the caller.
// Preserve startup output, but detach stdin and bound output draining after
// the starter exits: on Windows, redirected grandchildren can still retain
// copies of the starter's original output handles.
func RunPersistent(command *exec.Cmd) error {
	if err := ConfigurePersistent(command); err != nil {
		return err
	}
	command.Stdin = nil
	if command.Stdout != nil {
		command.Stdout = startupOutput{command.Stdout}
	}
	if command.Stderr != nil {
		command.Stderr = startupOutput{command.Stderr}
	}
	command.WaitDelay = time.Second
	err := command.Run()
	if err == exec.ErrWaitDelay {
		// os/exec returns this only after a successful starter exit. The
		// surviving daemon's copies must not keep this invocation open.
		return nil
	}
	return err
}
