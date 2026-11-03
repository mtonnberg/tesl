package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

// Exercise the actual formatter query through the production compiler client,
// including an unsaved sibling which is not a language import of this helper.
func TestMigrationFormattingObservesUnsavedOwnershipThroughLSP(t *testing.T) {
	repo := os.Getenv("TESL_REPO_ROOT")
	if repo == "" {
		t.Skip("requires TESL_REPO_ROOT and built compiler")
	}
	compiler := filepath.Join(repo, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Fatal(err)
	}
	project := t.TempDir()
	if err := os.WriteFile(filepath.Join(project, "tesl.toml"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	path := func(name string) string { return filepath.Join(project, filepath.FromSlash(name)) }
	write := func(name, contents string) {
		t.Helper()
		file := path(name)
		if err := os.MkdirAll(filepath.Dir(file), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}
	const original = "module NotesSchema.Migrate.V2.Private exposing []\n\nfn value()->Int=42\n\n"
	write("migrations/notes/v2/private.tesl", original)
	write("migrations/notes/v2.tesl", "module NotesSchema.Migrate.V2 exposing []\n")
	client := tooling.Client{Executable: compiler, Environment: os.Environ(), Sessions: tooling.NewWorkspaceSessions()}
	t.Cleanup(func() {
		if err := client.Sessions.Close(); err != nil {
			t.Error(err)
		}
	})
	server := NewServer(client)
	helper := path("migrations/notes/v2/private.tesl")
	uri := protocol.PathToURI(helper)
	server.documents[uri] = document{URI: uri, Path: helper, Version: 1, Text: original}
	format := func() []json.RawMessage {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		params, err := json.Marshal(map[string]any{"textDocument": map[string]any{"uri": uri}})
		if err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		if err = server.writeFormatting(ctx, json.RawMessage("1"), params, protocol.NewWriter(&output)); err != nil {
			t.Fatal(err)
		}
		message, err := protocol.NewReader(&output).Read()
		if err != nil {
			t.Fatal(err)
		}
		var response struct {
			Result []json.RawMessage
			Error  json.RawMessage
		}
		if err = json.Unmarshal(message, &response); err != nil || len(response.Error) != 0 {
			t.Fatalf("format response: %s %v", message, err)
		}
		return response.Result
	}
	if edits := format(); len(edits) != 1 {
		t.Fatalf("current helper should format: %s", edits)
	}
	snapshot := path("schema/notes/v2.tesl")
	snapshotURI := protocol.PathToURI(snapshot)
	server.documents[snapshotURI] = document{URI: snapshotURI, Path: snapshot, Version: 1, Text: "module NotesSchema.V2 exposing []\n"}
	if edits := format(); len(edits) != 0 {
		t.Fatalf("unsaved frozen snapshot did not protect helper: %s", edits)
	}
	delete(server.documents, snapshotURI)
	root := path("migrations/notes/v2.tesl")
	rootURI := protocol.PathToURI(root)
	server.documents[rootURI] = document{URI: rootURI, Path: root, Version: 2,
		Text: "# tesl:frozen-migration:v1 NotesSchema.Migrate.V2\nmodule NotesSchema.Migrate.V2 exposing []\n"}
	if edits := format(); len(edits) != 0 {
		t.Fatalf("unsaved closure did not protect helper: %s", edits)
	}
	delete(server.documents, rootURI)
	if edits := format(); len(edits) != 1 {
		t.Fatalf("discarded overlay kept stale read-only state: %s", edits)
	}
	write("schema/notes/v2.tesl", "module NotesSchema.V2 exposing []\n")
	if edits := format(); len(edits) != 0 {
		t.Fatalf("saved frozen snapshot did not protect helper: %s", edits)
	}
	if actual, err := os.ReadFile(helper); err != nil || string(actual) != original {
		t.Fatal("formatting wrote the workspace helper")
	}
	if actual, err := os.ReadFile(root); err != nil || string(actual) != "module NotesSchema.Migrate.V2 exposing []\n" {
		t.Fatal("formatting saved another open buffer")
	}
}
