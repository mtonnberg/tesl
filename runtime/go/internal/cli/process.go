package cli

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"tesl.dev/runtime/go/internal/tooling"
)

type processStatus struct{ code int }

func (status *processStatus) Error() string {
	return fmt.Sprintf("process exited with status %d", status.code)
}

// runProcess is the compiler's private argv-based build/mutation transport. The
// native CLI owns deadlines, bounded capture and Windows Job Object cleanup.
// This avoids a second Windows command implementation in PowerShell or cmd.exe.
func (app *App) runProcess(ctx context.Context, args []string) error {
	if len(args) < 3 {
		return errors.New("internal process runner requires timeout, directory and executable")
	}
	seconds, err := strconv.Atoi(args[0])
	if err != nil || seconds < 1 || seconds > 86400 {
		return errors.New("invalid internal process timeout")
	}
	client := tooling.Client{Executable: args[2], Directory: args[1], Environment: app.Environment, Timeout: time.Duration(seconds) * time.Second}
	result, err := client.Run(ctx, args[3:]...)
	if len(result.Stdout)+len(result.Stderr) > tooling.DefaultCompilerOutput {
		return &processStatus{125}
	}
	if _, writeErr := app.Stdout.Write(result.Stdout); writeErr != nil {
		return writeErr
	}
	if _, writeErr := app.Stderr.Write(result.Stderr); writeErr != nil {
		return writeErr
	}
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) {
		return err
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return &processStatus{124}
	}
	if result.ExitCode > 0 {
		return &processStatus{result.ExitCode}
	}
	return err
}
