//go:build windows

package install

import (
	"context"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"tesl.dev/runtime/go/internal/childprocess"
)

func Launch(executable, frontend string, arguments []string) error {
	selected, lease, err := selectedFrontend(executable, frontend)
	if err != nil {
		return err
	}
	defer func() { _ = lease.Close() }()
	command := exec.Command(selected, arguments...)
	command.Env = launcherEnvironment(selected)
	command.Stdin, command.Stdout, command.Stderr = os.Stdin, os.Stdout, os.Stderr
	child, err := childprocess.StartLauncher(command)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 1)
	go func() { done <- child.Wait() }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		child.Kill()
		<-done
		return ctx.Err()
	}
}
