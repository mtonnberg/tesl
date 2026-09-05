package cli

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"tesl.dev/runtime/go/internal/toolchain"
)

func (app *App) compileSource(ctx context.Context, args []string) error {
	if len(args) != 1 && (len(args) != 3 || args[1] != "--out" || args[2] == "") {
		return fmt.Errorf("usage: tesl compile [file.tesl] [--out directory]")
	}
	if len(args) == 3 {
		out := args[2]
		if !filepath.IsAbs(out) {
			out = filepath.Join(app.Directory, out)
		}
		if _, err := os.Lstat(out); err == nil {
			return fmt.Errorf("compile output already exists: %s", out)
		} else if !os.IsNotExist(err) {
			return err
		}
		return app.compiler(ctx, args...)
	}
	file := args[0]
	if !filepath.IsAbs(file) {
		file = filepath.Join(app.Directory, file)
	}
	stuff := filepath.Join(projectRoot(filepath.Dir(file)), ".tesl-stuff")
	if err := os.MkdirAll(stuff, 0700); err != nil {
		return err
	}
	temp, err := os.MkdirTemp(stuff, "tesl.compile-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(temp) }()
	out := filepath.Join(temp, "generated")
	if err := app.compiler(ctx, file, "--out", out); err != nil {
		return err
	}
	destination := filepath.Join(stuff, "go-build")
	if err := replaceBuildDirectory(out, destination); err != nil {
		return err
	}
	_, _ = fmt.Fprintln(app.Stdout, "compiled Go module:", file, "→", destination)
	return nil
}

func (app *App) build(ctx context.Context, args []string) error {
	mode, variant, tag, requestedOut := "", "app-only", "", ""
	noDocker := false
	for len(args) > 0 {
		arg := args[0]
		args = args[1:]
		switch arg {
		case "--local":
			mode = "local"
		case "--container":
			mode = "container"
		case "--app-only":
			mode = "container"
			variant = "app-only"
		case "--with-postgres":
			mode = "container"
			variant = "all-in-one"
		case "--no-docker":
			mode = "container"
			noDocker = true
		case "--tag", "--out", "--backend":
			if len(args) == 0 {
				return fmt.Errorf("%s requires a value", arg)
			}
			value := args[0]
			args = args[1:]
			if arg == "--backend" {
				if value != "go" {
					return fmt.Errorf("only the Go backend is supported")
				}
			} else {
				mode = "container"
				if arg == "--tag" {
					tag = value
				} else {
					requestedOut = value
				}
			}
		case "--help", "-h":
			_, _ = fmt.Fprintln(app.Stdout, "Usage: tesl build [--local|--container] [--app-only|--with-postgres] [--tag NAME] [--out DIR] [--no-docker]")
			return nil
		default:
			return fmt.Errorf("unexpected build argument: %s", arg)
		}
	}
	root := projectRoot(app.Directory)
	manifest, err := readManifest(root)
	if err != nil {
		return err
	}
	if mode == "" {
		mode = manifest.value("deploy", "target", "container")
	}
	if mode != "local" && mode != "container" {
		return fmt.Errorf("unknown [deploy].target %q; use local or container", mode)
	}
	entry := manifest.value("project", "entrypoint", "app.tesl")
	if !filepath.IsAbs(entry) {
		entry = filepath.Join(root, entry)
	}
	name := manifest.value("project", "name", "app")
	port := manifest.value("env", "PORT", "8086")
	if !validPort(port) {
		return fmt.Errorf("invalid application port: %q", port)
	}
	stuff := filepath.Join(root, ".tesl-stuff")
	if err := os.MkdirAll(stuff, 0700); err != nil {
		return err
	}
	temp, err := os.MkdirTemp(stuff, "tesl.build-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(temp) }()
	generated := filepath.Join(temp, "generated")
	if err := app.compiler(ctx, entry, "--out", generated); err != nil {
		return err
	}
	env, err := app.Resolver.GoEnvironment(app.Environment)
	if err != nil {
		return err
	}
	_, mainErr := os.Stat(filepath.Join(generated, "cmd", "app"))
	if mode == "local" {
		arguments := []string{"build", "./..."}
		if mainErr == nil {
			binary := filepath.Join(generated, "tesl-app")
			if runtime.GOOS == "windows" {
				binary += ".exe"
			}
			arguments = []string{"build", "-trimpath", "-o", binary, "./cmd/app"}
		}
		if err := app.invoke(ctx, "go", generated, env, arguments...); err != nil {
			return err
		}
		out := filepath.Join(stuff, "go-build")
		if err := replaceBuildDirectory(generated, out); err != nil {
			return err
		}
		_, _ = fmt.Fprintln(app.Stdout, "tesl build:", name, "built at", out)
		return nil
	}
	if mainErr != nil {
		return fmt.Errorf("%s has no main/server entrypoint", entry)
	}
	contextDir := filepath.Join(temp, "context")
	if err := os.Mkdir(contextDir, 0755); err != nil { // #nosec G301 -- public build context, inside a private temporary parent.
		return err
	}
	env = toolchain.Setenv(toolchain.Setenv(env, "GOOS", "linux"), "CGO_ENABLED", "0")
	if err := app.invoke(ctx, "go", generated, env, "build", "-trimpath", "-o", filepath.Join(contextDir, "tesl-app"), "./cmd/app"); err != nil {
		return err
	}
	templates, err := app.Resolver.Resolve("templates")
	if err != nil {
		return err
	}
	dockerfile, err := os.ReadFile(filepath.Join(templates, "docker", "Dockerfile."+variant+".tmpl")) // #nosec G304 -- installation template; variant is restricted to app-only or with-postgres above.
	if err != nil {
		return err
	}
	revision := "unknown"
	if output, err := app.capture(ctx, "git", root, "rev-parse", "HEAD"); err == nil {
		revision = strings.TrimSpace(output)
	}
	created := time.Now().UTC()
	if epoch, found := environmentValue(app.Environment, "SOURCE_DATE_EPOCH"); found {
		seconds, err := strconv.ParseInt(epoch, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid SOURCE_DATE_EPOCH: %w", err)
		}
		created = time.Unix(seconds, 0).UTC()
	}
	quoteLabel := func(value string) string { quoted := strconv.Quote(value); return quoted[1 : len(quoted)-1] }
	replacer := strings.NewReplacer("__APP_NAME__", quoteLabel(name), "__PORT__", port, "__REVISION__", quoteLabel(revision), "__CREATED__", created.Format(time.RFC3339), "__SOURCE__", "https://github.com/mtonnberg/tesl")
	if err := os.WriteFile(filepath.Join(contextDir, "Dockerfile"), []byte(replacer.Replace(string(dockerfile))), 0644); err != nil { // #nosec G703 G306 -- fixed filename under the private staging directory; generated public build instructions, no secrets.
		return err
	}
	if err := os.WriteFile(filepath.Join(contextDir, ".dockerignore"), []byte("*\n!tesl-app\n!Dockerfile\n!.dockerignore\n"), 0644); err != nil { // #nosec G306 -- public build instructions, no secrets.
		return err
	}
	out := requestedOut
	if out == "" {
		out, err = os.MkdirTemp(stuff, "tesl.container-")
		if err != nil {
			return err
		}
		if err := os.Remove(out); err != nil {
			return err
		}
	}
	if !filepath.IsAbs(out) {
		out = filepath.Join(app.Directory, out)
	}
	if _, err := os.Lstat(out); err == nil {
		return fmt.Errorf("build output already exists: %s", out)
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(out), 0755); err != nil { // #nosec G301 -- user-selected public build output, with private staging below.
		return err
	}
	// Stage beside the destination so the final rename also works when --out
	// selects a different volume (a common Windows workspace arrangement).
	staged, err := os.MkdirTemp(filepath.Dir(out), ".tesl-container-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(staged) }()
	if err := os.CopyFS(staged, os.DirFS(contextDir)); err != nil {
		return err
	}
	if err := os.Rename(staged, out); err != nil {
		return err
	}
	_, _ = fmt.Fprintln(app.Stdout, "tesl build: staged Docker context at", out)
	if noDocker {
		return nil
	}
	if tag == "" {
		tag = name + ":latest"
	}
	return app.invoke(ctx, "docker", root, app.Environment, "build", "-t", tag, out)
}

// Retain the last successful local build until its replacement is ready. A
// failed switch rolls back, including on Windows where nonempty dirs cannot be
// renamed over one another.
func replaceBuildDirectory(staged, destination string) error {
	backup := destination + ".previous"
	if _, err := os.Lstat(backup); err == nil {
		return fmt.Errorf("previous interrupted build at %s must be recovered first", backup)
	} else if !os.IsNotExist(err) {
		return err
	}
	hadOld := false
	if _, err := os.Lstat(destination); err == nil {
		if err := os.Rename(destination, backup); err != nil {
			return err
		}
		hadOld = true
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.Rename(staged, destination); err != nil {
		if hadOld {
			if restoreErr := os.Rename(backup, destination); restoreErr != nil {
				return fmt.Errorf("build switch failed (%v); prior build preserved at %s: %w", err, backup, restoreErr)
			}
		}
		return err
	}
	if hadOld {
		return os.RemoveAll(backup)
	}
	return nil
}
