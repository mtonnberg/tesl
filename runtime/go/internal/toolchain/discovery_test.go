package toolchain

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func writeFixture(t *testing.T, root, path, contents string, mode os.FileMode) string {
	t.Helper()
	path = filepath.Join(root, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func fixture(t *testing.T) (Resolver, map[string]string, string) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "Tesl tools å 😀")
	executable := writeFixture(t, root, "bin/tesl", "launcher", 0755)
	// Discovery follows the launcher to its real installation. Keep the original
	// executable spelling, but expect the canonical root (macOS aliases /var).
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	env := make(map[string]string)
	r := Resolver{Executable: executable, GOOS: runtime.GOOS, Getenv: func(k string) string { return env[k] }, LookPath: func(s string) (string, error) { return "", os.ErrNotExist }}
	return r, env, root
}

func manifestFixture(t *testing.T, root, compiler string) {
	t.Helper()
	m := Manifest{Version: 1, ToolchainVersion: "0.3.1-test", SourceRevision: strings.Repeat("a", 40), Target: "linux-amd64", Components: map[string]Component{"compiler": {Path: compiler, Version: "0.3.1-test"}}}
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	writeFixture(t, root, "share/tesl/toolchain.json", string(data), 0644)
}

func TestRelocatedInstallationAndExplicitOverride(t *testing.T) {
	r, env, root := fixture(t)
	compiler := writeFixture(t, root, "libexec/tesl/compiler", "compiler", 0755)
	manifestFixture(t, root, "libexec/tesl/compiler")
	if got, err := r.Resolve("compiler"); err != nil || got != compiler {
		t.Fatalf("resolve = %q, %v", got, err)
	}
	env["TESL_COMPILER"] = writeFixture(t, t.TempDir(), "custom compiler", "override", 0755)
	if got, err := r.Resolve("compiler"); err != nil || got != env["TESL_COMPILER"] {
		t.Fatalf("override = %q, %v", got, err)
	}
	env["TESL_COMPILER"] += "missing"
	if _, err := r.Resolve("compiler"); err == nil {
		t.Fatal("invalid explicit override silently fell back")
	}
}

func TestSymlinkedLauncherUsesRealInstallation(t *testing.T) {
	for _, directoryLink := range []bool{false, true} {
		name := "launcher"
		if directoryLink {
			name = "installation directory"
		}
		t.Run(name, func(t *testing.T) {
			r, _, root := fixture(t)
			compiler := writeFixture(t, root, "bin/tesl-compiler"+r.suffix(), "compiler", 0755)
			link := filepath.Join(t.TempDir(), "tesl")
			target := r.Executable
			if directoryLink {
				target = root
			}
			if err := os.Symlink(target, link); err != nil {
				t.Skipf("symlinks unavailable: %v", err)
			}
			r.Executable = link
			if directoryLink {
				r.Executable = filepath.Join(link, "bin", "tesl")
			}
			if got, err := r.Resolve("compiler"); err != nil || got != compiler {
				t.Fatalf("symlink = %q, %v", got, err)
			}
		})
	}
}

func TestManifestRejectsMalformedAndUnsafePaths(t *testing.T) {
	for _, path := range []string{"", "../compiler", "bin/../../compiler", "/bin/compiler", "C:/compiler.exe", `bin\compiler.exe`, "./compiler", "bin//compiler"} {
		t.Run(path, func(t *testing.T) {
			r, _, root := fixture(t)
			manifestFixture(t, root, path)
			if _, err := r.Resolve("compiler"); err == nil {
				t.Fatal("invalid manifest accepted")
			}
		})
	}
	for _, data := range []string{`{}`, `{"version":2}`, `{"version":1,"unknown":true}`, `{} {}`, strings.Repeat("x", 2<<20)} {
		r, _, root := fixture(t)
		writeFixture(t, root, "share/tesl/toolchain.json", data, 0644)
		if _, err := r.Resolve("compiler"); err == nil {
			t.Fatal("malformed manifest accepted")
		}
	}
}

func TestPresentInstallationDoesNotMixPATHComponents(t *testing.T) {
	r, env, root := fixture(t)
	manifestFixture(t, root, "missing/compiler")
	fallback := writeFixture(t, t.TempDir(), "go", "wrong version", 0755)
	r.LookPath = func(string) (string, error) { return fallback, nil }
	for _, name := range []string{"compiler", "go"} {
		if _, err := r.Resolve(name); err == nil {
			t.Fatalf("missing %s silently used PATH", name)
		}
	}
	env["TESL_TOOLCHAIN_ROOT"] = t.TempDir()
	if _, err := r.Resolve("compiler"); err == nil {
		t.Fatal("empty explicit root fell back")
	}
}

func TestRepositoryAndNixCompatibility(t *testing.T) {
	r, env, _ := fixture(t)
	env["TESL_REPO_ROOT"] = t.TempDir()
	compiler := writeFixture(t, env["TESL_REPO_ROOT"], "compiler/_build/default/bin/main.exe", "compiler", 0755)
	if got, err := r.Resolve("compiler"); err != nil || got != compiler {
		t.Fatalf("repo = %q, %v", got, err)
	}
	env["TESL_OCAML_COMPILER"] = writeFixture(t, t.TempDir(), "nix-compiler", "compiler", 0755)
	if got, err := r.Resolve("compiler"); err != nil || got != env["TESL_OCAML_COMPILER"] {
		t.Fatalf("Nix = %q, %v", got, err)
	}
}

func TestWindowsSuffixAndPostgresOverride(t *testing.T) {
	r, env, root := fixture(t)
	r.GOOS = "windows"
	compiler := writeFixture(t, root, "bin/tesl-compiler.exe", "compiler", 0644)
	if got, err := r.Resolve("compiler"); err != nil || got != compiler {
		t.Fatalf("Windows = %q, %v", got, err)
	}
	env["TESL_POSTGRES_BIN"] = t.TempDir()
	pg := writeFixture(t, env["TESL_POSTGRES_BIN"], "pg_ctl.exe", "postgres", 0644)
	if got, err := r.Resolve("pg_ctl"); err != nil || got != pg {
		t.Fatalf("Postgres = %q, %v", got, err)
	}
}

func TestDoctorReportsComponentsWithoutEnvironmentSecrets(t *testing.T) {
	r, env, root := fixture(t)
	env["TESL_POSTGRES_PASSWORD"] = "secret-never-print"
	manifestFixture(t, root, "bin/tesl-compiler")
	writeFixture(t, root, "bin/tesl-compiler", "compiler", 0755)
	report := r.Doctor()
	if report.OK || report.SourceRevision == "" || len(report.Components) < 10 {
		t.Fatalf("incomplete report: %+v", report)
	}
	data, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), env["TESL_POSTGRES_PASSWORD"]) {
		t.Fatal("doctor leaked environment")
	}
}

func TestCannotResolveLauncherAsItsOwnCompiler(t *testing.T) {
	r, _, _ := fixture(t)
	r.LookPath = func(string) (string, error) { return r.Executable, nil }
	if _, err := r.Resolve("compiler"); err == nil {
		t.Fatal("recursive compiler invocation")
	}
}

func TestNonExecutableCompilerRejected(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows does not use POSIX executable mode bits")
	}
	r, env, root := fixture(t)
	env["TESL_COMPILER"] = writeFixture(t, root, "file", "compiler", 0644)
	if _, err := r.Resolve("compiler"); err == nil || errors.Is(err, os.ErrNotExist) {
		t.Fatalf("permissions = %v", err)
	}
}
