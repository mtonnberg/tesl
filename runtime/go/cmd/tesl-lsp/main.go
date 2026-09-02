package main

import (
	"context"
	"os"

	"tesl.dev/runtime/go/internal/lsp"
)

func main() {
	status := lsp.NewServer(lsp.CompilerFromEnvironment()).Run(context.Background(), os.Stdin, os.Stdout)
	os.Exit(status)
}
