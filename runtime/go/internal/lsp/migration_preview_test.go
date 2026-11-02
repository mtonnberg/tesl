package lsp

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/sourceedit"
	"tesl.dev/runtime/go/internal/tooling"
)

type migrationPreviewCompiler struct {
	*fakeCompiler
	preview   *sourceedit.Preview
	failure   error
	output    []byte
	selection tooling.MigrationSelection
	documents []tooling.MigrationDocument
	calls     int
}

func (compiler *migrationPreviewCompiler) QueryMigrationPreview(_ context.Context, selection tooling.MigrationSelection, documents []tooling.MigrationDocument) (*sourceedit.Preview, tooling.Result, error) {
	compiler.selection, compiler.documents = selection, documents
	compiler.calls++
	return compiler.preview, tooling.Result{Stdout: compiler.output}, compiler.failure
}

func migrationEditorFixture(t *testing.T) (*Server, document, string, *migrationPreviewCompiler) {
	t.Helper()
	return migrationEditorSourceFixture(t, "old", "new")
}

func migrationEditorSourceFixture(t *testing.T, before, after string) (*Server, document, string, *migrationPreviewCompiler) {
	t.Helper()
	root := t.TempDir()
	entry, created := filepath.Join(root, "app.tesl"), filepath.Join(root, "new.tesl")
	digest := sha256.Sum256([]byte(before))
	hash := hex.EncodeToString(digest[:])
	manifest := map[string]any{"version": 1, "projectRoot": root, "documents": []any{map[string]any{"path": entry, "version": 19}}, "imports": []any{},
		"inputs":      []any{map[string]any{"path": entry, "sourceHash": hash, "diskHash": hash}, map[string]any{"path": created, "sourceHash": nil, "diskHash": nil}},
		"directories": []any{map[string]any{"path": root, "sourceHash": hash, "diskHash": hash}},
		"edits": []any{map[string]any{"path": entry, "beforeHex": hex.EncodeToString([]byte(before)), "afterHex": hex.EncodeToString([]byte(after)), "documentVersion": 19},
			map[string]any{"path": created, "beforeHex": nil, "afterHex": hex.EncodeToString([]byte("🌱 new file\n")), "documentVersion": nil}}}
	raw, err := json.Marshal(map[string]any{"version": 1, "kind": "migration-source-preview", "ok": true, "operation": "refresh",
		"compilerAbi": "tesl-source-abi-v1:" + strings.Repeat("a", 64), "compilable": false,
		"selection":   map[string]any{"entryFile": entry, "databaseFile": entry, "database": "App.Main", "family": "NotesSchema", "schemaRoot": "NotesSchema.VCurrent", "previousVersion": 1, "revisionBefore": 2, "revisionAfter": 2},
		"diagnostics": map[string]any{"version": 1, "diagnostics": []any{map[string]any{"severity": "error", "code": "MIG003", "message": "choose a transform"}}}, "manifest": manifest})
	if err != nil {
		t.Fatal(err)
	}
	preview, err := sourceedit.DecodePreview(raw)
	if err != nil {
		t.Fatal(err)
	}
	compiler := &migrationPreviewCompiler{fakeCompiler: &fakeCompiler{}, preview: preview}
	server := NewServer(compiler)
	doc := document{URI: protocol.PathToURI(entry), Path: entry, Version: 19, Text: before}
	server.documents[doc.URI] = doc
	return server, doc, created, compiler
}

func migrationEditorCommand(t *testing.T, server *Server, command string, argument any, code int) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"command": command, "arguments": []any{argument}})
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if _, err := server.handle(context.Background(), protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "workspace/executeCommand", Params: raw}, protocol.NewWriter(&output)); err != nil {
		t.Fatal(err)
	}
	message, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	response, err := protocol.DecodeResponse(message)
	if err != nil || (code == 0 && response.Error != nil) || (code != 0 && (response.Error == nil || response.Error.Code != code)) {
		t.Fatalf("workspace command response: %s %v", message, err)
	}
	return response.Result
}

func TestMigrationEditorPreviewRetainsExactSourcesAndExpiresHandles(t *testing.T) {
	server, doc, created, compiler := migrationEditorFixture(t)
	outside := filepath.Join(t.TempDir(), "another.tesl")
	server.documents[protocol.PathToURI(outside)] = document{URI: protocol.PathToURI(outside), Path: outside, Version: 3, Text: "other project"}
	selection := map[string]any{"entryFile": doc.Path, "projectRoot": filepath.Dir(doc.Path), "database": "App.Main", "newRevision": false}
	raw := migrationEditorCommand(t, server, "tesl.generateMigration", selection, 0)
	var preview struct {
		OK          bool
		PreviewID   string `json:"previewId"`
		Compilable  bool
		Files       []sourceedit.FileEdit
		Diagnostics json.RawMessage
	}
	if err := json.Unmarshal(raw, &preview); err != nil || !preview.OK || len(preview.PreviewID) != 32 || preview.Compilable || len(preview.Files) != 2 || !bytes.Contains(preview.Diagnostics, []byte("MIG003")) {
		t.Fatalf("preview summary: %s %v", raw, err)
	}
	if compiler.calls != 1 || compiler.selection.EntryFile != doc.Path || compiler.selection.Database != "App.Main" ||
		!reflect.DeepEqual(compiler.documents, []tooling.MigrationDocument{{Path: doc.Path, Version: 19, Source: "old"}}) {
		t.Fatalf("wrong compiler selection/overlays: %+v %+v", compiler.selection, compiler.documents)
	}
	contents := migrationEditorCommand(t, server, "tesl.migrationPreviewFile", map[string]string{"previewId": preview.PreviewID, "path": created}, 0)
	var file struct{ Before, After string }
	if err := json.Unmarshal(contents, &file); err != nil || file.Before != "" || file.After != "🌱 new file\n" {
		t.Fatalf("file diff: %s %v", contents, err)
	}
	contents = migrationEditorCommand(t, server, "tesl.migrationPreviewFile", map[string]string{"previewId": preview.PreviewID, "path": doc.Path}, 0)
	if err := json.Unmarshal(contents, &file); err != nil || file.Before != "old" || file.After != "new" {
		t.Fatalf("open-buffer diff: %s %v", contents, err)
	}
	migrationEditorCommand(t, server, "tesl.migrationPreviewFile", map[string]string{"previewId": preview.PreviewID, "path": outside}, -32602)
	oldID := preview.PreviewID
	raw = migrationEditorCommand(t, server, "tesl.generateMigration", selection, 0)
	if err := json.Unmarshal(raw, &preview); err != nil || preview.PreviewID == oldID {
		t.Fatal("new preview reused the old review handle")
	}
	migrationEditorCommand(t, server, "tesl.migrationPreviewFile", map[string]string{"previewId": oldID, "path": created}, -32602)
	if entries, err := os.ReadDir(filepath.Dir(doc.Path)); err != nil || len(entries) != 0 || server.documents[doc.URI].Text != "old" {
		t.Fatal("preview wrote disk or changed the editor buffer")
	}
	capabilities, _ := json.Marshal(server.initializeCapabilities(json.RawMessage(`{}`)))
	if !bytes.Contains(capabilities, []byte("tesl.generateMigration")) || !bytes.Contains(capabilities, []byte("tesl.migrationPreviewFile")) {
		t.Fatal("preview commands not advertised")
	}
}

func TestMigrationEditorRefusalInvalidatesPriorPreview(t *testing.T) {
	server, doc, created, compiler := migrationEditorFixture(t)
	selection := map[string]any{"entryFile": doc.Path, "projectRoot": filepath.Dir(doc.Path)}
	migrationEditorCommand(t, server, "tesl.generateMigration", selection, 0)
	if server.migrationPreview == nil {
		t.Fatal("successful preview was not retained")
	}
	oldID := server.migrationPreview.id
	compiler.failure = errors.New("compiler refused selection")
	compiler.output = []byte(`{"version":1,"kind":"migration-source-preview","ok":false,"errors":[{"message":"choose a database","candidates":[{"database":"App.Other"}]}],"manifest":null}`)
	raw := migrationEditorCommand(t, server, "tesl.generateMigration", selection, 0)
	if !bytes.Contains(raw, []byte(`"ok":false`)) || !bytes.Contains(raw, []byte("App.Other")) || server.migrationPreview != nil {
		t.Fatalf("refusal retained writable preview or lost candidates: %s", raw)
	}
	migrationEditorCommand(t, server, "tesl.migrationPreviewFile", map[string]string{"previewId": oldID, "path": created}, -32602)
	migrationEditorCommand(t, server, "tesl.generateMigration", map[string]string{"entryFile": doc.Path}, -32602)
	migrationEditorCommand(t, server, "tesl.unknown", selection, -32602)
	if compiler.calls != 2 {
		t.Fatal("invalid arguments reached the compiler")
	}
}

func TestMigrationEditorForwardsDecisionAndReviewedDigest(t *testing.T) {
	server, doc, _, compiler := migrationEditorFixture(t)
	selection := map[string]any{"entryFile": doc.Path, "projectRoot": filepath.Dir(doc.Path), "database": "App.Main", "decisionId": "NotesSchema.Note", "optionId": "additive-default", "expectedInputDigest": strings.Repeat("a", 64), "template": "untrusted arbitrary source is never forwarded"}
	migrationEditorCommand(t, server, "tesl.generateMigration", selection, 0)
	if compiler.selection.DecisionID != "NotesSchema.Note" || compiler.selection.OptionID != "additive-default" || compiler.selection.ExpectedInputDigest != strings.Repeat("a", 64) || len(compiler.documents) != 1 || compiler.documents[0].Source != doc.Text {
		t.Fatalf("choice bypassed compiler input guards: %+v", compiler.selection)
	}
}

func TestMigrationEditorMalformedGenerationExpiresPreview(t *testing.T) {
	server, doc, _, compiler := migrationEditorFixture(t)
	migrationEditorCommand(t, server, "tesl.generateMigration", map[string]string{"entryFile": doc.Path, "projectRoot": filepath.Dir(doc.Path)}, 0)
	var output bytes.Buffer
	if err := server.writeMigrationCommand(context.Background(), json.RawMessage(`1`), json.RawMessage(`{"command":"tesl.generateMigration","arguments":[]}`), protocol.NewWriter(&output)); err != nil {
		t.Fatal(err)
	}
	message, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	response, err := protocol.DecodeResponse(message)
	if err != nil || response.Error == nil || response.Error.Code != -32602 || server.migrationPreview != nil || compiler.calls != 1 {
		t.Fatalf("invalid generation preserved prior authority: %s %v", message, err)
	}
}

func TestMigrationEditorUnsupportedCompilerDoesNotAdvertiseCommands(t *testing.T) {
	server := NewServer(&fakeCompiler{})
	capabilities, err := json.Marshal(server.initializeCapabilities(json.RawMessage(`{}`)))
	if err != nil || bytes.Contains(capabilities, []byte("executeCommandProvider")) {
		t.Fatalf("unsupported migration capability: %s %v", capabilities, err)
	}
	migrationEditorCommand(t, server, "tesl.generateMigration", map[string]string{"entryFile": "/app.tesl", "projectRoot": "/"}, -32602)
}

func TestMigrationEditorDiffRejectsOversizedEncodedContents(t *testing.T) {
	for _, source := range []string{strings.Repeat("x", protocol.DefaultMaxMessageBytes/2+1), strings.Repeat("\x01", protocol.DefaultMaxMessageBytes/12)} {
		server, _, created, compiler := migrationEditorFixture(t)
		var envelope struct {
			Manifest map[string]json.RawMessage `json:"manifest"`
		}
		if err := json.Unmarshal(compiler.preview.JSON(), &envelope); err != nil {
			t.Fatal(err)
		}
		var edits []map[string]json.RawMessage
		if err := json.Unmarshal(envelope.Manifest["edits"], &edits); err != nil || len(edits) != 2 {
			t.Fatalf("fixture edits: %v", err)
		}
		edits[1]["afterHex"], _ = json.Marshal(hex.EncodeToString([]byte(source)))
		envelope.Manifest["edits"], _ = json.Marshal(edits)
		manifest, _ := json.Marshal(envelope.Manifest)
		fields := map[string]json.RawMessage{}
		if err := json.Unmarshal(compiler.preview.JSON(), &fields); err != nil {
			t.Fatal(err)
		}
		fields["manifest"] = manifest
		raw, _ := json.Marshal(fields)
		preview, err := sourceedit.DecodePreview(raw)
		if err != nil {
			t.Fatal(err)
		}
		server.migrationPreview = &migrationPreviewState{id: "test", preview: preview}
		argument, _ := json.Marshal(map[string]string{"previewId": "test", "path": created})
		var output bytes.Buffer
		err = server.writeMigrationPreviewFile(json.RawMessage(`1`), argument, protocol.NewWriter(&output))
		if err == nil || !strings.Contains(err.Error(), "message limit") || output.Len() != 0 {
			t.Fatalf("oversized diff reached transport: %v (%d bytes)", err, output.Len())
		}
	}
}

type cancellableMigrationPreviewCompiler struct {
	*fakeCompiler
	preview           *sourceedit.Preview
	started, canceled chan struct{}
	count             atomic.Int32
}

func (compiler *cancellableMigrationPreviewCompiler) QueryMigrationPreview(ctx context.Context, _ tooling.MigrationSelection, _ []tooling.MigrationDocument) (*sourceedit.Preview, tooling.Result, error) {
	if compiler.count.Add(1) == 2 {
		close(compiler.started)
		<-ctx.Done()
		close(compiler.canceled)
	}
	// Deliberately return a late success: the LSP must discard it on cancellation.
	return compiler.preview, tooling.Result{}, nil
}

func TestMigrationEditorCancellationDiscardsLatePreviewAndOldHandle(t *testing.T) {
	_, doc, created, fixture := migrationEditorFixture(t)
	compiler := &cancellableMigrationPreviewCompiler{fakeCompiler: &fakeCompiler{payload: []byte(`{"version":1,"diagnostics":[]}`)},
		preview: fixture.preview, started: make(chan struct{}), canceled: make(chan struct{})}
	connection := newRequestConnection(t, compiler)
	connection.send(t, "", "textDocument/didOpen", map[string]any{"textDocument": map[string]any{"uri": doc.URI, "version": doc.Version, "text": doc.Text}})
	params := map[string]any{"command": "tesl.generateMigration", "arguments": []any{map[string]any{"entryFile": doc.Path, "projectRoot": filepath.Dir(doc.Path)}}}
	connection.send(t, "1", "workspace/executeCommand", params)
	response := connection.response(t, "1", 0)
	var original struct {
		PreviewID string `json:"previewId"`
	}
	if err := json.Unmarshal(response.Result, &original); err != nil || original.PreviewID == "" {
		t.Fatalf("missing initial preview: %s %v", response.Result, err)
	}
	connection.send(t, "2", "workspace/executeCommand", params)
	awaitSignal(t, compiler.started, "migration compiler request")
	connection.send(t, "", "$/cancelRequest", map[string]int{"id": 2})
	awaitSignal(t, compiler.canceled, "migration compiler cancellation")
	connection.response(t, "2", requestCancelled)
	connection.send(t, "3", "workspace/executeCommand", map[string]any{"command": "tesl.migrationPreviewFile", "arguments": []any{
		map[string]string{"previewId": original.PreviewID, "path": created}}})
	connection.response(t, "3", -32602)
}

func TestMigrationEditorForwardsCompilerDecisionsAndAllDiagnosticGuidance(t *testing.T) {
	for _, hasOption := range []bool{false, true} {
		t.Run(fmt.Sprintf("option=%v", hasOption), func(t *testing.T) {
			server, doc, _, compiler := migrationEditorFixture(t)
			var envelope map[string]any
			if err := json.Unmarshal(compiler.preview.JSON(), &envelope); err != nil {
				t.Fatal(err)
			}
			options := []any{}
			if hasOption {
				options = append(options, map[string]any{"id": "additive-default", "label": "Supply a literal", "template": "Additive [Default count (todo \"Choose Int\")]", "help": "Compiler checked structural route", "needsCustomCode": true})
			}
			envelope["decisions"] = []any{map[string]any{"id": "entity:Todo", "entity": "Todo", "file": doc.Path, "line": 0, "col": 0, "reason": "choose a value", "options": options}}
			envelope["diagnostics"] = map[string]any{"version": 1, "diagnostics": []any{
				map[string]any{"file": doc.Path, "start": map[string]int{"line": 0, "col": 0}, "code": "MIG003", "severity": "error", "message": "choose a value"},
				map[string]any{"code": "MIG013", "severity": "error", "message": "frozen source changed"},
				map[string]any{"code": "T001", "severity": "error", "message": "expected Int, got String"},
			}}
			raw, err := json.Marshal(envelope)
			if err != nil {
				t.Fatal(err)
			}
			compiler.preview, err = sourceedit.DecodePreview(raw)
			if err != nil {
				t.Fatal(err)
			}
			raw = migrationEditorCommand(t, server, "tesl.generateMigration", map[string]any{"entryFile": doc.Path, "projectRoot": filepath.Dir(doc.Path)}, 0)
			var result struct {
				Decisions []json.RawMessage
				Guidance  []struct {
					DiagnosticIndex int
					DecisionID      string
					Guide           struct {
						Title   string
						Options []json.RawMessage
					}
				}
			}
			if err := json.Unmarshal(raw, &result); err != nil {
				t.Fatal(err)
			}
			if len(result.Decisions) != 1 || len(result.Guidance) != 3 || result.Guidance[0].DecisionID != "entity:Todo" || result.Guidance[1].Guide.Title != "Restore the recorded history" || result.Guidance[2].Guide.Title != "Resolve this compiler diagnostic" {
				t.Fatalf("lost compiler decisions/diagnostics: %s", raw)
			}
			wantOptions := 0
			if hasOption {
				wantOptions = 1
			}
			if len(result.Guidance[0].Guide.Options) != wantOptions {
				t.Fatalf("invented alternatives: %s", raw)
			}
		})
	}
}
