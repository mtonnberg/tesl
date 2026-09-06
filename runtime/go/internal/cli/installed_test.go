package cli

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/childprocess"
	"tesl.dev/runtime/go/internal/toolchain"
)

// This gate consumes the assembled payload, rather than constructing an
// installation from the runner's tools. An external network sandbox is still
// needed to establish offline installation: unusable proxies alone do not
// prevent arbitrary processes from opening outbound connections.
func TestInstalledToolchainWorkflow(t *testing.T) {
	source := os.Getenv("TESL_TEST_INSTALLED_ROOT")
	if source == "" {
		t.Skip("set TESL_TEST_INSTALLED_ROOT to an unpacked complete native payload")
	}
	work := t.TempDir()
	t.Cleanup(func() {
		// Extracted Go modules and the tested installation are read-only.
		_ = filepath.WalkDir(work, func(path string, entry fs.DirEntry, err error) error {
			if err == nil && entry.IsDir() {
				return os.Chmod(path, 0755)
			}
			return err
		})
	})
	install := filepath.Join(work, "relocated installation å with spaces")
	if err := copyInstalledPayload(source, install); err != nil {
		t.Fatal(err)
	}
	suffix := ""
	if runtime.GOOS == "windows" {
		suffix = ".exe"
	}
	binary := filepath.Join(install, "bin", "tesl"+suffix)
	resolver := toolchain.Resolver{Executable: binary, GOOS: runtime.GOOS}
	manifest, canonicalInstall, err := resolver.Load()
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Target != runtime.GOOS+"-"+runtime.GOARCH {
		t.Fatalf("payload target %q does not match this runner", manifest.Target)
	}
	for _, component := range []string{"tesl", "compiler", "go", "postgres", "initdb", "pg_ctl", "createdb", "psql", "stdlib", "templates", "doc", "go-modules", "licenses", "tesl-lsp", "tesl-dap", "tesl-mcp", "tesl-debug-inspect", "tesl-debug-attach"} {
		if _, err := resolver.Resolve(component); err != nil {
			t.Fatalf("complete payload requires %s: %v", component, err)
		}
	}
	if runtime.GOOS != "windows" {
		if err := filepath.WalkDir(install, func(path string, entry fs.DirEntry, err error) error {
			if err != nil || entry.Type()&os.ModeSymlink != 0 {
				return err
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			return os.Chmod(path, info.Mode().Perm()&0555)
		}); err != nil {
			t.Fatal(err)
		}
	}
	before := installedPayloadSnapshot(t, install)
	env := installedAcceptanceEnvironment(work)
	for _, name := range []string{"home", "config", "local", "cache", "empty-path", "tmp"} {
		if err := os.MkdirAll(filepath.Join(work, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	run := func(directory, executable string, args ...string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
		defer cancel()
		output, err := runInstalledCommand(ctx, directory, env, executable, args...)
		if err != nil {
			t.Fatalf("%s %v: %v\n%s", executable, args, err, output)
		}
		return output
	}
	var report toolchain.Report
	if err := json.Unmarshal([]byte(run(work, binary, "doctor", "--json")), &report); err != nil {
		t.Fatal(err)
	}
	if !report.OK || report.Root != canonicalInstall || report.ToolchainVersion != manifest.ToolchainVersion || report.SourceRevision != manifest.SourceRevision {
		t.Fatalf("installed identity/doctor mismatch: %+v", report)
	}
	for _, component := range report.Components {
		if !component.Optional && component.Path != filepath.Join(canonicalInstall, filepath.FromSlash(manifest.Components[component.Name].Path)) {
			t.Fatalf("doctor resolved %s outside the relocated payload: %s", component.Name, component.Path)
		}
	}
	if output := run(work, binary, "version"); !strings.HasPrefix(output, "tesl "+manifest.ToolchainVersion+"\n") {
		t.Fatalf("version does not match payload: %s", output)
	}

	t.Log("scaffold and compile using only installed components and fresh user caches")
	project := filepath.Join(work, "project å with spaces")
	run(work, binary, "init", filepath.Base(project), "--template", "api", "--postgres", "managed", "--yes", "--no-git")
	t.Cleanup(func() {
		if t.Failed() {
			if log, err := os.ReadFile(filepath.Join(project, ".tesl-postgres", "postgres.log")); err == nil {
				if len(log) > 16384 {
					log = log[len(log)-16384:]
				}
				t.Logf("temporary PostgreSQL log:\n%s", log)
			}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if output, err := runInstalledCommand(ctx, project, env, binary, "db", "stop"); err != nil {
			t.Errorf("stop installed managed database: %v\n%s", err, output)
		}
	})
	for _, args := range [][]string{{"agent-context", "app.tesl"}, {"check"}, {"test"}, {"build", "--local"}} {
		t.Logf("installed tesl %s", strings.Join(args, " "))
		run(project, binary, args...)
	}
	if info, err := os.Stat(filepath.Join(project, ".tesl-stuff", "go-build", "tesl-app"+suffix)); err != nil || !info.Mode().IsRegular() {
		t.Fatalf("local build did not produce an application executable: %v", err)
	}
	run(project, binary, "db", "start")
	if output := run(project, binary, "db", "status"); !strings.Contains(output, "running") {
		t.Fatalf("database did not start: %s", output)
	}
	portBytes, err := os.ReadFile(filepath.Join(project, ".tesl-postgres", "PORT"))
	if err != nil {
		t.Fatal(err)
	}
	port := strings.TrimSpace(string(portBytes))
	if !validPort(port) {
		t.Fatalf("invalid saved PostgreSQL port: %q", port)
	}
	psql, err := resolver.Resolve("psql")
	if err != nil {
		t.Fatal(err)
	}
	sql := func(query string) string {
		t.Helper()
		return run(project, psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", "127.0.0.1", "-p", port, "-U", "app", "-d", "app", "-tAc", query)
	}
	for setting, want := range map[string]string{"unix_socket_directories": "", "listen_addresses": "127.0.0.1"} {
		if value := strings.TrimSpace(sql("show " + setting)); value != want {
			t.Fatalf("installed managed database %s = %q, want %q", setting, value, want)
		}
	}
	sql("create table installation_preserved (n integer); insert into installation_preserved values (42)")
	writeProjectFile(t, project, ".tesl-stuff/user-notes.txt", "preserve user files\n")
	userFiles := map[string][]byte{}
	for _, path := range []string{"app.tesl", "tesl.toml", ".env", ".tesl-stuff/user-notes.txt"} {
		data, err := os.ReadFile(filepath.Join(project, path))
		if err != nil {
			t.Fatal(err)
		}
		userFiles[path] = data
	}

	t.Log("serve a database-backed authenticated request, then restart without losing data")
	stop := serveInstalledAPI(t, project, binary, env)
	stop()
	run(project, binary, "clean")
	run(project, binary, "db", "stop")
	if output := run(project, binary, "db", "status"); !strings.Contains(output, "stopped") {
		t.Fatalf("database did not stop: %s", output)
	}
	run(project, binary, "db", "start")
	if output := sql("select n from installation_preserved"); strings.TrimSpace(output) != "42" {
		t.Fatalf("restart/clean lost database contents: %q", output)
	}
	stop = serveInstalledAPI(t, project, binary, env)
	stop()
	run(project, binary, "db", "stop")
	for path, original := range userFiles {
		current, err := os.ReadFile(filepath.Join(project, path))
		if err != nil || !bytes.Equal(current, original) {
			t.Fatalf("user file changed: %s (%v)", path, err)
		}
	}
	if !reflect.DeepEqual(before, installedPayloadSnapshot(t, install)) {
		t.Fatal("installed payload changed while checking/building/running a project")
	}
}

func installedAcceptanceEnvironment(work string) []string {
	// Construct a new environment, so compiler/loader, Go, PostgreSQL and Tesl
	// overrides from a developer shell cannot conceal missing payload files.
	env := []string{}
	path := filepath.Join(work, "empty-path")
	if runtime.GOOS == "windows" {
		for _, key := range []string{"SystemRoot", "WINDIR", "COMSPEC", "PATHEXT"} {
			if value := os.Getenv(key); value != "" {
				env = append(env, key+"="+value)
			}
		}
		path = filepath.Join(os.Getenv("SystemRoot"), "System32")
	}
	for key, value := range map[string]string{
		"PATH": path, "HOME": filepath.Join(work, "home"), "USERPROFILE": filepath.Join(work, "home"),
		"APPDATA": filepath.Join(work, "config"), "LOCALAPPDATA": filepath.Join(work, "local"),
		"XDG_CONFIG_HOME": filepath.Join(work, "config"), "XDG_CACHE_HOME": filepath.Join(work, "cache"),
		"TMPDIR": filepath.Join(work, "tmp"), "TMP": filepath.Join(work, "tmp"), "TEMP": filepath.Join(work, "tmp"),
		"GOCACHE": filepath.Join(work, "cache", "go-build"), "GOMODCACHE": filepath.Join(work, "cache", "go-mod"),
		"GOMAXPROCS": "2", "GOFLAGS": "-p=2 -buildvcs=false", "LC_ALL": "C",
		"GOPROXY": "http://127.0.0.1:1", "HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1",
		"NO_PROXY": "127.0.0.1,localhost", "SESSION_JWT_SECRET": "installed-acceptance-session-key",
	} {
		env = append(env, key+"="+value)
	}
	return env
}

func runInstalledCommand(ctx context.Context, directory string, env []string, executable string, args ...string) (string, error) {
	command := exec.CommandContext(ctx, executable, args...)
	command.Dir, command.Env = directory, env
	command.WaitDelay = 10 * time.Second
	if runtime.GOOS != "windows" {
		command.Cancel = func() error { return command.Process.Signal(os.Interrupt) }
	}
	output, err := command.CombinedOutput()
	return string(output), err
}

func serveInstalledAPI(t *testing.T, project, binary string, env []string) func() {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	port := fmt.Sprint(listener.Addr().(*net.TCPAddr).Port)
	_ = listener.Close()
	command := exec.Command(binary, "run")
	command.Dir, command.Env = project, toolchain.Setenv(env, "PORT", port)
	output := &synchronizedOutput{}
	command.Stdout, command.Stderr = output, output
	child, err := childprocess.Start(command)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = child.Wait(); close(done) }()
	var once sync.Once
	stop := func() {
		once.Do(func() {
			if runtime.GOOS == "windows" {
				child.Kill()
			} else {
				_ = command.Process.Signal(os.Interrupt)
			}
			select {
			case <-done:
			case <-time.After(15 * time.Second):
				child.Kill()
				t.Error("installed server did not stop promptly")
			}
			if connection, err := net.DialTimeout("tcp4", address, time.Second); err == nil {
				_ = connection.Close()
				t.Error("installed server listener survived cancellation")
			}
		})
	}
	t.Cleanup(stop)
	client := &http.Client{Timeout: time.Second, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	deadline := time.Now().Add(3 * time.Minute)
	for {
		select {
		case <-done:
			t.Fatalf("installed server exited before serving: %s", output.String())
		default:
		}
		response, err := client.Get("http://" + address + "/todos/todo-1")
		if err == nil && response != nil {
			_, _ = io.Copy(io.Discard, response.Body)
			_ = response.Body.Close()
			if response.StatusCode != http.StatusUnauthorized {
				t.Fatalf("unauthenticated API returned %d: %s", response.StatusCode, output.String())
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("installed API never became reachable: %s", output.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
	claims := fmt.Sprintf(`{"sub":"demo","iat":%d,"exp":%d}`, time.Now().Unix(), time.Now().Add(time.Hour).Unix())
	token := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`)) + "." + base64.RawURLEncoding.EncodeToString([]byte(claims))
	mac := hmac.New(sha256.New, []byte("installed-acceptance-session-key"))
	_, _ = mac.Write([]byte(token))
	token += "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	request, err := http.NewRequest(http.MethodGet, "http://"+address+"/todos/todo-1", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.AddCookie(&http.Cookie{Name: "__Host-session", Value: token})
	response, err := client.Do(request)
	if err != nil || response == nil {
		t.Fatalf("authenticated request failed: %v", err)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	_ = response.Body.Close()
	if err != nil || response.StatusCode != http.StatusOK || !bytes.Contains(body, []byte("Read the Tesl tutorial")) {
		t.Fatalf("database-backed API response: %d %s (%v)\n%s", response.StatusCode, body, err, output.String())
	}
	return stop
}

func copyInstalledPayload(source, destination string) error {
	root, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return err
	}
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		to := filepath.Join(destination, relative)
		if entry.IsDir() {
			return os.MkdirAll(to, 0755)
		}
		if entry.Type()&os.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			resolved, err := filepath.EvalSymlinks(path)
			if err != nil {
				return err
			}
			contained, err := filepath.Rel(root, resolved)
			if filepath.IsAbs(target) || err != nil || !filepath.IsLocal(contained) {
				return fmt.Errorf("payload link escapes installation: %s", relative)
			}
			return os.Symlink(target, to)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("unsupported payload entry: %s", relative)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(to, data, info.Mode().Perm())
	})
}

func installedPayloadSnapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	result := map[string]string{}
	if err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		var data []byte
		if entry.Type()&os.ModeSymlink != 0 {
			var target string
			target, err = os.Readlink(path)
			data = []byte(target)
		} else if !entry.IsDir() {
			data, err = os.ReadFile(path)
		}
		result[path] = fmt.Sprintf("%s:%x", info.Mode(), sha256.Sum256(data))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestInstalledAcceptanceEnvironmentIsolation(t *testing.T) {
	for _, key := range []string{"TESL_REPO_ROOT", "TESL_TOOLCHAIN_ROOT", "TESL_COMPILER", "TESL_GO", "TESL_POSTGRES_BIN", "GOROOT", "GOWORK", "GONOPROXY", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "OCAMLLIB"} {
		t.Setenv(key, "host-must-not-leak")
	}
	work := t.TempDir()
	env := installedAcceptanceEnvironment(work)
	for _, value := range env {
		if strings.Contains(value, "host-must-not-leak") || strings.HasPrefix(value, "TESL_") {
			t.Fatalf("host discovery override leaked into installed acceptance: %s", value)
		}
	}
	for _, key := range []string{"HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "GOCACHE", "GOMODCACHE", "TMPDIR", "TMP", "TEMP"} {
		value, found := environmentValue(env, key)
		relative, err := filepath.Rel(work, value)
		if !found || err != nil || !filepath.IsLocal(relative) {
			t.Errorf("%s must select an isolated user path, got %q", key, value)
		}
	}
	path, _ := environmentValue(env, "PATH")
	expectedPath := filepath.Join(work, "empty-path")
	if runtime.GOOS == "windows" {
		expectedPath = filepath.Join(os.Getenv("SystemRoot"), "System32")
	}
	if path != expectedPath {
		t.Fatalf("PATH contains runner tools: %q", path)
	}
}

func TestInstalledPayloadCopyPreservesIndependentFiles(t *testing.T) {
	source, destination := t.TempDir(), filepath.Join(t.TempDir(), "relocated å")
	writeProjectFile(t, source, "bin/program", "payload\n")
	if err := os.Chmod(filepath.Join(source, "bin/program"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := copyInstalledPayload(source, destination); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(destination, "bin/program"))
	if err != nil || string(data) != "payload\n" {
		t.Fatalf("copied payload: %q %v", data, err)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(filepath.Join(destination, "bin/program"))
		if err != nil || info.Mode().Perm() != 0755 {
			t.Fatalf("copy lost executable permissions: %v %v", info, err)
		}
	}
	writeProjectFile(t, destination, "bin/program", "changed\n")
	data, err = os.ReadFile(filepath.Join(source, "bin/program"))
	if err != nil || string(data) != "payload\n" {
		t.Fatalf("copy mutated source payload: %q %v", data, err)
	}
}

func TestInstalledPayloadCopyRejectsNonrelocatableLinks(t *testing.T) {
	for _, variant := range []string{"internal-relative", "external-relative", "absolute-internal", "absolute-external", "dangling"} {
		t.Run(variant, func(t *testing.T) {
			work := t.TempDir()
			source := filepath.Join(work, "source")
			writeProjectFile(t, source, "real", "payload")
			writeProjectFile(t, work, "outside", "host-only")
			target := map[string]string{
				"internal-relative": "real", "external-relative": "../outside", "dangling": "absent",
				"absolute-internal": filepath.Join(source, "real"), "absolute-external": filepath.Join(work, "outside"),
			}[variant]
			if err := os.Symlink(target, filepath.Join(source, "link")); err != nil {
				if runtime.GOOS == "windows" {
					t.Skipf("runner cannot create symbolic links: %v", err)
				}
				t.Fatal(err)
			}
			destination := filepath.Join(work, "destination")
			err := copyInstalledPayload(source, destination)
			if variant != "internal-relative" {
				if err == nil {
					t.Fatal("accepted a link that cannot resolve within the relocated payload")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if target, err := os.Readlink(filepath.Join(destination, "link")); err != nil || target != "real" {
				t.Fatalf("relative payload link was not preserved: %q %v", target, err)
			}
		})
	}
}

func TestInstalledPayloadCopyThroughSymlinkedParent(t *testing.T) {
	work := t.TempDir()
	real := filepath.Join(work, "real")
	writeProjectFile(t, real, "source/real", "payload")
	alias := filepath.Join(work, "alias")
	for link, target := range map[string]string{alias: real, filepath.Join(real, "source/link"): "real"} {
		if err := os.Symlink(target, link); err != nil {
			if runtime.GOOS == "windows" {
				t.Skipf("runner cannot create symbolic links: %v", err)
			}
			t.Fatal(err)
		}
	}
	// Like macOS /var -> /private/var, the source's parent has a different
	// canonical spelling from its valid internal relative link target.
	destination := filepath.Join(work, "destination")
	if err := copyInstalledPayload(filepath.Join(alias, "source"), destination); err != nil {
		t.Fatalf("valid internal link under a symlinked parent was rejected: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(destination, "link"))
	if err != nil || string(data) != "payload" {
		t.Fatalf("relocated internal link is broken: %q %v", data, err)
	}
}
