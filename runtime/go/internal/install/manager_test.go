package install

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/toolchain"
)

type fixtureEntry struct {
	name, link string
	data       []byte
	mode       int64
	kind       byte
}

func fixtureEntries(t *testing.T, version string) []fixtureEntry {
	t.Helper()
	components := map[string]toolchain.Component{}
	entries := []fixtureEntry{}
	for _, name := range append(append([]string{}, Frontends...), "compiler", "go", "postgres", "initdb", "pg_ctl", "createdb", "psql") {
		path := "bin/" + name + binarySuffix()
		components[name] = toolchain.Component{Path: path, Version: version}
		entries = append(entries, fixtureEntry{name: path, data: []byte("native fixture " + version), mode: 0755, kind: tar.TypeReg})
	}
	for _, name := range []string{"stdlib", "templates", "doc", "go-modules", "licenses"} {
		path := "share/tesl/" + name
		components[name] = toolchain.Component{Path: path, Version: version}
		entries = append(entries, fixtureEntry{name: path, mode: 0755, kind: tar.TypeDir})
	}
	manifest := toolchain.Manifest{Version: 1, ToolchainVersion: version, SourceRevision: strings.Repeat("a", 40), Target: runtime.GOOS + "-" + runtime.GOARCH, Components: components}
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return append(entries, fixtureEntry{name: "share/tesl/toolchain.json", data: data, mode: 0644, kind: tar.TypeReg})
}

func fixtureArchive(t *testing.T, version, format string, entries []fixtureEntry) (string, string) {
	t.Helper()
	var contents bytes.Buffer
	prefix := "tesl-" + version + "-" + runtime.GOOS + "-" + runtime.GOARCH + "/"
	if format == "zip" {
		writer := zip.NewWriter(&contents)
		for _, entry := range entries {
			header := &zip.FileHeader{Name: prefix + entry.name, Method: zip.Deflate}
			mode := os.FileMode(entry.mode)
			if entry.kind == tar.TypeDir {
				mode |= os.ModeDir
				header.Name += "/"
			}
			if entry.kind == tar.TypeSymlink {
				mode |= os.ModeSymlink
			}
			header.SetMode(mode)
			file, err := writer.CreateHeader(header)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = file.Write(entry.data); err != nil {
				t.Fatal(err)
			}
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
	} else {
		compressed := gzip.NewWriter(&contents)
		writer := tar.NewWriter(compressed)
		for _, entry := range entries {
			header := &tar.Header{Name: prefix + entry.name, Typeflag: entry.kind, Mode: entry.mode, Linkname: entry.link}
			if entry.kind == tar.TypeReg {
				header.Size = int64(len(entry.data))
			}
			if err := writer.WriteHeader(header); err != nil {
				t.Fatal(err)
			}
			if entry.kind == tar.TypeReg {
				if _, err := writer.Write(entry.data); err != nil {
					t.Fatal(err)
				}
			}
		}
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		if err := compressed.Close(); err != nil {
			t.Fatal(err)
		}
	}
	name := filepath.Join(t.TempDir(), "toolchain."+format)
	if err := os.WriteFile(name, contents.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(contents.Bytes())
	return name, hex.EncodeToString(digest[:])
}

func testManager(t *testing.T) *Manager {
	t.Helper()
	launcher := filepath.Join(t.TempDir(), "tesl-install"+binarySuffix())
	if err := os.WriteFile(launcher, []byte("native installer fixture"), 0755); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(t.TempDir(), "install å with spaces")
	t.Cleanup(func() {
		if _, err := os.Stat(root); err == nil {
			_ = removeOwnedTree(root)
		}
	})
	return &Manager{Root: root, Executable: launcher}
}

func installFixture(t *testing.T, manager *Manager, version string) Result {
	t.Helper()
	archive, digest := fixtureArchive(t, version, "tar.gz", fixtureEntries(t, version))
	result, err := manager.Install(context.Background(), archive, digest)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestInstallCoexistSelectRollbackAndUninstallPreserveUserData(t *testing.T) {
	m := testManager(t)
	first := installFixture(t, m, "0.3.1")
	if first.State.Active != "0.3.1" || first.State.Generation != 1 {
		t.Fatalf("initial selection: %+v", first.State)
	}
	data := filepath.Join(m.Root, "projects", "example", ".tesl-postgres", "data", "user-table")
	if err := os.MkdirAll(filepath.Dir(data), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(data, []byte("preserved"), 0600); err != nil {
		t.Fatal(err)
	}
	second := installFixture(t, m, "0.3.2")
	if second.State.Active != "0.3.2" || second.State.Previous != "0.3.1" || len(second.Installed) != 2 {
		t.Fatalf("upgrade: %+v", second)
	}
	selected, err := m.Select("0.3.1")
	if err != nil {
		t.Fatal(err)
	}
	if selected.State.Previous != "0.3.2" {
		t.Fatalf("selection lost rollback: %+v", selected.State)
	}
	rolled, err := m.Rollback()
	if err != nil {
		t.Fatal(err)
	}
	if rolled.State.Active != "0.3.2" {
		t.Fatalf("rollback: %+v", rolled.State)
	}
	removed, err := m.Uninstall(context.Background(), "0.3.2")
	if err != nil {
		t.Fatal(err)
	}
	if removed.State.Active != "0.3.1" || removed.State.Previous != "" || len(removed.Installed) != 1 {
		t.Fatalf("uninstall active: %+v", removed)
	}
	removed, err = m.Uninstall(context.Background(), "0.3.1")
	if err != nil {
		t.Fatal(err)
	}
	if removed.State.Active != "" || len(removed.Installed) != 0 {
		t.Fatalf("uninstall final: %+v", removed)
	}
	if value, err := os.ReadFile(data); err != nil || string(value) != "preserved" {
		t.Fatalf("uninstall changed user database: %q %v", value, err)
	}
}

func TestZIPInstallAndSameVersionChecksums(t *testing.T) {
	m := testManager(t)
	archive, digest := fixtureArchive(t, "0.3.1", "zip", fixtureEntries(t, "0.3.1"))
	first, err := m.Install(context.Background(), archive, digest)
	if err != nil {
		t.Fatal(err)
	}
	second, err := m.Install(context.Background(), archive, digest)
	if err != nil {
		t.Fatal(err)
	}
	if first.State != second.State {
		t.Fatal("same archive changed selection generation")
	}
	entries := fixtureEntries(t, "0.3.1")
	entries[0].data = []byte("different archive")
	changed, other := fixtureArchive(t, "0.3.1", "zip", entries)
	if _, err := m.Install(context.Background(), changed, other); err == nil {
		t.Fatal("same version accepted different bytes")
	}
}

func TestInterruptedInstallPreservesAtomicSelectionAndCanResume(t *testing.T) {
	m := testManager(t)
	before := installFixture(t, m, "0.3.1")
	archive, digest := fixtureArchive(t, "0.3.2", "tar.gz", fixtureEntries(t, "0.3.2"))
	m.beforeCommit = func() error { return errors.New("interrupted before state commit") }
	if _, err := m.Install(context.Background(), archive, digest); err == nil {
		t.Fatal("injected interruption did not fail")
	}
	m.beforeCommit = nil
	state, err := m.List()
	if err != nil {
		t.Fatal(err)
	}
	if state.State != before.State {
		t.Fatalf("interrupted installation changed selection: %+v", state.State)
	}
	for _, pattern := range []string{".install-stage-*", ".state-*"} {
		paths, err := filepath.Glob(filepath.Join(m.Root, pattern))
		if err != nil || len(paths) != 0 {
			t.Fatalf("partial transaction survived: %v %v", paths, err)
		}
	}
	resumed, err := m.Install(context.Background(), archive, digest)
	if err != nil {
		t.Fatal(err)
	}
	if resumed.State.Active != "0.3.2" {
		t.Fatal("complete unselected version could not resume")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := m.Install(ctx, archive, digest); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation: %v", err)
	}
}

func TestUninstallRollsBackFailedStateCommitAndRefusesModifiedPayload(t *testing.T) {
	m := testManager(t)
	before := installFixture(t, m, "0.3.1")
	m.beforeCommit = func() error { return errors.New("state write interrupted") }
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err == nil {
		t.Fatal("expected interrupted uninstall")
	}
	m.beforeCommit = nil
	result, err := m.List()
	if err != nil || result.State != before.State {
		t.Fatalf("failed uninstall damaged selection: %+v %v", result, err)
	}
	root := filepath.Join(m.Root, "versions", "0.3.1")
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	userFile := filepath.Join(root, "user-notes")
	if err := os.WriteFile(userFile, []byte("important"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err == nil {
		t.Fatal("removed modified version with user files")
	}
	if _, err := os.Stat(userFile); err != nil {
		t.Fatal("lost user file")
	}
}

func TestMalformedStateAndForeignRootFailClosed(t *testing.T) {
	for _, state := range []string{`{"version":2}`, `{"version":1,"active_version":"../outside"}`, `{"version":1,"active_version":"0.3.1","previous_version":"0.3.1"}`, `{"version":1,"unexpected":true}`, `{"version":1} {}`} {
		t.Run(state, func(t *testing.T) {
			m := testManager(t)
			installFixture(t, m, "0.3.1")
			if err := os.WriteFile(filepath.Join(m.Root, "state.json"), []byte(state), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := m.Select("0.3.1"); err == nil {
				t.Fatal("accepted malformed state")
			}
		})
	}
	m := testManager(t)
	if err := os.MkdirAll(m.Root, 0700); err != nil {
		t.Fatal(err)
	}
	userFile := filepath.Join(m.Root, "user-file")
	if err := os.WriteFile(userFile, []byte("preserved"), 0600); err != nil {
		t.Fatal(err)
	}
	archive, digest := fixtureArchive(t, "0.3.1", "zip", fixtureEntries(t, "0.3.1"))
	if _, err := m.Install(context.Background(), archive, digest); err == nil {
		t.Fatal("took ownership of foreign nonempty root")
	}
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err == nil {
		t.Fatal("uninstalled from unmarked root")
	}
}

func TestArchiveRejectsUnsafeEntriesAndCorruption(t *testing.T) {
	for _, entry := range []fixtureEntry{
		{name: "../escape", kind: tar.TypeReg}, {name: "bin/../../escape", kind: tar.TypeReg}, {name: "C:/escape", kind: tar.TypeReg},
		{name: "bin\\escape", kind: tar.TypeReg}, {name: "NUL.txt", kind: tar.TypeReg}, {name: "bin/space ", kind: tar.TypeReg},
		{name: "bin/link", kind: tar.TypeSymlink, link: "../../../outside"}, {name: "bin/link", kind: tar.TypeSymlink, link: "/outside"},
		{name: "bin/link", kind: tar.TypeSymlink, link: "absent"}, {name: "bin/pipe", kind: tar.TypeFifo}, {name: receiptName, kind: tar.TypeReg},
	} {
		t.Run(fmt.Sprintf("%s-%d", entry.name, entry.kind), func(t *testing.T) {
			m := testManager(t)
			archive, digest := fixtureArchive(t, "0.3.1", "tar.gz", append(fixtureEntries(t, "0.3.1"), entry))
			if _, err := m.Install(context.Background(), archive, digest); err == nil {
				t.Fatal("unsafe entry accepted")
			}
		})
	}
	for _, kind := range []string{"duplicate", "symlink-parent-before", "symlink-parent-after", "bad-manifest", "checksum"} {
		t.Run(kind, func(t *testing.T) {
			m := testManager(t)
			entries := fixtureEntries(t, "0.3.1")
			switch kind {
			case "duplicate":
				entries = append(entries, entries[0])
			case "symlink-parent-before":
				entries = append([]fixtureEntry{{name: "other", kind: tar.TypeSymlink, link: "bin"}, {name: "other/file", kind: tar.TypeReg}}, entries...)
			case "symlink-parent-after":
				entries = append(entries, fixtureEntry{name: "other/file", kind: tar.TypeReg}, fixtureEntry{name: "other", kind: tar.TypeSymlink, link: "bin"})
			case "bad-manifest":
				entries[len(entries)-1].data = []byte(`{"version":1}`)
			}
			archive, digest := fixtureArchive(t, "0.3.1", "tar.gz", entries)
			if kind == "checksum" {
				digest = strings.Repeat("0", 64)
			}
			if _, err := m.Install(context.Background(), archive, digest); err == nil {
				t.Fatal("invalid archive accepted")
			}
		})
	}
}

func TestRelativeArchiveLinksRemainInternal(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows archive policy rejects symlinks")
	}
	m := testManager(t)
	entries := append(fixtureEntries(t, "0.3.1"), fixtureEntry{name: "lib/alias", kind: tar.TypeSymlink, link: "../bin/tesl"})
	archive, digest := fixtureArchive(t, "0.3.1", "tar.gz", entries)
	if _, err := m.Install(context.Background(), archive, digest); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Uninstall(context.Background(), "0.3.1"); err != nil {
		t.Fatal(err)
	}
}
