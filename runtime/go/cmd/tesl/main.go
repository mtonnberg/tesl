package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"tesl.dev/runtime/go/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err := cli.New().Run(ctx, os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "tesl:", err)
	}
	os.Exit(cli.ExitCode(err))
}
