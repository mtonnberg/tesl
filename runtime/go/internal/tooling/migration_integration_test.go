package tooling

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBuiltCompilerMigrationPreviewPreservesOpenBuffers(t *testing.T) {
	repo := os.Getenv("TESL_REPO_ROOT")
	if repo == "" {
		t.Skip("requires TESL_REPO_ROOT and the built compiler")
	}
	root := filepath.Join(t.TempDir(), "preview 'å $ project")
	if err := os.MkdirAll(filepath.Join(root, "schema/notes"), 0700); err != nil {
		t.Fatal(err)
	}
	entry, schema, virtual := filepath.Join(root, "app.tesl"), filepath.Join(root, "schema/notes/v-current.tesl"), filepath.Join(root, "unused.tesl")
	application := "module App exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport NotesSchema.VCurrent\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }\n"
	schemaSource := "module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n"
	client := Client{Executable: filepath.Join(repo, "compiler/_build/default/bin/main.exe"), Environment: os.Environ()}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for _, file := range []struct{ path, source string }{{filepath.Join(root, "tesl.toml"), ""}, {schema, schemaSource}, {entry, application}} {
		path, source := file.path, file.source
		if err := os.WriteFile(path, []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
		if strings.HasSuffix(path, ".tesl") {
			if result, err := client.Run(ctx, "agent-context", path); err != nil {
				t.Fatalf("fixture judgment: %v\n%s", err, result.Stdout)
			}
		}
	}
	documents := []MigrationDocument{
		{Path: virtual, Version: 0, Source: "module Unused exposing []\n"},
		{Path: schema, Version: -4, Source: schemaSource + "# unsaved schema bytes must be frozen\n"},
		{Path: entry, Version: 17, Source: application + "# unsaved application\n"},
	}
	selection := MigrationSelection{EntryFile: entry, ProjectRoot: root, Database: "Main", NewRevision: true}
	preview, result, err := client.QueryMigrationPreview(ctx, selection, documents)
	if err != nil {
		t.Fatalf("real compiler preview: %v\n%s\n%s", err, result.Stdout, result.Stderr)
	}
	if !preview.Compilable() || preview.Database() != "App.Main" || preview.EntryFile() != entry {
		t.Fatal("lost actual compiler judgment or selection")
	}
	versions := preview.Manifest().DocumentVersions()
	if len(versions) != 3 || versions[entry] != 17 || versions[schema] != -4 || versions[virtual] != 0 {
		t.Fatalf("lost source versions: %+v", versions)
	}
	var manifest struct {
		Edits []struct{ Path, AfterHex string }
	}
	if err := json.Unmarshal(preview.Manifest().JSON(), &manifest); err != nil {
		t.Fatal(err)
	}
	frozen := false
	for _, edit := range manifest.Edits {
		if edit.Path == filepath.Join(root, "schema/notes/v1.tesl") {
			contents, err := hex.DecodeString(edit.AfterHex)
			if err != nil || !bytes.Contains(contents, []byte("unsaved schema bytes must be frozen")) {
				t.Fatalf("compiler froze saved bytes instead of the open buffer: %v", err)
			}
			frozen = true
		}
	}
	if !frozen || bytes.Contains(result.Stdout, []byte("tesl-migration-overlays-")) || bytes.Contains(result.Stdout, []byte("tesl-overlay-")) {
		t.Fatal("preview lost the frozen source or exposed private transport paths")
	}
	again, _, err := client.QueryMigrationPreview(ctx, selection, documents)
	if err != nil || !bytes.Equal(preview.JSON(), again.JSON()) {
		t.Fatalf("identical buffers changed the manifest: %v", err)
	}
	savedOnly, _, err := client.QueryMigrationPreview(ctx, selection, nil)
	if err != nil || len(savedOnly.Manifest().DocumentVersions()) != 0 || bytes.Equal(preview.JSON(), savedOnly.JSON()) {
		t.Fatalf("saved-source preview reused the open-buffer view: %v", err)
	}
	for path, want := range map[string]string{entry: application, schema: schemaSource} {
		if data, err := os.ReadFile(path); err != nil || string(data) != want {
			t.Fatalf("preview saved %s: %v", path, err)
		}
	}
	for _, path := range []string{virtual, filepath.Join(root, "schema/notes/v1.tesl"), filepath.Join(root, "migrations")} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("preview created source: %s, %v", path, err)
		}
	}
	// Selection errors retain compiler diagnostics, but expose no applicable
	// manifest and do not silently choose the first of two application databases.
	documents[2].Source = application + "database Other = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }\n"
	selection.Database = ""
	failed, result, err := client.QueryMigrationPreview(ctx, selection, documents)
	if err == nil || failed != nil || result.ExitCode != 1 || !bytes.Contains(result.Stdout, []byte("App.Other")) || !bytes.Contains(result.Stdout, []byte("\"manifest\":null")) {
		t.Fatalf("ambiguous target did not preserve refusal diagnostics: %v\n%s", err, result.Stdout)
	}
}
