package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"tesl.dev/runtime/go/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err := cli.New().Run(ctx, os.Args[1:])
	// Child diagnostics have already been streamed. Preserve their status without
	// adding a second synthetic diagnostic to the compiler's stderr contract.
	var childExit *exec.ExitError
	if err != nil && !errors.As(err, &childExit) {
		fmt.Fprintln(os.Stderr, "tesl:", err)
	}
	os.Exit(cli.ExitCode(err))
}
