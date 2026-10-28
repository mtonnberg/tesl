package compilerfixture

import (
	"os"
	"path/filepath"
	"testing"
)

func TestManifestTracksCapturedFilesAndExactDocumentation(t *testing.T) {
	root := t.TempDir()
	files := []string{"compiler/lib/nested/source.ml", "compiler/bin/dune", "compiler/gen/gen.ml", "runtime/go/teslrt/runtime.go", "compiler/dune-project", "LANGUAGE-SPEC.md", "README.md", "INSTALL.md", "manual/page.md", "example/program.tesl", "example/learn/lesson.tesl", "dev-docs/design.md"}
	write := func(name, text string) {
		t.Helper()
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range files {
		write(name, "original")
	}
	before, err := Manifest(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range files {
		write(name, "modified")
		after, err := Manifest(root)
		if err != nil {
			t.Fatal(err)
		}
		if err := Check(before, after); err == nil {
			t.Fatalf("missed source/document mutation: %s", name)
		}
		write(name, "original")
	}
	write("manual/ignored.txt", "not copied")
	write("example/unselected/deep.tesl", "not copied")
	after, err := Manifest(root)
	if err != nil || before != after {
		t.Fatalf("manifest disagrees with documentation selection: %v", err)
	}
	write("compiler/lib/untracked.ml", "new input")
	after, err = Manifest(root)
	if err != nil || before == after {
		t.Fatalf("missed added untracked input: %v", err)
	}
	if err := os.Remove(filepath.Join(root, "compiler/lib/untracked.ml")); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(root, files[0]), filepath.Join(root, "compiler/lib/renamed.ml")); err != nil {
		t.Fatal(err)
	}
	after, err = Manifest(root)
	if err != nil || before == after {
		t.Fatalf("missed renamed input with identical bytes: %v", err)
	}
	if err := os.Symlink(filepath.Join(root, "README.md"), filepath.Join(root, "compiler/lib/link.ml")); err != nil {
		t.Fatal(err)
	}
	if _, err := Manifest(root); err == nil {
		t.Fatal("accepted special input")
	}
}
