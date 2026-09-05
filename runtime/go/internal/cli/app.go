// Package cli implements portable Tesl command orchestration.
package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"tesl.dev/runtime/go/internal/childprocess"
	"tesl.dev/runtime/go/internal/install"
	"tesl.dev/runtime/go/internal/toolchain"
)

type Invocation struct {
	Persistent     bool
	ToolchainRoot  string
	Executable     string
	Args           []string
	Directory      string
	Environment    []string
	Stdin          io.Reader
	Stdout, Stderr io.Writer
}

type App struct {
	Resolver       toolchain.Resolver
	Directory      string
	Environment    []string
	Stdin          io.Reader
	Stdout, Stderr io.Writer
	Execute        func(context.Context, Invocation) error
}

func New() *App {
	directory, _ := os.Getwd()
	return &App{Resolver: toolchain.Default(), Directory: directory, Environment: os.Environ(), Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr, Execute: execute}
}

func execute(ctx context.Context, invocation Invocation) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	command := exec.CommandContext(ctx, invocation.Executable, invocation.Args...) // #nosec G204 -- selected local tool, with literal argv; no shell interpretation.
	command.Dir, command.Env = invocation.Directory, invocation.Environment
	command.Stdin, command.Stdout, command.Stderr = invocation.Stdin, invocation.Stdout, invocation.Stderr
	// Managed PostgreSQL has an explicit start/stop lifecycle independent of this
	// invocation. Its daemon must survive pg_ctl and the CLI exiting.
	if invocation.Persistent {
		release, err := install.ConfigurePostgresLease(command, invocation.ToolchainRoot)
		if err != nil {
			return err
		}
		defer release()
		err = childprocess.RunPersistent(command)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	}
	// Child owns group/job cancellation; CommandContext must not race it by
	// terminating only the parent before the descendants have been contained.
	command.Cancel = nil
	child, err := childprocess.Start(command)
	if err != nil {
		return err
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			child.Kill()
		case <-done:
		}
	}()
	err = child.Wait()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

type usageError struct{ error }

func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	var usage *usageError
	if errors.As(err, &usage) {
		return 2
	}
	var status *processStatus
	if errors.As(err, &status) {
		return status.code
	}
	if errors.Is(err, context.Canceled) {
		return 130
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if code := exit.ExitCode(); code > 0 {
			return code
		}
		if exit.ProcessState != nil {
			if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
				return 128 + int(status.Signal())
			}
		}
	}
	return 1
}

func (app *App) invoke(ctx context.Context, tool, directory string, environment []string, args ...string) error {
	if tool == "go" && len(args) > 0 && (args[0] == "build" || args[0] == "test") {
		args = append([]string{args[0], "-buildvcs=false"}, args[1:]...)
	}
	path, err := app.Resolver.Resolve(tool)
	if err != nil {
		return err
	}
	persistent := tool == "pg_ctl" && len(args) > 0 && args[len(args)-1] == "start"
	toolchainRoot := ""
	if persistent {
		_, root, err := app.Resolver.Load()
		if err == nil {
			toolchainRoot = root
		} else if !os.IsNotExist(err) {
			return err
		}
	}
	return app.Execute(ctx, Invocation{Persistent: persistent, ToolchainRoot: toolchainRoot, Executable: path, Args: args, Directory: directory, Environment: environment, Stdin: app.Stdin, Stdout: app.Stdout, Stderr: app.Stderr})
}

func (app *App) compiler(ctx context.Context, args ...string) error {
	environment, err := app.Resolver.CompilerEnvironment(app.Environment)
	if err != nil {
		return err
	}
	// Only subprocess-producing compiler commands need the native process owner
	// and the selected offline Go environment. Ordinary queries remain independent
	// of whether Go is installed.
	if len(args) > 0 && (args[0] == "--mutate" || args[0] == "--exe") {
		var err error
		environment, err = app.Resolver.GoEnvironment(environment)
		if err != nil {
			return err
		}
		goTool, err := app.Resolver.Resolve("go")
		if err != nil {
			return err
		}
		environment = toolchain.Setenv(environment, "TESL_GO", goTool)
		self, err := os.Executable()
		if err != nil {
			return err
		}
		environment = toolchain.Setenv(environment, "TESL_PROCESS_RUNNER", self)
	}
	return app.invoke(ctx, "compiler", app.Directory, environment, args...)
}

func (app *App) Run(ctx context.Context, args []string) error {
	if len(args) > 0 && args[0] == "-C" {
		if len(args) < 2 {
			return fmt.Errorf("-C requires a working directory")
		}
		selected := *app
		selected.Directory = args[1]
		if !filepath.IsAbs(selected.Directory) {
			selected.Directory = filepath.Join(app.Directory, selected.Directory)
		}
		if info, err := os.Stat(selected.Directory); err != nil {
			return err
		} else if !info.IsDir() {
			return fmt.Errorf("-C requires a directory")
		}
		return selected.Run(ctx, args[2:])
	}
	if len(args) == 0 {
		args = []string{"help"}
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "--internal-run-process":
		return app.runProcess(ctx, rest)
	case "init":
		return app.init(ctx, rest)
	case "build":
		return app.build(ctx, rest)
	case "watch":
		return app.watch(ctx, rest)
	case "dast":
		return app.dast(ctx, rest)
	case "db":
		if len(rest) > 1 {
			return fmt.Errorf("usage: tesl db start|stop|status")
		}
		action := "status"
		if len(rest) == 1 {
			action = rest[0]
		}
		_, err := app.database(ctx, projectRoot(app.Directory), action)
		return err
	case "doctor":
		if len(rest) > 1 || (len(rest) == 1 && rest[0] != "--json") {
			return fmt.Errorf("usage: tesl doctor [--json]")
		}
		report := app.Resolver.Doctor()
		if len(rest) > 0 {
			if err := json.NewEncoder(app.Stdout).Encode(report); err != nil {
				return err
			}
		} else {
			for _, component := range report.Components {
				value := component.Path
				if component.Error != "" {
					value = component.Error
				}
				if _, err := fmt.Fprintf(app.Stdout, "%s: %s\n", component.Name, value); err != nil {
					return err
				}
			}
		}
		if !report.OK {
			return fmt.Errorf("toolchain is incomplete")
		}
		return nil
	case "version", "--version", "-v":
		version, err := app.Resolver.Version()
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintln(app.Stdout, "tesl", version); err != nil {
			return err
		}
		if compiler, err := app.Resolver.Resolve("compiler"); err == nil {
			_, err = fmt.Fprintln(app.Stdout, "compiler:", compiler)
			return err
		}
		return nil
	case "help", "--help", "-h":
		if len(rest) > 0 {
			return app.compiler(ctx, append([]string{"--help"}, rest...)...)
		}
		_, err := fmt.Fprintln(app.Stdout, "Tesl\n\n  init, check, compile, emit go, run, watch, test, mutate, build\n  db start|stop|status, clean, lint, fmt, fmt-check, validate\n  doc, explain, generate, agent-context, debug-inspect, debug-attach\n  search [--json] QUERY, --catalog-json\n  doctor [--json], version\n\nUse tesl help <topic> for compiler and language documentation.")
		return err
	case "check", "lint", "fmt", "format", "fmt-check", "validate":
		files, err := app.files(rest)
		if err != nil {
			return err
		}
		if verb == "format" {
			verb = "fmt"
		}
		flags := []string{"--" + verb}
		if verb == "validate" {
			flags = []string{"--check", "--lint", "--fmt-check"}
		}
		for _, flag := range flags {
			if err := app.compiler(ctx, append([]string{flag}, files...)...); err != nil {
				return err
			}
		}
		return nil
	case "compile", "emit":
		if verb == "emit" {
			if len(rest) == 0 || rest[0] != "go" {
				return fmt.Errorf("usage: tesl emit go [file.tesl] [--out directory]")
			}
			rest = rest[1:]
		}
		if len(rest) >= 2 && rest[0] == "--backend" {
			if rest[1] != "go" {
				return fmt.Errorf("only the Go backend is supported")
			}
			rest = rest[2:]
		}
		files, err := app.files(rest)
		if err != nil {
			return err
		}
		return app.compileSource(ctx, files)
	case "run", "test":
		return app.runOrTest(ctx, verb, rest)
	case "--test-name":
		return app.runOrTest(ctx, "test", args)
	case "generate":
		if len(rest) < 2 {
			return fmt.Errorf("usage: tesl generate ir|ts|elm <file> [--out file]")
		}
		flag := map[string]string{"ir": "--ir", "ts": "--generate-ts", "elm": "--generate-elm"}[rest[0]]
		if flag == "" {
			return fmt.Errorf("unknown generator: %s", rest[0])
		}
		return app.compiler(ctx, append([]string{flag}, rest[1:]...)...)
	case "mutate":
		return app.compiler(ctx, append([]string{"--mutate"}, rest...)...)
	case "debug-inspect":
		if len(rest) == 0 {
			return fmt.Errorf("usage: tesl debug-inspect <file> [options]")
		}
		compiler, err := app.Resolver.Resolve("compiler")
		if err != nil {
			return err
		}
		env := toolchain.Setenv(app.Environment, "TESL_COMPILER", compiler)
		return app.invoke(ctx, "tesl-debug-inspect", app.Directory, env, append([]string{"--file", rest[0]}, rest[1:]...)...)
	case "debug-attach":
		return app.invoke(ctx, "tesl-debug-attach", app.Directory, app.Environment, rest...)
	case "doc", "explain", "search", "agent-context":
		return app.compiler(ctx, args...)
	case "check-json", "definition-json", "occurrences-json", "type-at-json", "field-at-json", "completions-json", "local-bindings-json", "semantic-json":
		return app.compiler(ctx, append([]string{"--" + verb}, rest...)...)
	case "clean":
		if len(rest) == 1 && (rest[0] == "--help" || rest[0] == "-h") {
			_, _ = fmt.Fprintln(app.Stdout, "Usage: tesl clean (remove generated build output; preserve database and project data)")
			return nil
		}
		if len(rest) != 0 {
			return fmt.Errorf("usage: tesl clean")
		}
		return app.clean()
	}
	if strings.HasPrefix(verb, "--") {
		return app.compiler(ctx, args...)
	}
	return fmt.Errorf("unknown command: %s (try tesl help)", verb)
}

func (app *App) runOrTest(ctx context.Context, verb string, args []string) error {
	debug, name, kind := false, "", ""
	withDAST := false
	dastArgs := []string{}
	for len(args) > 0 && strings.HasPrefix(args[0], "--") {
		flag := args[0]
		args = args[1:]
		if verb == "test" {
			switch flag {
			case "--with-dast", "--also-run-dast":
				withDAST = true
				continue
			case "--dast-active":
				dastArgs = append(dastArgs, "--active")
				continue
			case "--dast-allow-remote":
				dastArgs = append(dastArgs, "--allow-remote")
				continue
			case "--dast-target", "--dast-server":
				if len(args) == 0 {
					return fmt.Errorf("%s requires a value", flag)
				}
				dastArgs = append(dastArgs, strings.Replace(flag, "--dast-", "--", 1), args[0])
				args = args[1:]
				continue
			}
		}
		if flag == "--debug" && verb == "run" {
			debug = true
			continue
		}
		if flag != "--backend" && flag != "--test-name" && flag != "--test-kind" {
			return fmt.Errorf("unknown %s flag: %s", verb, flag)
		}
		if len(args) == 0 {
			return fmt.Errorf("%s requires a value", flag)
		}
		value := args[0]
		args = args[1:]
		switch flag {
		case "--backend":
			if value != "go" {
				return fmt.Errorf("only the Go backend is supported")
			}
		case "--test-name":
			name = value
		case "--test-kind":
			kind = value
		}
	}
	files, err := app.files(args)
	if err != nil {
		return err
	}
	if verb == "run" {
		return app.executeSource(ctx, files[0], files[1:], debug, false, "", "")
	}
	if withDAST && len(files) != 1 {
		return fmt.Errorf("--with-dast requires exactly one source file")
	}
	if withDAST {
		if _, err := parseDAST(append(append([]string{}, dastArgs...), files[0])); err != nil {
			return err
		}
	}
	var failed error
	for _, file := range files {
		if err := app.executeSource(ctx, file, nil, false, true, name, kind); err != nil {
			failed = err
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	if failed == nil && withDAST {
		return app.dast(ctx, append(dastArgs, files[0]))
	}
	return failed
}

func (app *App) executeSource(ctx context.Context, file string, args []string, debug, tests bool, name, kind string) error {
	file, project, err := app.sourceFile(file)
	if err != nil {
		return err
	}
	stuff := filepath.Join(project, ".tesl-stuff")
	if err := os.MkdirAll(stuff, 0700); err != nil {
		return err
	}
	temp, err := os.MkdirTemp(stuff, "tesl.")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(temp) }()
	out := filepath.Join(temp, "go")
	emitArgs := []string{file, "--out", out}
	if debug {
		emitArgs = append(emitArgs, "--debug")
	}
	if err := app.compiler(ctx, emitArgs...); err != nil {
		return err
	}
	projectEnv, err := app.projectEnvironment(ctx, project, true)
	if err != nil {
		return err
	}
	env, err := app.Resolver.GoEnvironment(projectEnv)
	if err != nil {
		return err
	}
	if tests {
		env = toolchain.Setenv(toolchain.Setenv(env, "TESL_TEST_NAME", name), "TESL_TEST_KIND", kind)
		return app.invoke(ctx, "go", out, env, "test", "./...")
	}
	if _, err := os.Stat(filepath.Join(out, "cmd", "app")); err != nil {
		return fmt.Errorf("%s has no main/server entrypoint", file)
	}
	binary := filepath.Join(temp, "tesl-app")
	if runtime.GOOS == "windows" {
		binary += ".exe"
	}
	if err := app.invoke(ctx, "go", out, env, "build", "-o", binary, "./cmd/app"); err != nil {
		return err
	}
	env = projectEnv
	if debug {
		env = toolchain.Setenv(toolchain.Setenv(env, "TESL_DEBUG", "1"), "TESL_DEBUG_ROOT", project)
	}
	return app.Execute(ctx, Invocation{Executable: binary, Args: args, Directory: app.Directory, Environment: env, Stdin: app.Stdin, Stdout: app.Stdout, Stderr: app.Stderr})
}

func (app *App) clean() error {
	root := projectRoot(app.Directory)
	if custom, _ := environmentValue(app.Environment, "TESL_BUILD_DIR"); custom != "" {
		if !filepath.IsAbs(custom) {
			custom = filepath.Join(root, custom)
		}
		custom = filepath.Clean(custom)
		relative, err := filepath.Rel(custom, root)
		if err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return fmt.Errorf("refusing to clean TESL_BUILD_DIR containing the project: %s", custom)
		}
		if err := os.RemoveAll(custom); err != nil {
			return err
		}
	}
	stuff := filepath.Join(root, ".tesl-stuff")
	entries, err := os.ReadDir(stuff)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		if name == "build" || name == "go-build" || name == "debug.sock" || name == "debug.port" || name == "debug.token" || strings.HasPrefix(name, "tesl.") || strings.HasPrefix(name, "go-emit-") {
			if err := os.RemoveAll(filepath.Join(stuff, name)); err != nil {
				return err
			}
		}
	}
	return nil
}
