package tooling

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// A native helper works under Windows too: no shell, signals or Bash fixture.
func TestMain(m *testing.M) {
	if mode := os.Getenv("TESL_SESSION_TEST_HELPER"); mode != "" {
		sessionHelper(mode)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func sessionHelper(mode string) {
	input, output := os.Stdin, os.Stdout
	if input == nil || output == nil {
		os.Exit(2)
	}
	if mode == "bad-handshake" {
		_ = writeWorkspaceFrame(output, []byte(`{"version":99,"protocol":"tesl-workspace"}`))
		return
	}
	_ = writeWorkspaceFrame(output, []byte(`{"version":1,"protocol":"tesl-workspace"}`))
	for {
		fields := make([][]byte, 5)
		for i := range fields {
			value, err := readWorkspaceFrame(input, 8192)
			if err != nil {
				return
			}
			fields[i] = value
		}
		switch mode {
		case "hang":
			time.Sleep(time.Minute)
		case "crash":
			os.Exit(9)
		case "oversized":
			_, _ = os.Stdout.Write([]byte{255, 255, 255, 255})
			time.Sleep(time.Minute)
		case "truncated":
			_, _ = os.Stdout.Write([]byte{0, 0, 0, 100, 'x'})
			return
		}
		snapshot := string(fields[0])
		if mode == "stale" {
			snapshot = "previous-revision"
		}
		result := `{"version":1,"diagnostics":[]}`
		if mode == "bad-schema" {
			result = `{"version":1}`
		}
		response := fmt.Sprintf(`{"version":1,"snapshot":%q,"exit_code":0,"result":%s,"error":null}`, snapshot, result)
		_ = writeWorkspaceFrame(output, []byte(response))
	}
}

func sessionTestClient(t testing.TB) Client {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "../../../.."))
	executable := filepath.Join(root, "compiler/_build/default/bin/main.exe")
	if _, err := os.Stat(executable); err != nil {
		t.Skip("build compiler to run retained-session integration tests")
	}
	client := Client{Executable: executable, Sessions: NewWorkspaceSessions(), Environment: withEnvironment(os.Environ(), "TESL_REPO_ROOT", root)}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

func testExecutable(t testing.TB) string {
	t.Helper()
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func workspaceState(t *testing.T, client Client) *WorkspaceSessions {
	t.Helper()
	sessions := client.Sessions
	if sessions == nil {
		t.Fatal("expected retained workspace sessions")
	}
	return sessions
}

func runningWorkspaceProcess(t *testing.T, client Client) *workspaceProcess {
	t.Helper()
	process := workspaceState(t, client).process
	if process == nil {
		t.Fatal("expected a running workspace compiler")
	}
	return process
}

func sessionProject(t testing.TB) (string, string) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "project space räksmörgås")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tesl.toml"), []byte("entry = \"main.tesl\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	return root, filepath.Join(root, "main.tesl")
}

func TestBuiltCompilerWorkspaceInstalledStdlibDiscovery(t *testing.T) {
	client := sessionTestClient(t)
	// Defers run before TempDir cleanups. Windows cannot remove the installed
	// executable while the retained compiler still has it open.
	defer func() {
		if err := client.Close(); err != nil {
			t.Error(err)
		}
	}()
	repo := filepath.Clean(filepath.Join(filepath.Dir(client.Executable), "../../../.."))
	prefix := filepath.Join(t.TempDir(), "installed å toolchain")
	installed := filepath.Join(prefix, "bin", "tesl-compiler")
	if runtime.GOOS == "windows" {
		installed += ".exe"
	}
	stdlib := filepath.Join(prefix, "share", "tesl", "stdlib")
	if err := os.MkdirAll(filepath.Dir(installed), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(stdlib, 0700); err != nil {
		t.Fatal(err)
	}
	copyFile := func(from, to string, mode os.FileMode) {
		t.Helper()
		data, err := os.ReadFile(from)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(to, data, mode); err != nil {
			t.Fatal(err)
		}
	}
	copyFile(client.Executable, installed, 0755)
	paths, err := filepath.Glob(filepath.Join(repo, "tesl", "*.tesl"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("missing bundled stdlib: %v", err)
	}
	for _, path := range paths {
		copyFile(path, filepath.Join(stdlib, filepath.Base(path)), 0600)
	}
	client.Executable = installed
	client.Environment = withoutEnvironment(withoutEnvironment(client.Environment, "TESL_STDLIB_DIR"), "TESL_REPO_ROOT")
	root, entry := sessionProject(t)
	client.Directory = root
	source := "module Main exposing [leap]\nimport Tesl.Prelude exposing [Int, Bool]\nimport Tesl.CivilTime exposing [CivilTime.isLeapYear]\nfn leap(year: Int) -> Bool = CivilTime.isLeapYear year\n"
	check := func(client Client, wantOK bool) {
		t.Helper()
		payload, result, err := client.QuerySourceJSON(context.Background(), "--agent-context-json", entry, source)
		if err != nil {
			t.Fatal(err)
		}
		var response struct {
			OK bool `json:"ok"`
		}
		if json.Unmarshal(payload, &response) != nil || response.OK != wantOK || (result.ExitCode == 0) != wantOK {
			t.Fatalf("installed stdlib ok=%v, exit=%d: %s", wantOK, result.ExitCode, payload)
		}
	}
	fresh := client
	fresh.Sessions = nil
	check(fresh, true)
	check(client, true)
	// Explicit override wins over resources adjacent to the executable. It must
	// not fall back to the working checkout when the selected library is absent.
	empty := t.TempDir()
	client.Environment = withEnvironment(client.Environment, "TESL_STDLIB_DIR", empty)
	check(client, false)
	// Resolve the actual compiler location, not a symlink's unrelated directory.
	link := filepath.Join(t.TempDir(), filepath.Base(installed))
	if err := os.Symlink(installed, link); err == nil {
		fresh.Executable = link
		check(fresh, true)
	} else if runtime.GOOS != "windows" {
		t.Fatal(err)
	}
	process := runningWorkspaceProcess(t, client)
	t.Cleanup(func() {
		select {
		case <-process.done:
		default:
			t.Error("installed compiler must exit before its temporary installation is removed")
		}
	})
}

const sessionSource = "module Main exposing [twice]\nimport Tesl.Prelude exposing [Int]\nimport Helper exposing [number]\nfn twice() -> Int = number() * 2\n"
const sessionHelperSource = "module Helper exposing [number]\nimport Tesl.Prelude exposing [Int]\nfn number() -> Int = 4\n"

func TestBuiltCompilerWorkspaceMatchesFreshQueries(t *testing.T) {
	client := sessionTestClient(t)
	root, entry := sessionProject(t)
	helper := filepath.Join(root, "helper.tesl")
	if err := os.WriteFile(helper, []byte(sessionHelperSource), 0600); err != nil {
		t.Fatal(err)
	}
	fresh := client
	fresh.Sessions = nil
	flags := []string{"--check-json", "--agent-context-json", "--local-bindings-json", "--semantic-json", "--type-at-json", "--field-at-json", "--definition-json", "--type-definition-json", "--occurrences-json", "--signature-help-json", "--completions-json", "--selection-range-json", "--config-context-json"}
	for _, source := range []string{sessionSource, strings.ReplaceAll(sessionSource, "\n", "\r\n")} {
		for _, flag := range flags {
			t.Run(flag+fmt.Sprint(strings.Contains(source, "\r")), func(t *testing.T) {
				position := []string{"3", "22"}
				if flag == "--check-json" || flag == "--agent-context-json" || flag == "--semantic-json" || flag == "--local-bindings-json" {
					position = nil
				}
				expected, expectedResult, err := fresh.QuerySourceJSON(context.Background(), flag, entry, source, position...)
				if err != nil {
					t.Fatal(err)
				}
				for i := 0; i < 2; i++ {
					got, result, err := client.QuerySourceJSON(context.Background(), flag, entry, source, position...)
					if err != nil {
						t.Fatal(err)
					}
					var wantJSON, gotJSON any
					_ = json.Unmarshal(expected, &wantJSON)
					_ = json.Unmarshal(got, &gotJSON)
					if !reflect.DeepEqual(wantJSON, gotJSON) || result.ExitCode != expectedResult.ExitCode {
						t.Fatalf("session differs from fresh\nwant %s\ngot %s", expected, got)
					}
				}
			})
		}
	}
	if workspaceState(t, client).starts != 1 {
		t.Fatalf("compiler started %d times", workspaceState(t, client).starts)
	}
	// manifest/helper once, entry twice (LF then CRLF), never per query.
	if workspaceState(t, client).writes != 4 {
		t.Fatalf("mirror wrote %d files", workspaceState(t, client).writes)
	}
	if _, err := os.Stat(entry); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unsaved entry was written into user's workspace")
	}
}

func TestBuiltCompilerWorkspaceRevisions(t *testing.T) {
	client := sessionTestClient(t)
	root, entry := sessionProject(t)
	helper := filepath.Join(root, "helper.tesl")
	write := func(path, source string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(helper, sessionHelperSource)
	query := func(overlays []SourceOverlay) string {
		t.Helper()
		fresh := client
		fresh.Sessions = nil
		want, expectedResult, err := fresh.QuerySourcesJSON(context.Background(), "--check-json", entry, overlays)
		if err != nil {
			t.Fatal(err)
		}
		got, result, err := client.QuerySourcesJSON(context.Background(), "--check-json", entry, overlays)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(want, got) || expectedResult.ExitCode != result.ExitCode {
			t.Fatalf("revision mismatch\nwant %s\ngot %s", want, got)
		}
		return string(got)
	}
	overlay := []SourceOverlay{{entry, sessionSource}}
	baseline := query(overlay)
	// Same-size and same-mtime save must still invalidate dependent diagnostics.
	stat, err := os.Stat(helper)
	if err != nil {
		t.Fatal(err)
	}
	write(helper, strings.Replace(sessionHelperSource, "= 4", "= x", 1))
	_ = os.Chtimes(helper, stat.ModTime(), stat.ModTime())
	if got := query(overlay); got == baseline {
		t.Fatal("same-size disk edit was stale")
	}
	if got := query(append(overlay, SourceOverlay{helper, sessionHelperSource})); got != baseline {
		t.Fatal("unsaved import did not override disk")
	}
	if got := query(overlay); got == baseline {
		t.Fatal("closing import failed to restore disk contents")
	}
	write(helper, sessionHelperSource)
	if got := query(overlay); got != baseline {
		t.Fatal("saved repair not visible")
	}
	if err := os.Remove(helper); err != nil {
		t.Fatal(err)
	}
	if got := query(overlay); got == baseline {
		t.Fatal("deleted module was cached")
	}
	write(helper, sessionHelperSource)
	if got := query(overlay); got != baseline {
		t.Fatal("recreated module was stale")
	}
	broken := []SourceOverlay{{entry, "module Main exposing ["}}
	if got := query(broken); !strings.Contains(got, `"source":"parser"`) {
		t.Fatalf("missing parse diagnostics: %s", got)
	}
	if got := query(overlay); got != baseline {
		t.Fatal("repair after parse error was stale")
	}
	write(filepath.Join(root, "new-module.tesl"), "module NewModule exposing []\n")
	query(overlay)
	before := runningWorkspaceProcess(t, client)
	before.child.Kill()
	<-before.done
	if _, _, err := client.QuerySourcesJSON(context.Background(), "--check-json", entry, overlay); err == nil {
		t.Fatal("crash was hidden")
	}
	if got := query(overlay); got != baseline {
		t.Fatal("crash restart did not reconstruct snapshot")
	}
	if workspaceState(t, client).starts != 2 {
		t.Fatalf("starts = %d", workspaceState(t, client).starts)
	}
	shadow := workspaceState(t, client).shadow
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(shadow); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("shadow leaked after close")
	}
	if _, _, err := client.QuerySourcesJSON(context.Background(), "--check-json", entry, overlay); err == nil {
		t.Fatal("closed session accepted request")
	}
}

func TestBuiltCompilerWorkspaceExternalStdlibChanges(t *testing.T) {
	client := sessionTestClient(t)
	_, entry := sessionProject(t)
	library := t.TempDir()
	if err := os.Mkdir(filepath.Join(library, "tesl"), 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(library, "tesl/list.tesl")
	original := "module List exposing [length]\nimport Tesl.Prelude exposing [List, Int]\nfn length(xs: List a) -> Int = 0\n"
	if err := os.WriteFile(path, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	client.Environment = withEnvironment(client.Environment, "TESL_REPO_ROOT", library)
	source := "module Main exposing [size]\nimport Tesl.Prelude exposing [Int]\nimport Tesl.List exposing [List.length]\nfn size() -> Int = List.length [1]\n"
	first, _, err := client.QuerySourceJSON(context.Background(), "--check-json", entry, source)
	if err != nil {
		t.Fatal(err)
	}
	changed := strings.ReplaceAll(original, "Int", "String")
	changed = strings.Replace(changed, "= 0", `= "oops"`, 1)
	if err := os.WriteFile(path, []byte(changed), 0600); err != nil {
		t.Fatal(err)
	}
	second, _, err := client.QuerySourceJSON(context.Background(), "--check-json", entry, source)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(first, second) {
		t.Fatalf("stdlib edit reused project cache: %s", second)
	}
	fresh := client
	fresh.Sessions = nil
	want, _, err := fresh.QuerySourceJSON(context.Background(), "--check-json", entry, source)
	if err != nil || !bytes.Equal(want, second) {
		t.Fatalf("stdlib change mismatch: %s vs %s, %v", want, second, err)
	}
}

func TestBuiltCompilerWorkspaceRootAndEnvironmentChanges(t *testing.T) {
	client := sessionTestClient(t)
	_, first := sessionProject(t)
	_, second := sessionProject(t)
	source := "module Main exposing []\n"
	for _, entry := range []string{first, second, first} {
		got, _, err := client.QuerySourceJSON(context.Background(), "--agent-context-json", entry, source)
		if err != nil {
			t.Fatal(err)
		}
		var response struct {
			File string `json:"file"`
		}
		if err := json.Unmarshal(got, &response); err != nil || response.File != entry {
			t.Fatalf("wrong project: %s", got)
		}
	}
	if workspaceState(t, client).starts != 3 {
		t.Fatal("different roots shared one process")
	}
	previous := runningWorkspaceProcess(t, client)
	client.Environment = withEnvironment(client.Environment, "TESL_TEST_TOOLCHAIN_REVISION", "next")
	if _, _, err := client.QuerySourceJSON(context.Background(), "--check-json", first, source); err != nil {
		t.Fatal(err)
	}
	if workspaceState(t, client).process == previous {
		t.Fatal("changed toolchain environment reused process")
	}
	select {
	case <-previous.done:
	default:
		t.Fatal("old compiler still running")
	}
}

func TestBuiltCompilerWorkspaceProofAndUnitsCorpus(t *testing.T) {
	client := sessionTestClient(t)
	_, file, _, _ := runtime.Caller(0)
	examples := filepath.Join(filepath.Dir(file), "../../../../example/learn")
	root, _ := sessionProject(t)
	names := []string{"lesson03-records.tesl", "lesson06-proof-check-proof-auth.tesl", "lesson12-records-with-proofs.tesl", "lesson29-forall-list-proofs.tesl", "lesson44-multi-param-proofs.tesl", "lesson52-maybe-proof.tesl", "lesson72-units.tesl"}
	overlays := make([]SourceOverlay, 0, len(names))
	for _, name := range names {
		source, err := os.ReadFile(filepath.Join(examples, name))
		if err != nil {
			t.Fatal(err)
		}
		overlays = append(overlays, SourceOverlay{filepath.Join(root, name), string(source)})
	}
	fresh := client
	fresh.Sessions = nil
	// One snapshot, several modules: cached checker metadata must not inherit a
	// different module's units aliases or proof state when revisited.
	for _, index := range []int{6, 0, 1, 2, 3, 4, 5, 6, 0} {
		for _, flag := range []string{"--semantic-json", "--check-json", "--type-at-json"} {
			t.Run(names[index]+flag, func(t *testing.T) {
				var position []string
				if flag == "--type-at-json" {
					position = []string{"0", "0"}
				}
				want, expected, err := fresh.QuerySourcesJSON(context.Background(), flag, overlays[index].Path, overlays, position...)
				if err != nil {
					t.Fatal(err)
				}
				got, result, err := client.QuerySourcesJSON(context.Background(), flag, overlays[index].Path, overlays, position...)
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(want, got) || expected.ExitCode != result.ExitCode {
					t.Fatalf("retained compiler disagrees on %s\nwant %s\ngot %s", names[index], want, got)
				}
			})
		}
	}
}

func TestWorkspaceSessionProtocolFailures(t *testing.T) {
	for _, mode := range []string{"bad-handshake", "stale", "crash", "oversized", "truncated", "bad-schema", "hang"} {
		t.Run(mode, func(t *testing.T) {
			_, entry := sessionProject(t)
			client := Client{Executable: testExecutable(t), Sessions: NewWorkspaceSessions(), Timeout: 1500 * time.Millisecond, Environment: withEnvironment(os.Environ(), "TESL_SESSION_TEST_HELPER", mode)}
			defer func() { _ = client.Close() }()
			start := time.Now()
			if _, _, err := client.QuerySourceJSON(context.Background(), "--check-json", entry, "module Main exposing []\n"); err == nil {
				t.Fatal("invalid session result accepted")
			}
			if time.Since(start) > 5*time.Second {
				t.Fatal("failed process did not terminate promptly")
			}
			if workspaceState(t, client).process != nil {
				t.Fatal("failed session retained")
			}
			// Changed toolchain environment after a failed request starts cleanly.
			client.Environment = withEnvironment(client.Environment, "TESL_SESSION_TEST_HELPER", "ok")
			// The short deadline above tests termination of a broken compiler.
			// Recovery has the normal query budget, including restaging source
			// and stdlib files on loaded CI hosts running the race detector.
			client.Timeout = DefaultCompilerTimeout
			if _, _, err := client.QuerySourceJSON(context.Background(), "--check-json", entry, "module Main exposing []\n"); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestWorkspaceSessionCancellationAndClose(t *testing.T) {
	_, entry := sessionProject(t)
	client := Client{Executable: testExecutable(t), Sessions: NewWorkspaceSessions(), Environment: withEnvironment(os.Environ(), "TESL_SESSION_TEST_HELPER", "hang")}
	// An already-canceled query must not scan or start a process.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := client.QuerySourceJSON(ctx, "--check-json", entry, "module Main exposing []\n"); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled query: %v", err)
	}
	if workspaceState(t, client).starts != 0 {
		t.Fatal("canceled query started compiler")
	}
	// Closing also interrupts the active exchange and canceled queued callers.
	done := make(chan error, 1)
	go func() {
		_, _, err := client.QuerySourceJSON(context.Background(), "--check-json", entry, "module Main exposing []\n")
		done <- err
	}()
	time.Sleep(50 * time.Millisecond)
	queued, cancelQueued := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancelQueued()
	if _, _, err := client.QuerySourceJSON(queued, "--check-json", entry, "module Main exposing []\n"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("queued query: %v", err)
	}
	start := time.Now()
	_ = client.Close()
	if time.Since(start) > 3*time.Second {
		t.Fatal("close waited for full compiler timeout")
	}
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("active query on close: %v", err)
	}
}

func TestWorkspaceSessionConcurrentSnapshots(t *testing.T) {
	client := sessionTestClient(t)
	_, entry := sessionProject(t)
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			source := fmt.Sprintf("module Main exposing [value%d]\nimport Tesl.Prelude exposing [Int]\nfn value%d() -> Int = %d\n", i, i, i)
			got, _, err := client.QuerySourceJSON(context.Background(), "--agent-context-json", entry, source)
			if err != nil {
				t.Error(err)
				return
			}
			if !strings.Contains(string(got), fmt.Sprintf(`"name":"value%d"`, i)) {
				t.Errorf("query saw another overlay: %s", got)
			}
		}(i)
	}
	wg.Wait()
}

func TestWorkspaceFrameBounds(t *testing.T) {
	for _, limit := range []int{-1, DefaultCompilerOutput + 1} {
		if _, err := readWorkspaceFrame(bytes.NewReader([]byte{0, 0, 0, 0}), limit); err == nil {
			t.Fatalf("accepted invalid frame limit %d", limit)
		}
	}
	var rejected bytes.Buffer
	if err := writeWorkspaceFrame(&rejected, make([]byte, DefaultCompilerOutput+1)); err == nil || rejected.Len() != 0 {
		t.Fatal("oversized outgoing frame wrote bytes")
	}
	for _, payload := range [][]byte{nil, {0}, {0, 0, 0, 4, 'a'}, {255, 255, 255, 255}} {
		if _, err := readWorkspaceFrame(bytes.NewReader(payload), 16); err == nil {
			t.Fatalf("accepted %v", payload)
		}
	}
	var buf bytes.Buffer
	if err := writeWorkspaceFrame(&buf, []byte("😀\r\n\x00")); err != nil {
		t.Fatal(err)
	}
	got, err := readWorkspaceFrame(&buf, 16)
	if err != nil || string(got) != "😀\r\n\x00" {
		t.Fatalf("roundtrip %q %v", got, err)
	}
	if _, err := readWorkspaceFrame(&buf, 16); !errors.Is(err, io.EOF) {
		t.Fatal(err)
	}
}

type shortWorkspaceWriter struct{ calls, shortAt int }

func (writer *shortWorkspaceWriter) Write(data []byte) (int, error) {
	writer.calls++
	if writer.calls == writer.shortAt {
		return len(data) - 1, nil
	}
	return len(data), nil
}

func TestWorkspaceFrameRefusesShortWrites(t *testing.T) {
	for _, call := range []int{1, 2} {
		writer := &shortWorkspaceWriter{shortAt: call}
		if err := writeWorkspaceFrame(writer, []byte("body")); !errors.Is(err, io.ErrShortWrite) {
			t.Fatalf("short write %d accepted: %v", call, err)
		}
	}
}

func BenchmarkWorkspaceRepeatedQuery(b *testing.B) {
	for _, retained := range []bool{false, true} {
		b.Run(fmt.Sprint("retained=", retained), func(b *testing.B) {
			client := sessionTestClient(b)
			if !retained {
				client.Sessions = nil
			}
			root, entry := sessionProject(b)
			if err := os.WriteFile(filepath.Join(root, "helper.tesl"), []byte(sessionHelperSource), 0600); err != nil {
				b.Fatal(err)
			}
			if _, _, err := client.QuerySourceJSON(context.Background(), "--check-json", entry, sessionSource); err != nil {
				b.Fatal(err)
			}
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, _, err := client.QuerySourceJSON(context.Background(), "--check-json", entry, sessionSource); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
