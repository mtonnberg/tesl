package sourceedit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// historyFixture lays out one family: frozen sources, a nested private module,
// two checkpoints and the current revision's files, which keep their own guards.
func historyFixture(t *testing.T) (string, *Manifest) {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{
		"schema/s/v-current.tesl":    "cur",
		"schema/s/v1.tesl":           "one",
		"schema/s/sub/x.tesl":        "x",
		"migrations/s/v2.tesl":       "m2",
		"migrations/s/v1.checkpoint": "c1",
		"migrations/s/v2.checkpoint": "c2",
		"migrations/s/v3.tesl":       "m3",
	}
	for name, contents := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	m := historyManifest(t, root)
	return root, m
}

func historyManifest(t *testing.T, root string) *Manifest {
	t.Helper()
	tr, err := openTree(root)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tr.root.Close() }()
	w := wireManifest{Version: 2, ProjectRoot: root}
	for _, name := range []string{"migrations/s/v3.tesl", "schema/s/v-current.tesl"} {
		path := filepath.Join(root, name)
		digest, err := tr.fileHash(path)
		if err != nil {
			t.Fatal(err)
		}
		w.Inputs = append(w.Inputs, input{Path: path, SourceHash: digest, DiskHash: digest})
	}
	for _, name := range []string{"", "migrations", "migrations/s", "schema", "schema/s"} {
		path := filepath.Join(root, name)
		digest, err := tr.directoryHash(path)
		if err != nil {
			t.Fatal(err)
		}
		w.Directories = append(w.Directories, directory{Path: path, SourceHash: digest, DiskHash: digest})
	}
	h := historyGuard{Trees: []string{filepath.Join(root, "migrations/s"), filepath.Join(root, "schema/s")},
		Excluded: []string{filepath.Join(root, "migrations/s/v3.tesl"), filepath.Join(root, "schema/s/v-current.tesl")}}
	digest, err := tr.historyHash(h, nil)
	if err != nil {
		t.Fatal(err)
	}
	h.SourceHash, h.DiskHash = digest, digest
	w.History = []historyGuard{h}
	m, err := Decode(encode(w))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// The digest is a cross-implementation format: the compiler's test
// (test_migration_manifest.ml) asserts the same value for the same layout,
// and both were derived independently from the documented byte format.
func TestFrozenHistoryDigestVector(t *testing.T) {
	_, m := historyFixture(t)
	const expected = "a55a135c5d39d75aeb9fa491a9186a5af7d26ed8c7017ecaeedc06d8a73ae733"
	if got := m.wire.History[0].DiskHash; got != expected {
		t.Fatalf("frozen history digest %s, want %s", got, expected)
	}
	if err := m.VerifyDisk(); err != nil {
		t.Fatal(err)
	}
}

func TestFrozenHistoryRefusesFrozenByteChanges(t *testing.T) {
	cases := []struct {
		name   string
		change func(root string) error
	}{
		{"edited frozen source", func(root string) error {
			return os.WriteFile(filepath.Join(root, "schema/s/v1.tesl"), []byte("ONE"), 0o600)
		}},
		{"edited nested module", func(root string) error {
			return os.WriteFile(filepath.Join(root, "schema/s/sub/x.tesl"), []byte("y"), 0o600)
		}},
		{"added file", func(root string) error {
			return os.WriteFile(filepath.Join(root, "schema/s/sub/y.tesl"), nil, 0o600)
		}},
		{"removed file", func(root string) error { return os.Remove(filepath.Join(root, "migrations/s/v2.tesl")) }},
		{"added directory", func(root string) error { return os.Mkdir(filepath.Join(root, "schema/s/v1"), 0o700) }},
		{"edited newest checkpoint", func(root string) error {
			return os.WriteFile(filepath.Join(root, "migrations/s/v2.checkpoint"), []byte("C2"), 0o600)
		}},
		{"removed older checkpoint", func(root string) error { return os.Remove(filepath.Join(root, "migrations/s/v1.checkpoint")) }},
		{"symbolic link", func(root string) error {
			return os.Symlink("v1.tesl", filepath.Join(root, "schema/s/alias.tesl"))
		}},
		{"replaced tree", func(root string) error {
			if err := os.Rename(filepath.Join(root, "schema/s"), filepath.Join(root, "schema/t")); err != nil {
				return err
			}
			return os.Symlink("t", filepath.Join(root, "schema/s"))
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root, m := historyFixture(t)
			if err := c.change(root); err != nil {
				t.Fatal(err)
			}
			if err := m.VerifyDisk(); err == nil {
				t.Fatal("accepted a changed frozen history")
			}
		})
	}
}

// Excluded paths carry their own guards; an older checkpoint's bytes are sealed
// in its frozen migration root and are not part of the digest.
func TestFrozenHistoryDigestScope(t *testing.T) {
	root, m := historyFixture(t)
	if err := os.WriteFile(filepath.Join(root, "migrations/s/v1.checkpoint"), []byte("older"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := m.VerifyDisk(); err != nil {
		t.Fatalf("older checkpoint bytes changed the digest: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "migrations/s/v3.tesl"), []byte("M3"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := m.VerifyDisk(); err == nil || !strings.Contains(err.Error(), "saved source changed") {
		t.Fatalf("excluded current source lost its own guard: %v", err)
	}
}

func TestFrozenHistoryAbsentTreeVector(t *testing.T) {
	root := t.TempDir()
	tr, err := openTree(root)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tr.root.Close() }()
	digest, err := tr.historyHash(historyGuard{Trees: []string{filepath.Join(root, "migrations/s")}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if digest != "3a92f4f81a6c67ea2e18294bbf3c6cfc2ab8b21cebfa01b1073e9a0b6f6c9484" {
		t.Fatalf("absent tree digest %s", digest)
	}
}

func TestFrozenHistoryRejectsInconsistentScopes(t *testing.T) {
	root, m := historyFixture(t)
	cases := []struct {
		name   string
		change func(*wireManifest)
	}{
		{"unexcluded input", func(w *wireManifest) { w.History[0].Excluded = w.History[0].Excluded[1:] }},
		{"unguarded exclusion", func(w *wireManifest) {
			w.History[0].Excluded = append([]string{filepath.Join(root, "migrations/s/v1.checkpoint")}, w.History[0].Excluded...)
		}},
		{"unguarded tree", func(w *wireManifest) { w.History[0].Trees = append(w.History[0].Trees, filepath.Join(root, "x")) }},
		{"nested trees", func(w *wireManifest) {
			w.History = append(w.History, historyGuard{Trees: []string{filepath.Join(root, "schema/s/sub")}, SourceHash: w.History[0].SourceHash, DiskHash: w.History[0].DiskHash})
		}},
		{"unsorted trees", func(w *wireManifest) {
			trees := w.History[0].Trees
			w.History[0].Trees = []string{trees[1], trees[0]}
		}},
		{"invalid digest", func(w *wireManifest) { w.History[0].DiskHash = "bad" }},
		{"no trees", func(w *wireManifest) { w.History[0].Trees = nil }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := m.wire
			w.History = []historyGuard{{Trees: append([]string{}, m.wire.History[0].Trees...),
				Excluded: append([]string{}, m.wire.History[0].Excluded...), SourceHash: m.wire.History[0].SourceHash, DiskHash: m.wire.History[0].DiskHash}}
			c.change(&w)
			if _, err := Decode(encode(w)); err == nil {
				t.Fatal("accepted an inconsistent history scope")
			}
		})
	}
	if _, err := Decode([]byte(strings.Replace(string(m.JSON()), `"excluded":[`, `"excluded":null,"x":[`, 1))); err == nil {
		t.Fatal("accepted a malformed history object")
	}
}

func TestFrozenHistoryRequiresSavedView(t *testing.T) {
	_, m := historyFixture(t)
	w := m.wire
	w.History = []historyGuard{m.wire.History[0]}
	w.History[0].SourceHash = strings.Repeat("0", 64)
	changed, err := Decode(encode(w))
	if err != nil {
		t.Fatal(err)
	}
	if changed.requireSaved() == nil || changed.requireEditor() == nil {
		t.Fatal("a differing source view of the frozen history was accepted for application")
	}
}
