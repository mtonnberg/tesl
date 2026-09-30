package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestBuildSwitchPreservesLastSuccess(t *testing.T) {
	for _, failure := range []string{"none", "missing-stage", "interrupted-build"} {
		t.Run(failure, func(t *testing.T) {
			root := t.TempDir()
			old, staged := filepath.Join(root, "go-build"), filepath.Join(root, "stage")
			writeProjectFile(t, old, "app", "last success")
			if failure != "missing-stage" {
				writeProjectFile(t, staged, "app", "new success")
			}
			if failure == "interrupted-build" {
				writeProjectFile(t, old+".previous", "app", "recover me")
			}
			err := replaceBuildDirectory(staged, old)
			if (err != nil) != (failure != "none") {
				t.Fatalf("switch: %v", err)
			}
			data, err := os.ReadFile(filepath.Join(old, "app"))
			want := "last success"
			if failure == "none" {
				want = "new success"
			}
			if err != nil || string(data) != want {
				t.Fatalf("lost build: %q, %v", data, err)
			}
			if failure == "interrupted-build" {
				data, err := os.ReadFile(filepath.Join(old+".previous", "app"))
				if err != nil || string(data) != "recover me" {
					t.Fatal("lost recovery copy")
				}
			}
		})
	}
}

func TestManagedDatabaseStateTransitions(t *testing.T) {
	for _, state := range []string{"new", "stopped", "running", "wrong-major", "occupied-port", "bad-port", "createdb-fallback", "unreachable"} {
		t.Run(state, func(t *testing.T) {
			app, calls := fakeApp(t)
			getenv := app.Resolver.Getenv
			app.Resolver.Getenv = func(key string) string {
				if key == "TESL_POSTGRES_BIN" {
					return app.Directory
				}
				return getenv(key)
			}
			for _, name := range []string{"pg_ctl", "initdb", "createdb", "psql"} {
				if app.Resolver.GOOS == "windows" {
					name += ".exe"
				}
				if err := os.WriteFile(filepath.Join(app.Directory, name), []byte("tool"), 0755); err != nil {
					t.Fatal(err)
				}
			}
			writeProjectFile(t, app.Directory, "tesl.toml", "[database]\nmode = managed\n[env]\nTESL_POSTGRES_PORT = 5432\n")
			dataDir := filepath.Join(app.Directory, ".tesl-postgres", "data")
			if state != "new" {
				writeProjectFile(t, dataDir, "PG_VERSION", "17\n")
			}
			if state == "running" {
				writeProjectFile(t, dataDir, "postmaster.pid", "123\ndata\ntime\n55444\n")
			}
			if state == "bad-port" {
				writeProjectFile(t, app.Directory, ".tesl-postgres/PORT", "5432 -c evil=1")
			}
			if state == "occupied-port" {
				listener, err := net.Listen("tcp4", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				defer func() { _ = listener.Close() }()
				writeProjectFile(t, app.Directory, ".tesl-postgres/PORT", fmt.Sprint(listener.Addr().(*net.TCPAddr).Port))
			}
			execute := app.Execute
			app.Execute = func(ctx context.Context, inv Invocation) error {
				_ = execute(ctx, inv)
				args := strings.Join(inv.Args, "|")
				if args == "--version" {
					major := "17.10"
					if state == "wrong-major" {
						major = "18.1"
					}
					_, _ = fmt.Fprintln(inv.Stdout, "pg_ctl (PostgreSQL)", major)
				}
				if strings.HasSuffix(args, "|status") && state != "running" {
					return fmt.Errorf("not running")
				}
				if strings.HasSuffix(args, "|app") && (state == "createdb-fallback" || state == "unreachable") {
					return fmt.Errorf("database exists")
				}
				if strings.HasSuffix(args, "|select 1") && state == "unreachable" {
					return fmt.Errorf("connection refused")
				}
				return nil
			}
			port, err := app.database(context.Background(), app.Directory, "start")
			bad := state == "wrong-major" || state == "bad-port" || state == "unreachable"
			if (err != nil) != bad {
				t.Fatalf("start: port %s, %v", port, err)
			}
			starts := 0
			for _, inv := range *calls {
				if inv.Args[len(inv.Args)-1] == "start" {
					starts++
					if !inv.Persistent {
						t.Fatal("daemon would die when CLI exits")
					}
					for i, arg := range inv.Args {
						if arg == "-o" {
							// cmd.exe does not strip POSIX single quotes. The
							// socket setting must reach PostgreSQL as an empty
							// value without depending on shell-specific quoting.
							options := strings.Fields(inv.Args[i+1])
							if len(options) != 7 || options[6] != "unix_socket_directories=" {
								t.Fatalf("socket option is not portable: %q", inv.Args[i+1])
							}
						}
					}
				} else if inv.Persistent {
					t.Fatal("short-lived command escaped cleanup")
				}
			}
			if state == "running" || state == "wrong-major" || state == "bad-port" {
				if starts != 0 {
					t.Fatal("started/restarted existing or incompatible cluster")
				}
			} else if starts != 1 {
				t.Fatalf("start count %d", starts)
			}
			if !bad {
				saved, err := os.ReadFile(filepath.Join(app.Directory, ".tesl-postgres", "PORT"))
				if err != nil || strings.TrimSpace(string(saved)) != port {
					t.Fatal("port not persisted")
				}
			}
			if state == "running" && port != "55444" {
				t.Fatal("ignored running server port")
			}
		})
	}
}

func TestDatabaseStatusAndStopNeverInitialize(t *testing.T) {
	for _, action := range []string{"status", "stop"} {
		app, calls := fakeApp(t)
		writeProjectFile(t, app.Directory, "tesl.toml", "[database]\nmode = managed\n")
		if _, err := app.database(context.Background(), app.Directory, action); err != nil {
			t.Fatal(err)
		}
		if len(*calls) != 0 {
			t.Fatal("uninitialized status/stop launched database tools")
		}
		if _, err := os.Stat(filepath.Join(app.Directory, ".tesl-postgres")); !os.IsNotExist(err) {
			t.Fatal("created cluster")
		}
	}
}

func TestWatchFingerprintUsesContentAndMissingImports(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "app.tesl")
	writeProjectFile(t, root, "app.tesl", "abc")
	paths := []string{file}
	before := watchFingerprint(paths)
	info, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	writeProjectFile(t, root, "app.tesl", "def")
	_ = os.Chtimes(file, info.ModTime(), info.ModTime())
	if before == watchFingerprint(paths) {
		t.Fatal("same-size/time edit not detected")
	}
	before = watchFingerprint(paths)
	writeProjectFile(t, root, "missing.tesl", "module Missing exposing []")
	if before == watchFingerprint(paths) {
		t.Fatal("new import not detected")
	}
	before = watchFingerprint(paths)
	writeProjectFile(t, root, "editor.tmp", "irrelevant")
	if before != watchFingerprint(paths) {
		t.Fatal("unrelated file causes restart")
	}
	_ = os.Remove(file)
	if before == watchFingerprint(paths) {
		t.Fatal("deleted source not detected")
	}
}

func TestWatchStopsOldExecutionBeforeRestartAndOnCancel(t *testing.T) {
	app, _ := fakeApp(t)
	app.Stdout, app.Stderr = &synchronizedOutput{}, &synchronizedOutput{}
	writeProjectFile(t, app.Directory, "app.tesl", "first")
	writeProjectFile(t, app.Directory, "dependency.tesl", "first")
	var active, peak atomic.Int32
	started := make(chan struct{}, 4)
	app.Execute = func(ctx context.Context, inv Invocation) error {
		if len(inv.Args) > 0 && inv.Args[0] == "--deps" {
			_, _ = io.WriteString(inv.Stdout, filepath.Join(app.Directory, "dependency.tesl")+"\n")
			return nil
		}
		for i, arg := range inv.Args {
			if arg == "--out" {
				return os.MkdirAll(filepath.Join(inv.Args[i+1], "cmd", "app"), 0700)
			}
		}
		if len(inv.Args) > 0 && inv.Args[0] == "build" {
			return nil
		}
		n := active.Add(1)
		peak.CompareAndSwap(0, n)
		if n > 1 {
			peak.Store(n)
		}
		started <- struct{}{}
		<-ctx.Done()
		active.Add(-1)
		return ctx.Err()
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- app.Run(ctx, []string{"watch", "app.tesl"}) }()
	waitStart := func() {
		t.Helper()
		select {
		case <-started:
		case <-time.After(5 * time.Second):
			t.Fatal("watch did not start")
		}
	}
	waitStart()
	writeProjectFile(t, app.Directory, "dependency.tesl", "second")
	waitStart()
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("watch did not stop")
	}
	if active.Load() != 0 || peak.Load() != 1 {
		t.Fatalf("active=%d peak=%d", active.Load(), peak.Load())
	}
}

func TestWorkingDirectoryOverrideIsScoped(t *testing.T) {
	app, calls := fakeApp(t)
	original := app.Directory
	writeProjectFile(t, original, "nested project/tesl.toml", "[project]\nentrypoint = app.tesl\n")
	writeProjectFile(t, original, "nested project/app.tesl", "module App exposing []\n")
	if err := app.Run(context.Background(), []string{"-C", "nested project", "check"}); err != nil {
		t.Fatal(err)
	}
	if app.Directory != original {
		t.Fatal("-C mutated caller")
	}
	if (*calls)[0].Directory != filepath.Join(original, "nested project") {
		t.Fatal("-C ignored")
	}
	if err := app.Run(context.Background(), []string{"-C", "missing", "check"}); err == nil {
		t.Fatal("accepted nonexistent cwd")
	}
}

func TestCleanExplicitBuildRootAndHelp(t *testing.T) {
	app, _ := fakeApp(t)
	writeProjectFile(t, app.Directory, "custom build/generated", "generated")
	writeProjectFile(t, app.Directory, "custom notes", "keep")
	app.Environment = append(app.Environment, "TESL_BUILD_DIR=custom build")
	if err := app.Run(context.Background(), []string{"clean", "--help"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(app.Directory, "custom build/generated")); err != nil {
		t.Fatal("help deleted output")
	}
	if err := app.Run(context.Background(), []string{"clean"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(app.Directory, "custom build")); !os.IsNotExist(err) {
		t.Fatal("ignored selected build directory")
	}
	app.Environment = append(app.Environment, "TESL_BUILD_DIR=.")
	if err := app.Run(context.Background(), []string{"clean"}); err == nil {
		t.Fatal("accepted project root as generated output")
	}
	if _, err := os.Stat(filepath.Join(app.Directory, "custom notes")); err != nil {
		t.Fatal("deleted user data")
	}
}
