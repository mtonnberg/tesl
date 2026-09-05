package cli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/toolchain"
)

type synchronizedOutput struct {
	sync.Mutex
	buffer bytes.Buffer
}

func (out *synchronizedOutput) Write(data []byte) (int, error) {
	out.Lock()
	defer out.Unlock()
	return out.buffer.Write(data)
}
func (out *synchronizedOutput) String() string {
	out.Lock()
	defer out.Unlock()
	return out.buffer.String()
}

func TestBuiltCompilerNativeCLIWorkflow(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	repo := filepath.Clean(filepath.Join(filepath.Dir(file), "../../../.."))
	compiler := filepath.Join(repo, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("built compiler unavailable")
	}
	app := New()
	app.Directory = t.TempDir()
	output := &synchronizedOutput{}
	app.Stdout = output
	app.Stderr = output
	getenv := app.Resolver.Getenv
	app.Resolver.Getenv = func(key string) string {
		switch key {
		case "TESL_COMPILER":
			return compiler
		case "TESL_TEMPLATES_DIR":
			return filepath.Join(repo, "templates")
		}
		return getenv(key)
	}
	if err := app.Run(context.Background(), []string{"init", "project å with spaces", "--template", "minimal", "--yes", "--no-git"}); err != nil {
		t.Fatal(err)
	}
	app.Directory = filepath.Join(app.Directory, "project å with spaces")
	for _, args := range [][]string{{"agent-context", "app.tesl"}, {"check"}, {"test"}, {"compile"}, {"build"}} {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		err := app.Run(ctx, args)
		cancel()
		if err != nil {
			t.Fatalf("%v: %v\n%s", args, err, output.String())
		}
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	port := fmt.Sprint(listener.Addr().(*net.TCPAddr).Port)
	_ = listener.Close()
	app.Environment = toolchain.Setenv(app.Environment, "PORT", port)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- app.Run(ctx, []string{"run"}) }()
	client := http.Client{Timeout: time.Second}
	deadline := time.Now().Add(45 * time.Second)
	for {
		select {
		case err := <-done:
			t.Fatalf("server exited: %v\n%s", err, output.String())
		default:
		}
		response, err := client.Get("http://" + address + "/tasks/1")
		if err == nil && response != nil {
			_, _ = io.Copy(io.Discard, response.Body)
			_ = response.Body.Close()
			if response.StatusCode != http.StatusUnauthorized {
				t.Fatalf("auth boundary returned %d\n%s", response.StatusCode, output.String())
			}
			break
		}
		if time.Now().After(deadline) {
			cancel()
			<-done
			t.Fatalf("server never became reachable\n%s", output.String())
		}
		time.Sleep(30 * time.Millisecond)
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancellation: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop")
	}
	if conn, err := net.DialTimeout("tcp4", address, time.Second); err == nil {
		_ = conn.Close()
		t.Fatal("server listener survived cancellation")
	}
	entries, err := os.ReadDir(filepath.Join(app.Directory, ".tesl-stuff"))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "tesl.") {
			t.Fatalf("temporary build survived: %s", entry.Name())
		}
	}
}

func TestManagedPostgresWorkflow(t *testing.T) {
	app := New()
	if _, err := app.Resolver.Resolve("initdb"); err != nil {
		t.Skip("PostgreSQL tools unavailable")
	}
	app.Directory = filepath.Join(t.TempDir(), "database å with spaces")
	output := &synchronizedOutput{}
	app.Stdout, app.Stderr = output, output
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := fmt.Sprint(listener.Addr().(*net.TCPAddr).Port)
	_ = listener.Close()
	writeProjectFile(t, app.Directory, "tesl.toml", "[database]\nmode = managed\n[env]\nTESL_POSTGRES_PORT = "+port+"\n")
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if _, err := app.database(ctx, app.Directory, "stop"); err != nil {
			t.Errorf("stop cluster: %v\n%s", err, output.String())
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	selected, err := app.database(ctx, app.Directory, "start")
	if err != nil {
		t.Fatalf("start: %v\n%s", err, output.String())
	}
	connection := []string{"-h", "127.0.0.1", "-p", selected, "-U", "app", "-d", "app", "-tAc"}
	checkListeners := func() {
		t.Helper()
		for setting, want := range map[string]string{"unix_socket_directories": "", "listen_addresses": "127.0.0.1"} {
			value, err := app.capture(ctx, "psql", app.Directory, append(connection, "show "+setting)...)
			if err != nil || strings.TrimSpace(value) != want {
				t.Fatalf("managed database %s = %q, want %q: %v", setting, value, want, err)
			}
		}
	}
	checkListeners()
	if _, err := app.capture(ctx, "psql", app.Directory, append(connection, "create table preserved (n integer); insert into preserved values (42)")...); err != nil {
		t.Fatal(err)
	}
	if _, err := app.database(ctx, app.Directory, "start"); err != nil {
		t.Fatal(err)
	}
	if err := app.clean(); err != nil {
		t.Fatal(err)
	}
	if _, err := app.database(ctx, app.Directory, "stop"); err != nil {
		t.Fatal(err)
	}
	if _, err := app.database(ctx, app.Directory, "start"); err != nil {
		t.Fatal(err)
	}
	result, err := app.capture(ctx, "psql", app.Directory, append(connection, "select n from preserved")...)
	checkListeners()
	if err != nil || strings.TrimSpace(result) != "42" {
		t.Fatalf("restart lost data: %q, %v", result, err)
	}
}

func TestBuiltCompilerWindowsDebugProjectCompiles(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	repo := filepath.Clean(filepath.Join(filepath.Dir(file), "../../../.."))
	compiler := filepath.Join(repo, "compiler", "_build", "default", "bin", "main.exe")
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
	output := &synchronizedOutput{}
	app.Stdout, app.Stderr = output, output
	writeProjectFile(t, app.Directory, "child.tesl", "module Child exposing [answer]\nimport Tesl.Prelude exposing [Int]\nfn answer() -> Int = 42\n")
	writeProjectFile(t, app.Directory, "app.tesl", "module App exposing [value]\nimport Tesl.Prelude exposing [Int]\nimport Child exposing [answer]\nfn value() -> Int = answer()\ntest \"answer\" {\n  expect value() == 42\n}\n")
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if err := app.compiler(ctx, "agent-context", "app.tesl"); err != nil {
		t.Fatalf("fixture: %v\n%s", err, output.String())
	}
	out := filepath.Join(app.Directory, "generated")
	if err := app.compiler(ctx, "app.tesl", "--out", out, "--debug"); err != nil {
		t.Fatalf("emit: %v\n%s", err, output.String())
	}
	env, err := app.Resolver.GoEnvironment(app.Environment)
	if err != nil {
		t.Fatal(err)
	}
	env = toolchain.Setenv(toolchain.Setenv(toolchain.Setenv(env, "GOOS", "windows"), "GOARCH", "amd64"), "CGO_ENABLED", "0")
	if err := app.invoke(ctx, "go", out, env, "test", "-c", "-mod=readonly", "-o", filepath.Join(app.Directory, "debug.test.exe"), "./internal/teslmodapp"); err != nil {
		t.Fatalf("Windows debug project: %v\n%s", err, output.String())
	}
}
