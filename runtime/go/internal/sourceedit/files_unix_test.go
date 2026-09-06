//go:build unix

package sourceedit

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestCompilerManifestSavedGuards(t *testing.T) {
	root, _, raw := compilerManifest(t)
	m, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.VerifyDisk(); err != nil {
		t.Fatalf("producer/consumer initial guards disagree: %v", err)
	}
	app := filepath.Join(root, "app.tesl")
	original, err := os.ReadFile(app)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name   string
		change func() func()
	}{
		{"changed read-only application", func() func() {
			if err := os.WriteFile(app, append([]byte("# concurrent edit\n"), original...), 0600); err != nil {
				t.Fatal(err)
			}
			return func() { _ = os.WriteFile(app, original, 0600) }
		}},
		{"deleted input", func() func() {
			if err := os.Remove(app); err != nil {
				t.Fatal(err)
			}
			return func() { _ = os.WriteFile(app, original, 0600) }
		}},
		{"new output already exists", func() func() {
			path := m.wire.Edits[0].Path
			if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte("unexpected"), 0600); err != nil {
				t.Fatal(err)
			}
			return func() {
				_ = os.Remove(path)
				for p := filepath.Dir(path); p != root; p = filepath.Dir(p) {
					if err := os.Remove(p); err != nil {
						break
					}
				}
			}
		}},
		{"read-only directory membership", func() func() {
			path := filepath.Join(root, "unrelated")
			if err := os.WriteFile(path, []byte("new"), 0600); err != nil {
				t.Fatal(err)
			}
			return func() { _ = os.Remove(path) }
		}},
		{"source replaced by symlink", func() func() {
			destination := filepath.Join(t.TempDir(), "original")
			_ = os.WriteFile(destination, original, 0600)
			_ = os.Remove(app)
			if err := os.Symlink(destination, app); err != nil {
				t.Fatal(err)
			}
			return func() { _ = os.Remove(app); _ = os.WriteFile(app, original, 0600) }
		}},
		{"source replaced by FIFO", func() func() {
			_ = os.Remove(app)
			if err := syscall.Mkfifo(app, 0600); err != nil {
				t.Fatal(err)
			}
			return func() { _ = os.Remove(app); _ = os.WriteFile(app, original, 0600) }
		}},
		{"source replaced by directory", func() func() {
			_ = os.Remove(app)
			if err := os.Mkdir(app, 0700); err != nil {
				t.Fatal(err)
			}
			return func() { _ = os.Remove(app); _ = os.WriteFile(app, original, 0600) }
		}},
		{"parent replaced by symlink", func() func() {
			schema := filepath.Join(root, "schema")
			moved := filepath.Join(t.TempDir(), "schema")
			if err := os.Rename(schema, moved); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(moved, schema); err != nil {
				t.Fatal(err)
			}
			return func() { _ = os.Remove(schema); _ = os.Rename(moved, schema) }
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			restore := c.change()
			defer restore()
			if err := m.VerifyDisk(); err == nil {
				t.Fatal("stale/special source accepted")
			}
		})
		if err := m.VerifyDisk(); err != nil {
			t.Fatalf("restored fixture not accepted: %v", err)
		}
	}
}
func TestCompilerManifestGuardedReadDoesNotBlockOnSubstitutedFIFO(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "pipe.tesl")
	if err := syscall.Mkfifo(file, 0600); err != nil {
		t.Fatal(err)
	}
	r, err := os.OpenRoot(root)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = r.Close() }()
	// Directly exercise the open used after lstat. The FIFO must open without a
	// writer so a change between lstat and open cannot block guard verification.
	f, err := openRegular(r, "pipe.tesl")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil || info.Mode().IsRegular() {
		t.Fatal("special file was accepted as regular")
	}
}
func TestCompilerManifestRootIdentity(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "project")
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	tree, err := openTree(path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tree.root.Close() }()
	if err := os.Rename(path, path+"-moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := tree.verifyRoot(); err == nil {
		t.Fatal("new directory at the same path accepted")
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(path, alias); err != nil {
		t.Fatal(err)
	}
	if other, err := openTree(alias); err == nil {
		_ = other.root.Close()
		t.Fatal("aliased project accepted")
	}
}
func TestCompilerImportResolutionParityVectors(t *testing.T) {
	for _, v := range []struct{ name, path string }{
		{"NotesSchema.VCurrent", "schema/notes/v-current.tesl"},
		{"JSONNotesSchema.V12.PrivateTypes", "schema/j-s-o-n-notes/v12/private-types.tesl"},
		{"NotesSchema.Migrate.V2.Helpers", "migrations/notes/v2/helpers.tesl"},
		{"NotesSchema.V2147483646", "schema/notes/v2147483646.tesl"},
	} {
		got, ok := schemaRelative(v.name)
		if !ok || got != filepath.FromSlash(v.path) {
			t.Fatalf("%s -> %s", v.name, got)
		}
	}
	for _, name := range []string{"Schema.V2", "NotesSchema.V0", "NotesSchema.V01", "NotesSchema.V2147483647", "NotesSchema.V2/Other", "NotesSchema..V2", "../App", "NotesSchema.V2_0"} {
		if _, ok := schemaRelative(name); ok {
			t.Fatalf("invalid schema import accepted: %s", name)
		}
	}
	root := t.TempDir()
	nested := filepath.Join(root, "nested")
	_ = os.Mkdir(nested, 0700)
	source := filepath.Join(nested, "app.tesl")
	expected := filepath.Join(root, "schema", "notes", "v-current.tesl")
	_ = os.MkdirAll(filepath.Dir(expected), 0700)
	_ = os.WriteFile(expected, []byte("schema"), 0600)
	if got := resolveImport(source, "NotesSchema.VCurrent"); got != expected {
		t.Fatal(got)
	}
	pascal := filepath.Join(nested, "NotesSchema.VCurrent.tesl")
	_ = os.WriteFile(pascal, nil, 0600)
	if got := resolveImport(source, "NotesSchema.VCurrent"); got != pascal {
		t.Fatal(got)
	}
	lower := filepath.Join(nested, "notes-schema.-v-current.tesl")
	_ = os.WriteFile(lower, nil, 0600)
	if got := resolveImport(source, "NotesSchema.VCurrent"); got != lower {
		t.Fatal(got)
	}
	_ = os.Remove(lower)
	_ = os.Remove(pascal)
	_ = os.WriteFile(filepath.Join(nested, "tesl.toml"), nil, 0600)
	if got := resolveImport(source, "NotesSchema.VCurrent"); got != filepath.Join(nested, "schema", "notes", "v-current.tesl") {
		t.Fatalf("crossed project marker: %s", got)
	}
}
func TestCompilerManifestImportShadowWithoutInputChanges(t *testing.T) {
	root, _, raw := compilerManifest(t)
	m, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	// A new flat candidate can change resolution. Directory guards independently
	// catch new entry names; the resolver must identify the changed dependency.
	schema := filepath.Join(root, "NotesSchema.VCurrent.tesl")
	if err := os.WriteFile(schema, []byte("module NotesSchema.VCurrent exposing []\n"), 0600); err != nil {
		t.Fatal(err)
	}
	err = m.VerifyDisk()
	if err == nil || !strings.Contains(err.Error(), "import resolution changed") {
		t.Fatalf("changed resolver accepted or misclassified: %v", err)
	}
}

func TestCompilerManifestDanglingImportShadowRetainsAllOldInputs(t *testing.T) {
	root, _, raw := compilerManifest(t, func(root string) {
		app := filepath.Join(root, "app.tesl")
		source, err := os.ReadFile(app)
		if err != nil {
			t.Fatal(err)
		}
		owner := strings.Replace(string(source), "module App", "module Connection", 1)
		if err := os.WriteFile(filepath.Join(root, "Connection.tesl"), []byte(owner), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(app, []byte("module App exposing []\nimport Connection\n"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(filepath.Join(root, "elsewhere"), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(root, "elsewhere", "connection.tesl"), filepath.Join(root, "connection.tesl")); err != nil {
			t.Fatal(err)
		}
	})
	m, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.VerifyDisk(); err != nil {
		t.Fatal(err)
	}
	source, err := os.ReadFile(filepath.Join(root, "Connection.tesl"))
	if err != nil {
		t.Fatal(err)
	}
	// The previously selected input bytes and every captured directory membership
	// stay the same. Only a dangling higher-priority candidate becomes available.
	if err := os.WriteFile(filepath.Join(root, "elsewhere", "connection.tesl"), source, 0600); err != nil {
		t.Fatal(err)
	}
	tree, err := openTree(root)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tree.root.Close() }()
	for _, g := range m.wire.Inputs {
		actual, err := tree.fileHash(g.Path)
		if err != nil || !same(actual, g.DiskHash) {
			t.Fatalf("old input guard changed: %s, %v", g.Path, err)
		}
	}
	for _, g := range m.wire.Directories {
		actual, err := tree.directoryHash(g.Path)
		if err != nil || !same(actual, g.DiskHash) {
			t.Fatalf("old directory guard changed: %s, %v", g.Path, err)
		}
	}
	if err := m.VerifyDisk(); err == nil || !strings.Contains(err.Error(), "import resolution changed") {
		t.Fatalf("dangling shadow was not detected: %v", err)
	}
}
