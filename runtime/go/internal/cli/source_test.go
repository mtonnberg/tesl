package cli

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func sourceSymlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		if runtime.GOOS == "windows" && os.IsPermission(err) {
			t.Skip("creating symlinks requires Windows Developer Mode or symlink privileges")
		}
		t.Fatal(err)
	}
}

func TestSourceCommandsRejectUnsafePathsBeforeStartingTools(t *testing.T) {
	commands := [][]string{
		{"compile", "app.tesl"},
		{"compile", "app.tesl", "--out", "generated"},
		{"emit", "go", "app.tesl", "--out", "generated"},
		{"run", "app.tesl"},
		{"run", "--debug", "app.tesl"},
		{"test", "app.tesl"},
		{"watch", "app.tesl"},
		{"compile"}, {"run"}, {"test"}, {"watch"},
		{"build", "--local"}, {"build", "--no-docker", "--out", "context"},
	}
	for _, pathKind := range []string{"absolute-escape", "relative-escape", "chain-escape", "directory-escape", "broken", "loop", "directory"} {
		for _, args := range commands {
			t.Run(pathKind+"/"+strings.Join(args, " "), func(t *testing.T) {
				app, calls := fakeApp(t)
				// A sibling sharing the project prefix catches string-prefix checks.
				outside := app.Directory + "-outside"
				t.Cleanup(func() { _ = os.RemoveAll(outside) })
				writeProjectFile(t, outside, "app.tesl", "module App exposing []\n")
				writeProjectFile(t, app.Directory, "tesl.toml", "[project]\nentrypoint = app.tesl\n")
				entry := filepath.Join(app.Directory, "app.tesl")
				switch pathKind {
				case "absolute-escape":
					sourceSymlink(t, filepath.Join(outside, "app.tesl"), entry)
				case "relative-escape":
					sourceSymlink(t, filepath.Join("..", filepath.Base(outside), "app.tesl"), entry)
				case "chain-escape":
					sourceSymlink(t, filepath.Join(outside, "app.tesl"), filepath.Join(app.Directory, "middle.tesl"))
					sourceSymlink(t, "middle.tesl", entry)
				case "directory-escape":
					sourceSymlink(t, outside, filepath.Join(app.Directory, "linked"))
					sourceSymlink(t, filepath.Join("linked", "app.tesl"), entry)
				case "broken":
					sourceSymlink(t, "missing.tesl", entry)
				case "loop":
					sourceSymlink(t, "middle.tesl", entry)
					sourceSymlink(t, "app.tesl", filepath.Join(app.Directory, "middle.tesl"))
				case "directory":
					if err := os.Mkdir(entry, 0700); err != nil {
						t.Fatal(err)
					}
				}
				err := app.Run(context.Background(), args)
				if err == nil || !strings.Contains(err.Error(), "source") {
					t.Fatalf("expected source-path rejection, got %v", err)
				}
				if len(*calls) != 0 {
					t.Fatalf("unsafe source reached a tool: %+v", *calls)
				}
				for _, name := range []string{".tesl-stuff", "generated", "context"} {
					if _, err := os.Lstat(filepath.Join(app.Directory, name)); !os.IsNotExist(err) {
						t.Fatalf("rejected source left %s: %v", name, err)
					}
				}
			})
		}
	}
}

func TestSourceCommandsPassCanonicalInProjectPaths(t *testing.T) {
	for _, args := range [][]string{{"compile", "app.tesl"}, {"emit", "go", "app.tesl", "--out", "generated"}, {"run", "app.tesl"}, {"test", "app.tesl"}, {"build", "--local"}} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			app, calls := fakeApp(t)
			writeProjectFile(t, app.Directory, "tesl.toml", "[project]\nentrypoint = app.tesl\n")
			writeProjectFile(t, app.Directory, "src å with spaces/app.tesl", "module App exposing []\n")
			sourceSymlink(t, filepath.Join("src å with spaces", "app.tesl"), filepath.Join(app.Directory, "middle.tesl"))
			sourceSymlink(t, "middle.tesl", filepath.Join(app.Directory, "app.tesl"))
			want, err := filepath.EvalSymlinks(filepath.Join(app.Directory, "src å with spaces/app.tesl"))
			if err != nil {
				t.Fatal(err)
			}
			stop := errors.New("compiler reached")
			execute := app.Execute
			app.Execute = func(ctx context.Context, inv Invocation) error {
				_ = execute(ctx, inv)
				return stop
			}
			if err := app.Run(context.Background(), args); !errors.Is(err, stop) {
				t.Fatalf("valid source rejected: %v", err)
			}
			if len(*calls) != 1 || len((*calls)[0].Args) == 0 || (*calls)[0].Args[0] != want {
				t.Fatalf("compiler must receive canonical source %q: %+v", want, *calls)
			}
		})
	}
}

func TestBuildRejectsManifestEntrypointOutsideSelectedProject(t *testing.T) {
	for _, absolute := range []bool{false, true} {
		app, calls := fakeApp(t)
		outside := t.TempDir()
		writeProjectFile(t, outside, "app.tesl", "module App exposing []\n")
		entry := filepath.Join(outside, "app.tesl")
		if !absolute {
			var err error
			entry, err = filepath.Rel(app.Directory, entry)
			if err != nil {
				t.Fatal(err)
			}
		}
		writeProjectFile(t, app.Directory, "tesl.toml", "[project]\nentrypoint = "+filepath.ToSlash(entry)+"\n")
		if err := app.Run(context.Background(), []string{"build", "--local"}); err == nil || !strings.Contains(err.Error(), "outside the project root") {
			t.Fatalf("accepted escaping manifest entrypoint: %v", err)
		}
		if len(*calls) != 0 {
			t.Fatal("escaping entrypoint reached a tool")
		}
	}
}

func TestSourceFileSupportsProjectAliasesAndStandaloneFiles(t *testing.T) {
	for _, layout := range []string{"plain", "project-alias", "internal-directory-link", "standalone"} {
		t.Run(layout, func(t *testing.T) {
			app, _ := fakeApp(t)
			root := app.Directory
			writeProjectFile(t, root, "project å/src/app.tesl", "module App exposing []\n")
			app.Directory = filepath.Join(root, "project å")
			if layout != "standalone" {
				writeProjectFile(t, app.Directory, "tesl.toml", "[project]\nentrypoint = src/app.tesl\n")
			}
			entry := filepath.Join("src", "app.tesl")
			switch layout {
			case "project-alias":
				sourceSymlink(t, app.Directory, filepath.Join(root, "alias"))
				app.Directory = filepath.Join(root, "alias")
			case "internal-directory-link":
				sourceSymlink(t, "src", filepath.Join(app.Directory, "alias"))
				entry = filepath.Join("alias", "app.tesl")
			}
			want, err := filepath.EvalSymlinks(filepath.Join(root, "project å/src/app.tesl"))
			if err != nil {
				t.Fatal(err)
			}
			got, _, err := app.sourceFile(entry)
			if err != nil || got != want {
				t.Fatalf("source %q, want %q: %v", got, want, err)
			}
		})
	}
}

func TestBuiltCompilerNativeCLISourceLinks(t *testing.T) {
	_, filename, _, _ := runtime.Caller(0)
	repo := filepath.Clean(filepath.Join(filepath.Dir(filename), "../../../.."))
	compiler := filepath.Join(repo, "compiler/_build/default/bin/main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("built compiler unavailable")
	}
	app := New()
	app.Directory = t.TempDir()
	getenv := app.Resolver.Getenv
	app.Resolver.Getenv = func(key string) string {
		if key == "TESL_COMPILER" {
			return compiler
		}
		return getenv(key)
	}
	writeProjectFile(t, app.Directory, "tesl.toml", "[project]\nentrypoint = app.tesl\n")
	writeProjectFile(t, app.Directory, "src/app.tesl", "module App exposing [value]\nimport Tesl.Prelude exposing [Int]\nfn value() -> Int = 7\n")
	entry := filepath.Join(app.Directory, "app.tesl")
	sourceSymlink(t, filepath.Join("src", "app.tesl"), entry)
	if err := app.Run(context.Background(), []string{"emit", "go", "app.tesl", "--out", "generated"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(app.Directory, "generated/go.mod")); err != nil {
		t.Fatalf("valid linked source did not compile: %v", err)
	}
	if err := os.Remove(entry); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	writeProjectFile(t, outside, "app.tesl", "module App exposing []\n")
	sourceSymlink(t, filepath.Join(outside, "app.tesl"), entry)
	if err := app.Run(context.Background(), []string{"emit", "go", "app.tesl", "--out", "rejected"}); err == nil || !strings.Contains(err.Error(), "outside the project root") {
		t.Fatalf("retargeted source was accepted: %v", err)
	}
	if _, err := os.Stat(filepath.Join(app.Directory, "rejected")); !os.IsNotExist(err) {
		t.Fatal("retargeted source produced output")
	}
}
