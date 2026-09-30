package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/install"
)

func testInstaller(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "tesl-install")
	if err := os.WriteFile(path, []byte("standalone installer fixture"), 0755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestStandaloneInstallerHelpAndArgumentErrors(t *testing.T) {
	executable := testInstaller(t)
	for _, args := range [][]string{nil, {"help"}, {"--help"}} {
		var output bytes.Buffer
		if err := run(context.Background(), executable, args, &output, &output); err != nil || !strings.Contains(output.String(), "Usage:") {
			t.Fatalf("help %q: %s %v", args, &output, err)
		}
	}
	for _, scenario := range []struct {
		args []string
		want string
	}{
		{[]string{"install"}, "no embedded ZIP"},
		{[]string{"install", "--archive", "file.zip"}, "requires --archive and --sha256"},
		{[]string{"install", "--sha256", strings.Repeat("a", 64)}, "requires --archive and --sha256"},
		{[]string{"select"}, "version is required"},
		{[]string{"uninstall"}, "version is required"},
		{[]string{"list", "--archive", "file.zip"}, "apply only to install"},
		{[]string{"list", "unexpected"}, "unexpected positional"},
		{[]string{"bogus"}, "unknown installer command"},
	} {
		var output bytes.Buffer
		err := run(context.Background(), executable, scenario.args, &output, &output)
		if err == nil || !strings.Contains(err.Error(), scenario.want) {
			t.Fatalf("args %q: %v", scenario.args, err)
		}
	}
}

func TestListAndStateJSONRespectExplicitRoot(t *testing.T) {
	executable := testInstaller(t)
	root := filepath.Join(t.TempDir(), "managed root å")
	for _, directory := range []string{"bin", "versions", "leases"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0700); err != nil {
			t.Fatal(err)
		}
	}
	digest := sha256.Sum256([]byte("standalone installer fixture"))
	marker := `{"version":1,"kind":"tesl-managed-installation","launcher_sha256":"` + hex.EncodeToString(digest[:]) + `"}`
	if err := os.WriteFile(filepath.Join(root, ".tesl-install.json"), []byte(marker), 0600); err != nil {
		t.Fatal(err)
	}
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, action := range []string{"list", "state"} {
		var output, diagnostics bytes.Buffer
		if err := run(context.Background(), executable, []string{action, "--root", root, "--json"}, &output, &diagnostics); err != nil {
			t.Fatal(err)
		}
		var result install.Result
		if err := json.Unmarshal(output.Bytes(), &result); err != nil {
			t.Fatalf("invalid JSON: %s %v", &output, err)
		}
		if result.Version != 1 || result.Action != action || result.Root != canonical || result.State.Version != 1 || result.Installed == nil || diagnostics.Len() != 0 {
			t.Fatalf("state result: %+v, stderr: %s", result, &diagnostics)
		}
	}
}

func TestEmbeddedInstallerDefaultsToInstallAndRejectsCorruption(t *testing.T) {
	// Deliberately corrupt hash establishes that no-argument setup reaches
	// archive verification without creating a user installation.
	executable := testInstaller(t)
	prefix, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	archive := []byte("PK corrupt fixture")
	footer := make([]byte, install.FooterSize)
	copy(footer, install.FooterMagic)
	binary.LittleEndian.PutUint64(footer[16:24], uint64(len(prefix)))
	binary.LittleEndian.PutUint64(footer[24:32], uint64(len(archive)))
	if err := os.WriteFile(executable, append(append(prefix, archive...), footer...), 0755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{nil, {"install", "--root", filepath.Join(t.TempDir(), "installation")}} {
		var output bytes.Buffer
		err := run(context.Background(), executable, args, &output, &output)
		if err == nil || !strings.Contains(err.Error(), "embedded ZIP checksum") {
			t.Fatalf("embedded args %q: %v", args, err)
		}
	}
}
