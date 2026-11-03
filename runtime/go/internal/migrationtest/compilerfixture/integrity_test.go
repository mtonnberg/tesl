package compilerfixture

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestCapturedCandidateRejectsDrift(t *testing.T) {
	parts := []string{"compiler/lib/a.ml", "original bytes", "compiler/bin/dune", "original build rule", "runtime/go/teslrt/a.go", "runtime bytes", "manual/a.md", "documentation bytes", "dune-project bytes", "PATH=/toolchain", "OCAMLPARAM=original", "toolchain hash", "dune build bin/main.exe -j 2", "A/B/C edit recipe"}
	key, err := Key(parts)
	if err != nil {
		t.Fatal(err)
	}
	if err := Check(key, key); err != nil {
		t.Fatal(err)
	}
	for i := range parts {
		changed := make([]string, len(parts))
		copy(changed, parts)
		changed[i] += "-changed"
		actual, err := Key(changed)
		if err != nil {
			t.Fatal(err)
		}
		if err := Check(key, actual); err == nil {
			t.Fatalf("accepted changed captured input %d", i)
		}
	}
	for _, changed := range [][]string{parts[:len(parts)-1], append(slices.Clone(parts), "added source"), {"a", "bc"}, {"ab", "c"}} {
		actual, err := Key(changed)
		if err != nil {
			t.Fatal(err)
		}
		if err := Check(key, actual); err == nil {
			t.Fatal("accepted changed manifest shape")
		}
	}
}

func TestCachedBinaryRejectsTampering(t *testing.T) {
	path := filepath.Join(t.TempDir(), "compiler")
	if err := os.WriteFile(path, []byte("original"), 0700); err != nil {
		t.Fatal(err)
	}
	hash, err := Binary(path, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Binary(path, hash); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("tampered"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := Binary(path, hash); err == nil {
		t.Fatal("accepted changed binary")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := Binary(path, hash); err == nil {
		t.Fatal("accepted missing binary")
	}
	other := filepath.Join(t.TempDir(), "other")
	if err := os.WriteFile(other, []byte("original"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, path); err != nil {
		t.Fatal(err)
	}
	if _, err := Binary(path, hash); err == nil {
		t.Fatal("accepted symlink replacement")
	}
}

func TestKeyPreservesBytesAndBoundaries(t *testing.T) {
	seen := map[string]bool{}
	for _, parts := range [][]string{nil, {""}, {"", ""}, {"a", "bc"}, {"ab", "c"}, {"\xff"}, {"\xfe"}, {"\ufffd"}} {
		key, err := Key(parts)
		if err != nil {
			t.Fatal(err)
		}
		if seen[key] {
			t.Fatalf("distinct input bytes or boundaries collapsed: %q", parts)
		}
		seen[key] = true
	}
}
