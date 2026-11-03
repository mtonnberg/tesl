package migrationtest

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/migrationtest/compilerfixture"
)

// One immutable candidate per process. A changed checkout is an error, never a
// second, mixed candidate. Only the compiler executables are reused.
var migrationCompilers struct {
	sync.Mutex
	directory string
	key       string
	inputs    string
	binaries  [3]string
	hashes    [3]string
	buildTime time.Duration
	root      string
}

func TestMain(m *testing.M) {
	code := m.Run()
	if migrationCompilers.directory != "" {
		if err := checkMigrationCompilers(); err != nil {
			fmt.Fprintln(os.Stderr, "compiler cache final integrity:", err)
			code = 1
		}
		if err := os.RemoveAll(migrationCompilers.directory); err != nil {
			fmt.Fprintln(os.Stderr, "compiler cache cleanup:", err)
			code = 1
		}
	}
	os.Exit(code)
}

func compilerDigest(data []byte) string {
	return compilerfixture.Digest(data)
}

func compilerInputManifest(root string) (string, error) {
	return compilerfixture.Manifest(root)
}

func compilerCacheSnapshot(ctx context.Context, root string) (string, string, error) {
	manifest, err := compilerInputManifest(root)
	if err != nil {
		return "", "", err
	}
	parts := []string{manifest, root, "dune build bin/main.exe -j 2"}
	environment := os.Environ()
	slices.Sort(environment)
	parts = append(parts, environment...)
	configHome := os.Getenv("XDG_CONFIG_HOME")
	if configHome == "" {
		configHome = filepath.Join(os.Getenv("HOME"), ".config")
	}
	configPath := filepath.Join(configHome, "dune/config")
	config, err := os.ReadFile(configPath)
	if err != nil && !os.IsNotExist(err) {
		return "", "", err
	}
	parts = append(parts, configPath, fmt.Sprint(os.IsNotExist(err)), compilerDigest(config))
	// Hash the actual fixture/caching recipe as well as the tool executables and
	// their reported configuration. Nix store paths also bind library closures.
	for _, file := range []string{"compiler_upgrade_test.go", "compiler_cache_test.go", "compilerfixture/manifest.go", "compilerfixture/integrity.go"} {
		data, err := os.ReadFile(filepath.Join(root, "runtime/go/internal/migrationtest", file))
		if err != nil {
			return "", "", err
		}
		parts = append(parts, file, compilerDigest(data))
	}
	for _, tool := range []string{"dune", "ocamlc", "ocamlopt", "go", "cc"} {
		path, err := exec.LookPath(tool)
		if err != nil {
			return "", "", err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return "", "", err
		}
		args := []string{"--version"}
		switch tool {
		case "ocamlc", "ocamlopt":
			args = []string{"-config"}
		case "go":
			args = []string{"version"}
		}
		out, err := exec.CommandContext(ctx, path, args...).CombinedOutput()
		if err != nil {
			return "", "", fmt.Errorf("compiler toolchain %s: %w: %s", tool, err, out)
		}
		parts = append(parts, tool, path, compilerDigest(data), string(out))
	}
	key, err := compilerfixture.Key(parts)
	return key, manifest, err
}

func compilerCacheKey(t *testing.T, ctx context.Context, root string) (string, string) {
	t.Helper()
	key, manifest, err := compilerCacheSnapshot(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	return key, manifest
}

func checkMigrationCompilers() error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	key, _, err := compilerCacheSnapshot(ctx, migrationCompilers.root)
	if err != nil {
		return err
	}
	if err := compilerfixture.Check(migrationCompilers.key, key); err != nil {
		return err
	}
	for i, path := range migrationCompilers.binaries {
		if _, err := compilerfixture.Binary(path, migrationCompilers.hashes[i]); err != nil {
			return err
		}
	}
	return nil
}

func validateCompilerClone(t *testing.T, clone string) {
	t.Helper()
	manifest, err := compilerInputManifest(clone)
	if err != nil || manifest != migrationCompilers.inputs {
		t.Fatalf("compiler inputs changed during capture: %v", err)
	}
}

func buildMigrationCompilerVariants(t *testing.T, ctx context.Context, root string) (string, string, string) {
	t.Helper()
	started := time.Now()
	migrationCompilers.Lock()
	defer migrationCompilers.Unlock()
	key, manifest := compilerCacheKey(t, ctx, root)
	if err := compilerfixture.Check(migrationCompilers.key, key); err != nil {
		t.Fatal(err)
	}
	hit := migrationCompilers.key != ""
	if !hit {
		var err error
		migrationCompilers.directory, err = os.MkdirTemp("", "tesl-migration-compilers-")
		if err != nil {
			t.Fatal(err)
		}
		migrationCompilers.inputs = manifest
		migrationCompilers.root = root
		migrationCompilers.key = key // A failed build stays poisoned for this process.
		t.Logf("compiler cache captured_input_manifest=%s", manifest)
		started := time.Now()
		a, b, c := buildUncachedMigrationCompilerVariants(t, ctx, root)
		migrationCompilers.buildTime = time.Since(started)
		migrationCompilers.binaries = [3]string{a, b, c}
	}
	for i, path := range migrationCompilers.binaries {
		hash, err := compilerfixture.Binary(path, migrationCompilers.hashes[i])
		if err != nil {
			t.Fatal(err)
		}
		migrationCompilers.hashes[i] = hash
	}
	endKey, _ := compilerCacheKey(t, ctx, root)
	if endKey != key {
		t.Fatal("compiler inputs/environment changed during build or validation")
	}
	t.Logf("compiler cache hit=%t inputs=%s key=%s binaries=%v build_time=%s lookup_total=%s", hit, compilerDigest([]byte(manifest)), key, migrationCompilers.hashes, migrationCompilers.buildTime, time.Since(started))
	t.Cleanup(func() {
		migrationCompilers.Lock()
		defer migrationCompilers.Unlock()
		if err := checkMigrationCompilers(); err != nil {
			t.Error(err)
		}
	})
	return migrationCompilers.binaries[0], migrationCompilers.binaries[1], migrationCompilers.binaries[2]
}
