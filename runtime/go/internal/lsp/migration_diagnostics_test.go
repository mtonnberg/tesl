package lsp

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

type richFakeCompiler struct{ *fakeCompiler }

func (*richFakeCompiler) DiagnosticQueryVersion() int { return 2 }

func TestRichDiagnosticsUseRelatedBuffersAndRetainGuidance(t *testing.T) {
	root := t.TempDir()
	entry, old := filepath.Join(root, "app.tesl"), filepath.Join(root, "old.tesl")
	if err := os.WriteFile(old, []byte("disk"), 0600); err != nil {
		t.Fatal(err)
	}
	d := map[string]any{"file": entry, "start": map[string]int{"line": 0, "col": 0}, "end": map[string]int{"line": 0, "col": 1},
		"code": "MIG003", "severity": "error", "source": "migration", "message": "choose a migration", "fix": nil,
		"actionClass": "decision", "needsConfirmation": true, "fixAllEligible": false, "command": nil,
		"codeDescription":    map[string]string{"href": "https://github.com/mtonnberg/tesl/blob/main/manual/best-practices.md#database-access"},
		"relatedInformation": []any{map[string]any{"file": old, "message": "previous field", "start": map[string]int{"line": 0, "col": 5}, "end": map[string]int{"line": 0, "col": 6}}}}
	payload, err := json.Marshal(map[string]any{"version": 2, "diagnostics": []any{d}})
	if err != nil {
		t.Fatal(err)
	}
	compiler := &richFakeCompiler{&fakeCompiler{payload: payload}}
	server := NewServer(compiler)
	doc := document{URI: protocol.PathToURI(entry), Path: entry, Text: "x", Version: 2}
	groups, err := server.diagnosticsForDocumentWithOverlays(context.Background(), doc, []tooling.SourceOverlay{{Path: old, Source: "🌱 x"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(compiler.flags) != 1 || compiler.flags[0] != "--check-json-v2" {
		t.Fatalf("did not use rich endpoint: %v", compiler.flags)
	}
	encoded, err := json.Marshal(groups[doc.URI])
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"actionClass":"decision"`, `"needsConfirmation":true`, `"fixAllEligible":false`, `"character":3`, `"character":4`, `"codeDescription"`, protocol.PathToURI(old)} {
		if !bytes.Contains(encoded, []byte(want)) {
			t.Fatalf("missing %s: %s", want, encoded)
		}
	}
	if after, err := os.ReadFile(old); err != nil || string(after) != "disk" {
		t.Fatal("diagnostics saved an unsaved related buffer")
	}
}

func TestMissingDiagnosticOriginsRemainLinkable(t *testing.T) {
	entry, missing := filepath.Join(t.TempDir(), "app.tesl"), filepath.Join(t.TempDir(), "missing.tesl")
	doc := document{URI: protocol.PathToURI(entry), Path: entry, Text: "x"}
	uri, span, err := diagnosticLocation(doc, nil, missing, sourcePosition{}, sourcePosition{})
	if err != nil || uri != protocol.PathToURI(missing) || span["start"] != (protocol.Position{}) || span["end"] != (protocol.Position{}) {
		t.Fatalf("missing origin: %s %+v %v", uri, span, err)
	}
	if _, _, err := diagnosticLocation(doc, nil, missing, sourcePosition{}, sourcePosition{Col: 1}); err == nil {
		t.Fatal("invented a range in an absent document")
	}
}

func TestDecisionDiagnosticsNeverBecomeOrdinaryQuickFixes(t *testing.T) {
	uri := testFileURI("decision.tesl")
	server := NewServer(&fakeCompiler{})
	server.documents[uri] = document{URI: uri, Path: testFilePath("decision.tesl"), Text: "x"}
	for _, test := range []struct {
		class        string
		confirmation bool
		count        int
	}{{"decision", true, 0}, {"decision", false, 0}, {"suggested", true, 0}, {"suggested", false, 1}, {"mechanical", false, 1}} {
		params, err := json.Marshal(map[string]any{"textDocument": map[string]string{"uri": uri}, "context": map[string]any{"diagnostics": []any{
			map[string]any{"code": "MIG003", "data": map[string]any{"actionClass": test.class, "needsConfirmation": test.confirmation,
				"fix": map[string]any{"kind": "replace_line", "line": 0, "replacement": "fixed"}}}}}})
		if err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		if err := server.writeCodeActions(json.RawMessage(`1`), params, protocol.NewWriter(&output)); err != nil {
			t.Fatal(err)
		}
		message, err := protocol.NewReader(&output).Read()
		if err != nil {
			t.Fatal(err)
		}
		var response struct{ Result []json.RawMessage }
		if err := json.Unmarshal(message, &response); err != nil || len(response.Result) != test.count {
			t.Fatalf("%+v: %s %v", test, message, err)
		}
	}
}

func TestFrozenSourceDiagnosticsThroughRealCompilerAndRetainedLSP(t *testing.T) {
	repo := os.Getenv("TESL_REPO_ROOT")
	if repo == "" {
		t.Skip("requires TESL_REPO_ROOT and built compiler")
	}
	compiler := filepath.Join(repo, "compiler/_build/default/bin/main.exe")
	project := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	write := func(path, source string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
	}
	entry := filepath.Join(project, "app.tesl")
	write(filepath.Join(project, "tesl.toml"), "")
	write(filepath.Join(project, "schema/notes/v-current.tesl"), "module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n")
	write(entry, "module App exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport NotesSchema.VCurrent\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }\n")
	run := func(args ...string) []byte {
		t.Helper()
		command := exec.CommandContext(ctx, compiler, args...)
		command.Dir, command.Env = project, os.Environ()
		output, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("compiler %v: %v\n%s", args, err, output)
		}
		return output
	}
	run("agent-context", entry)
	var preview struct {
		OK       bool
		Manifest struct {
			Edits []struct{ Path, AfterHex string }
		}
	}
	output := run("migrate", "generate", entry, "--manifest-json", "--project-root", project)
	if err := json.Unmarshal(output, &preview); err != nil || !preview.OK || len(preview.Manifest.Edits) == 0 {
		t.Fatalf("source fixture preview: %s %v", output, err)
	}
	for _, edit := range preview.Manifest.Edits {
		relative, err := filepath.Rel(project, edit.Path)
		if err != nil || strings.HasPrefix(relative, "..") || filepath.IsAbs(relative) {
			t.Fatal("fixture preview escaped its project")
		}
		contents, err := hex.DecodeString(edit.AfterHex)
		if err != nil {
			t.Fatal(err)
		}
		write(edit.Path, string(contents))
	}
	for _, edit := range preview.Manifest.Edits {
		run("agent-context", edit.Path)
	}
	run("agent-context", entry)
	frozen := filepath.Join(project, "schema/notes/v1.tesl")
	original, err := os.ReadFile(frozen)
	if err != nil {
		t.Fatal(err)
	}
	client := tooling.Client{Executable: compiler, Environment: os.Environ(), Sessions: tooling.NewWorkspaceSessions()}
	t.Cleanup(func() {
		if err := client.Sessions.Close(); err != nil {
			t.Error(err)
		}
	})
	server := NewServer(client)
	application, err := os.ReadFile(entry)
	if err != nil {
		t.Fatal(err)
	}
	appDoc := document{URI: protocol.PathToURI(entry), Path: entry, Text: string(application), Version: 1}
	server.documents[appDoc.URI] = appDoc
	doc := document{URI: protocol.PathToURI(frozen), Path: frozen, Text: string(original), Version: 1}
	for _, changed := range []bool{false, true, false, true} {
		doc.Version++
		doc.Text = string(original)
		if changed {
			doc.Text += "# unsaved frozen edit\n"
		}
		server.documents[doc.URI] = doc
		groups, err := server.diagnosticsForDocument(ctx, doc)
		if err != nil {
			t.Fatal(err)
		}
		encoded, err := json.Marshal(groups)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(encoded, []byte("MIG013")) != changed {
			t.Fatalf("stale source-integrity judgment after changed=%t: %s", changed, encoded)
		}
		if changed {
			for _, want := range []string{`"needsConfirmation":true`, `"actionClass":"decision"`, `"relatedInformation":[{"location":`, "/migrations/notes/v2.tesl"} {
				if !bytes.Contains(encoded, []byte(want)) {
					t.Fatalf("real migration metadata lacks %s: %s", want, encoded)
				}
			}

		}
		if bytes.Contains(encoded, []byte("tesl-workspace-")) || bytes.Contains(encoded, []byte("tesl-overlay-")) {
			t.Fatalf("private compiler mirror leaked: %s", encoded)
		}
		groups, err = server.diagnosticsForDocument(ctx, appDoc)
		if err != nil {
			t.Fatal(err)
		}
		encoded, err = json.Marshal(groups)
		if err != nil || bytes.Contains(encoded, []byte("MIG013")) != changed {
			t.Fatalf("unchanged importer retained stale implicit-history diagnostics: %s %v", encoded, err)
		}
	}
	if saved, err := os.ReadFile(frozen); err != nil || !bytes.Equal(saved, original) {
		t.Fatal("diagnostics changed frozen source")
	}
	t.Run("safe current-import correction and idempotence", func(t *testing.T) {
		// Restore the frozen buffer, then make only the application buffer stale.
		// The compiler must judge those exact bytes, without saving either file.
		doc.Text, doc.Version = string(original), doc.Version+1
		server.documents[doc.URI] = doc
		appDoc.Text = strings.ReplaceAll(string(application), "NotesSchema.VCurrent", "NotesSchema.V1")
		appDoc.Version = 27
		server.documents[appDoc.URI] = appDoc
		server.documentChanges = true
		actions := fixAllTestRequest(t, server, appDoc, []string{"source.fixAll.tesl"})
		if len(actions) != 1 || len(actions[0].Edit.DocumentChanges) != 1 {
			t.Fatalf("real MIG015 did not produce a single guarded fix-all: %+v", actions)
		}
		change := actions[0].Edit.DocumentChanges[0]
		if change.TextDocument.Version != 27 || change.TextDocument.URI != appDoc.URI || len(change.Edits) != 2 {
			t.Fatalf("MIG015 lost its version or qualified-use correction: %+v", change)
		}
		index := protocol.NewLineIndex(appDoc.Text)
		for i := len(change.Edits) - 1; i >= 0; i-- {
			edit := change.Edits[i]
			start, err := index.Offset(edit.Range.Start)
			if err != nil {
				t.Fatal(err)
			}
			end, err := index.Offset(edit.Range.End)
			if err != nil {
				t.Fatal(err)
			}
			appDoc.Text = appDoc.Text[:start] + edit.NewText + appDoc.Text[end:]
		}
		if appDoc.Text != string(application) {
			t.Fatalf("fix-all changed unrelated application source: %s", appDoc.Text)
		}
		appDoc.Version++
		server.documents[appDoc.URI] = appDoc
		if next := fixAllTestRequest(t, server, appDoc, []string{"source.fixAll.tesl"}); len(next) != 0 {
			t.Fatalf("fix-all is not idempotent on the corrected buffer: %+v", next)
		}
		if disk, err := os.ReadFile(entry); err != nil || !bytes.Equal(disk, application) {
			t.Fatal("fix-all preview saved an editor buffer")
		}
		run("agent-context", entry)
	})
	t.Run("compiler-backed editor preview and file diffs", func(t *testing.T) {
		previous := filepath.Join(project, "migrations/notes/v2.tesl")
		before, err := os.ReadFile(previous)
		if err != nil {
			t.Fatal(err)
		}
		previousDoc := document{URI: protocol.PathToURI(previous), Path: previous, Version: 15,
			Text: string(before) + "\n# Unsaved migration review note\n"}
		server.documents[previousDoc.URI] = previousDoc
		defer delete(server.documents, previousDoc.URI)
		checked, _, err := client.QuerySourcesJSON(ctx, "--agent-context-json", entry, server.sourceOverlays())
		var contextResult struct {
			OK bool `json:"ok"`
		}
		if err != nil || json.Unmarshal(checked, &contextResult) != nil || !contextResult.OK {
			t.Fatalf("unsaved migration fixture failed agent-context: %s %v", checked, err)
		}
		raw := migrationEditorCommand(t, server, "tesl.generateMigration", map[string]any{
			"entryFile": entry, "projectRoot": project, "database": "App.Main", "newRevision": true}, 0)
		var preview struct {
			OK         bool
			PreviewID  string `json:"previewId"`
			Compilable bool
			Files      []struct{ Path string }
		}
		if err := json.Unmarshal(raw, &preview); err != nil || !preview.OK || !preview.Compilable {
			t.Fatalf("real LSP preview: %s %v", raw, err)
		}
		plan, err := server.prepareMigrationEdits(server.migrationPreview)
		if err != nil || plan == nil || len(plan.open) != 1 || len(plan.closed) == 0 || plan.open[0].before.Path != previous {
			t.Fatalf("real preview did not produce a mixed document plan: %+v %v", plan, err)
		}
		forward, err := plan.open[0].forward(previousDoc)
		if err != nil {
			t.Fatal(err)
		}
		changed := previousDoc
		changed.Text = applyMigrationTestEdit(t, previousDoc.Text, forward)
		changed.Version += 3
		if !strings.Contains(changed.Text, "Unsaved migration review note") {
			t.Fatal("compiler freeze discarded unsaved migration source")
		}
		inverse, err := plan.open[0].inverse(changed)
		if err != nil || applyMigrationTestEdit(t, changed.Text, inverse) != previousDoc.Text {
			t.Fatalf("real compiler edit could not restore its exact open preimage: %v", err)
		}
		if server.documents[appDoc.URI].Text != string(application) {
			t.Fatal("migration planning changed application source")
		}
		migration := filepath.Join(project, "migrations/notes/v3.tesl")
		found := false
		for _, file := range preview.Files {
			if file.Path == migration {
				found = true
			}
		}
		if !found {
			t.Fatalf("new revision missing from editor preview: %s", raw)
		}
		contents := migrationEditorCommand(t, server, "tesl.migrationPreviewFile", map[string]string{"previewId": preview.PreviewID, "path": migration}, 0)
		var change struct{ Before, After string }
		if err := json.Unmarshal(contents, &change); err != nil || change.Before != "" || !strings.Contains(change.After, "NotesSchema.Migrate.V3") {
			t.Fatalf("real generated file diff: %s %v", contents, err)
		}
		if _, err := os.Stat(migration); !os.IsNotExist(err) {
			t.Fatal("editor preview created the new revision")
		}
		if after, err := os.ReadFile(previous); err != nil || !bytes.Equal(before, after) {
			t.Fatal("editor preview froze the previous migration on disk")
		}
	})
}
