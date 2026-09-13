//go:build linux

package cli

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"

	"golang.org/x/sys/unix"
)

func migrationTerminal(file *os.File) bool {
	fd := file.Fd()
	if fd > math.MaxInt32 {
		return false
	}
	_, err := unix.IoctlGetTermios(int(fd), unix.TCGETS)
	return err == nil
}

func migrationWaitInput(ctx context.Context, file *os.File) error {
	fd := file.Fd()
	if fd > math.MaxInt32 {
		return fmt.Errorf("invalid terminal descriptor")
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
		n, err := unix.Poll(fds, 100)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return err
		}
		if n != 0 {
			return nil
		}
	}
}
