package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"tesl.dev/runtime/go/internal/cli"
	"tesl.dev/runtime/go/internal/install"
)

func run(ctx context.Context, executable string, arguments []string, output, diagnostics io.Writer) error {
	if len(arguments) == 0 {
		embedded, err := install.FindEmbedded(executable)
		if err != nil {
			return err
		}
		if embedded != nil {
			arguments = []string{"install"}
		}
	}
	if len(arguments) == 0 || arguments[0] == "help" || arguments[0] == "--help" {
		_, err := fmt.Fprintln(output, "Usage: tesl-install install --archive FILE --sha256 HEX [--root DIR] [--json]\n       tesl-install list|state|rollback [--root DIR] [--json]\n       tesl-install select|uninstall VERSION [--root DIR] [--json]\n\nInstalls/selects verified local archives for the current user.\nNo shell profiles, registry settings, projects or databases are changed.\nAdd the reported path_directory to PATH and restart your editor.")
		return err
	}
	root, err := install.RootForExecutable(executable)
	if err != nil {
		return err
	}
	action, arguments := arguments[0], arguments[1:]
	version := ""
	if action == "select" || action == "uninstall" {
		if len(arguments) == 0 {
			return errors.New("a version is required")
		}
		version, arguments = arguments[0], arguments[1:]
	}
	flags := flag.NewFlagSet("tesl-install "+action, flag.ContinueOnError)
	flags.SetOutput(diagnostics)
	flags.StringVar(&root, "root", root, "per-user installation root")
	archive := flags.String("archive", "", "local .tar.gz or .zip")
	checksum := flags.String("sha256", "", "expected archive SHA-256")
	asJSON := flags.Bool("json", false, "machine-readable result")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if action != "install" && (*archive != "" || *checksum != "") {
		return errors.New("--archive and --sha256 apply only to install")
	}
	manager := install.Manager{Root: root, Executable: executable}
	var result install.Result
	switch action {
	case "install":
		if *archive == "" && *checksum == "" {
			var cleanup func()
			*archive, *checksum, cleanup, err = install.ExtractEmbedded(ctx, executable)
			if err != nil {
				return err
			}
			defer cleanup()
		}
		if *archive == "" || *checksum == "" {
			return errors.New("install requires --archive and --sha256")
		}
		result, err = manager.Install(ctx, *archive, *checksum)
	case "list", "state":
		result, err = manager.List()
		result.Action = action
	case "select":
		result, err = manager.Select(version)
	case "rollback":
		result, err = manager.Rollback()
	case "uninstall":
		result, err = manager.Uninstall(ctx, version)
	default:
		return fmt.Errorf("unknown installer command %q", action)
	}
	if err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(output).Encode(result)
	}
	_, err = fmt.Fprintf(output, "%s: selected %s\nPATH directory: %s\n", result.Action, result.State.Active, result.Bin)
	for _, version := range result.Installed {
		if _, writeErr := fmt.Fprintf(output, "  %s (%s)\n", version.Version, version.Target); writeErr != nil {
			return writeErr
		}
	}
	return err
}

func main() {
	executable, err := os.Executable()
	if err == nil && install.IsFrontend(os.Args[0]) {
		err = install.Launch(executable, os.Args[0], os.Args[1:])
	} else if err == nil {
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		err = run(ctx, executable, os.Args[1:], os.Stdout, os.Stderr)
		cancel()
	}
	var childExit *exec.ExitError
	if err != nil && !errors.As(err, &childExit) {
		_, _ = fmt.Fprintln(os.Stderr, "tesl-install:", err)
	}
	os.Exit(cli.ExitCode(err))
}
