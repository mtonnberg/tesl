//go:build linux

package lsp

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/sourceedit"
	"tesl.dev/runtime/go/internal/tooling"
)

// Unlike the call-recording unit fixture, this compiler is safe for concurrent
// background diagnostics launched by real didChange/didOpen notifications.
type migrationWireCompiler struct{ *migrationPreviewCompiler }

func (*migrationWireCompiler) QuerySourceJSON(context.Context, string, string, string, ...string) ([]byte, tooling.Result, error) {
	return []byte(`{"version":1,"diagnostics":[]}`), tooling.Result{}, nil
}

type migrationWireClient struct {
	t            *testing.T
	writer       *protocol.Writer
	frames       chan json.RawMessage
	docs         map[string]document
	seq          uint64
	lastResponse json.RawMessage
}

func (client *migrationWireClient) send(value any) {
	client.t.Helper()
	if err := client.writer.WriteJSON(value); err != nil {
		client.t.Fatal(err)
	}
}

func (client *migrationWireClient) next() protocol.Request {
	client.t.Helper()
	for {
		select {
		case raw := <-client.frames:
			var frame protocol.Request
			if err := json.Unmarshal(raw, &frame); err != nil {
				client.t.Fatal(err)
			}
			if frame.Method != "" && len(frame.ID) == 0 {
				if frame.Method == "textDocument/publishDiagnostics" {
					var params struct {
						Diagnostics []json.RawMessage `json:"diagnostics"`
					}
					if err := json.Unmarshal(frame.Params, &params); err != nil || params.Diagnostics == nil {
						client.t.Fatalf("diagnostic notification must contain an array: %s %v", raw, err)
					}
				}
				continue
			}
			if frame.Method == "" {
				client.lastResponse = raw
			}
			return frame
		case <-time.After(5 * time.Second):
			client.t.Fatal("migration wire did not progress")
		}
	}
}

func (client *migrationWireClient) snapshot(request protocol.Request, omitFence bool) {
	client.t.Helper()
	if request.Method != "tesl/migrationSnapshot" {
		client.t.Fatalf("expected snapshot, got %s", request.Method)
	}
	var params struct {
		PreviewID string `json:"previewId"`
	}
	if err := json.Unmarshal(request.Params, &params); err != nil {
		client.t.Fatal(err)
	}
	entries := []any{}
	for _, doc := range client.docs {
		entries = append(entries, map[string]any{"uri": doc.URI, "version": doc.Version, "source": doc.Text, "openId": strconv.FormatUint(doc.openID, 10)})
	}
	client.seq++
	if !omitFence {
		raw, _ := json.Marshal(map[string]any{"version": 1, "previewId": params.PreviewID, "eventSeq": client.seq})
		client.send(protocol.Request{JSONRPC: "2.0", Method: "tesl/migrationSnapshotFence", Params: raw})
	}
	raw, _ := json.Marshal(map[string]any{"version": 1, "previewId": params.PreviewID, "eventSeq": client.seq, "documents": entries})
	client.send(protocol.Response{JSONRPC: "2.0", ID: request.ID, Result: raw})
}

func (client *migrationWireClient) edits(request protocol.Request, limit int) []document {
	client.t.Helper()
	if request.Method != "tesl/migrationApplyEdit" {
		client.t.Fatalf("expected guarded edit, got %s", request.Method)
	}
	var params struct {
		Documents []struct {
			URI     string `json:"uri"`
			Version int    `json:"version"`
			Source  string `json:"source"`
			OpenID  string `json:"openId"`
			NewText string `json:"newText"`
		} `json:"documents"`
	}
	if err := json.Unmarshal(request.Params, &params); err != nil {
		client.t.Fatal(err)
	}
	changed := []document{}
	for i, edit := range params.Documents {
		doc := client.docs[edit.URI]
		if doc.Text != edit.Source || doc.Version != edit.Version || strconv.FormatUint(doc.openID, 10) != edit.OpenID {
			client.t.Fatal("wire edit lacks exact preimage/lifetime/version guards")
		}
		if i >= limit {
			continue
		}
		doc.Text, doc.Version = edit.NewText, doc.Version+3
		client.docs[doc.URI] = doc
		changed = append(changed, doc)
	}
	return changed
}

func (client *migrationWireClient) changes(changed []document) {
	for _, doc := range changed {
		raw, _ := json.Marshal(map[string]any{"textDocument": map[string]any{"uri": doc.URI, "version": doc.Version}, "contentChanges": []any{map[string]string{"text": doc.Text}}})
		client.send(protocol.Request{JSONRPC: "2.0", Method: "textDocument/didChange", Params: raw})
	}
}

func TestMigrationApplicationCheckedBarriersThroughJSONRPC(t *testing.T) {
	for _, scenario := range []string{"ack before change", "ack after change", "omitted change", "missing fence", "partial refusal", "refused", "user edit", "close reopen", "opened published file", "inverse user edit", "inverse omitted change", "cancelled", "disconnect"} {
		t.Run(scenario, func(t *testing.T) {
			server, _, doc, created := migrationApplicationFixture(t, true)
			server.compiler = &migrationWireCompiler{server.compiler.(*migrationPreviewCompiler)}
			previewID := server.migrationPreview.id
			input, send := io.Pipe()
			receive, output := io.Pipe()
			ctx, cancel := context.WithCancel(context.Background())
			finished := make(chan struct{})
			readerDone := make(chan struct{})
			client := &migrationWireClient{t: t, writer: protocol.NewWriter(send), frames: make(chan json.RawMessage, 64), docs: map[string]document{}}
			for uri, doc := range server.documents {
				client.docs[uri] = doc
			}
			go func() {
				defer close(readerDone)
				reader := protocol.NewReader(receive)
				for {
					raw, err := reader.Read()
					if err != nil {
						return
					}
					client.frames <- raw
				}
			}()
			go func() { defer close(finished); server.Run(ctx, input, output); _ = output.Close() }()
			t.Cleanup(func() {
				cancel()
				_ = send.Close()
				_ = receive.Close()
				awaitSignal(t, finished, "migration session")
				awaitSignal(t, readerDone, "migration wire reader")
			})
			client.send(protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "initialize", Params: json.RawMessage(`{"capabilities":{"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true,"failureHandling":"transactional"}},"experimental":{"teslMigrationApply":{"version":1,"snapshotBarrier":1}}}}`)})
			if response := client.next(); string(response.ID) != "1" {
				t.Fatal("initialize response missing")
			}
			raw, _ := json.Marshal(map[string]any{"command": "tesl.applyMigration", "arguments": []any{map[string]string{"previewId": previewID}}})
			client.send(protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`44`), Method: "workspace/executeCommand", Params: raw})
			before := client.next()
			if _, err := os.Stat(created); !os.IsNotExist(err) {
				t.Fatal("source was published before client preflight fence")
			}
			client.snapshot(before, false)
			edit := client.next()
			if scenario == "disconnect" {
				client.edits(edit, 2)
				_ = send.Close()
				awaitSignal(t, finished, "disconnected migration session")
				if report, err := sourceedit.Recover(context.Background(), filepath.Dir(doc.Path)); err == nil || !report.RecoveryRequired {
					t.Fatal("disk-only recovery guessed a disconnected editor outcome")
				}
				return
			}
			limit := 2
			if scenario == "partial refusal" || strings.HasPrefix(scenario, "inverse ") {
				limit = 1
			}
			if scenario == "refused" {
				limit = 0
			}
			changed := client.edits(edit, limit)
			if scenario == "ack after change" {
				client.changes(changed)
			}
			applied := scenario != "partial refusal" && scenario != "refused" && !strings.HasPrefix(scenario, "inverse ")
			ack, _ := json.Marshal(map[string]bool{"applied": applied})
			client.send(protocol.Response{JSONRPC: "2.0", ID: edit.ID, Result: ack})
			if scenario == "cancelled" {
				client.send(protocol.Request{JSONRPC: "2.0", Method: "$/cancelRequest", Params: json.RawMessage(`{"id":44}`)})
			}
			snapshot := client.next()
			if scenario == "user edit" {
				after := client.docs[doc.URI]
				after.Text = "concurrent user work"
				after.Version++
				client.docs[doc.URI] = after
				changed = []document{after}
			}
			if scenario != "ack after change" && scenario != "omitted change" {
				client.changes(changed)
			}
			if scenario == "close reopen" {
				after := client.docs[doc.URI]
				after.openID += 100
				client.docs[doc.URI] = after
				closeRaw, _ := json.Marshal(map[string]any{"textDocument": map[string]string{"uri": doc.URI}})
				client.send(protocol.Request{JSONRPC: "2.0", Method: "textDocument/didClose", Params: closeRaw})
				openRaw, _ := json.Marshal(map[string]any{"textDocument": map[string]any{"uri": doc.URI, "languageId": "tesl", "version": after.Version, "text": after.Text}})
				client.send(protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: openRaw})
			}
			if scenario == "opened published file" {
				opened := document{URI: protocol.PathToURI(created), Path: created, Version: 1, Text: "new closed file\n", openID: 100}
				client.docs[opened.URI] = opened
				raw, _ := json.Marshal(map[string]any{"textDocument": map[string]any{"uri": opened.URI, "languageId": "tesl", "version": opened.Version, "text": opened.Text}})
				client.send(protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: raw})
			}
			client.snapshot(snapshot, scenario == "missing fence")
			if scenario == "cancelled" {
				for i := 0; i < 2; i++ {
					inverse := client.next()
					restored := client.edits(inverse, 2)
					client.send(protocol.Response{JSONRPC: "2.0", ID: inverse.ID, Result: json.RawMessage(`{"applied":true}`)})
					fence := client.next()
					client.changes(restored)
					client.snapshot(fence, false)
				}
			}
			if scenario == "partial refusal" || strings.HasPrefix(scenario, "inverse ") {
				inverse := client.next()
				restored := []document{}
				ack := json.RawMessage(`{"applied":true}`)
				if scenario == "inverse user edit" {
					changed := client.docs[doc.URI]
					changed.Text = "user edit before inverse"
					changed.Version++
					client.docs[doc.URI] = changed
					restored = []document{changed}
					ack = json.RawMessage(`{"applied":false}`)
				} else {
					restored = client.edits(inverse, 2)
				}
				client.send(protocol.Response{JSONRPC: "2.0", ID: inverse.ID, Result: ack})
				fence := client.next()
				if scenario != "inverse omitted change" {
					client.changes(restored)
				}
				client.snapshot(fence, false)
			}
			response := client.next()
			var result migrationApplicationResult
			if string(response.ID) != "44" || response.Method != "" {
				t.Fatalf("missing application response: %+v", response)
			}
			final, err := protocol.DecodeResponse(client.lastResponse)
			if scenario == "cancelled" {
				if err != nil || final.Error == nil || final.Error.Code != -32800 {
					t.Fatalf("cancelled request lost its cancellation response: %s %v", client.lastResponse, err)
				}
				raw, _ := json.Marshal(map[string]any{"command": "tesl.migrationApplicationStatus", "arguments": []any{map[string]string{"previewId": previewID}}})
				client.send(protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`45`), Method: "workspace/executeCommand", Params: raw})
				client.next()
				final, err = protocol.DecodeResponse(client.lastResponse)
			}
			if err != nil || final.Error != nil || json.Unmarshal(final.Result, &result) != nil {
				t.Fatalf("invalid final reply: %s %v", client.lastResponse, err)
			}
			want := "editor-pending"
			recovery := true
			if scenario == "ack before change" || scenario == "ack after change" {
				want, recovery = "committed", false
			}
			if scenario == "partial refusal" || scenario == "refused" || scenario == "cancelled" {
				want, recovery = "restored", false
			}
			if result.SourceTransaction.Outcome != want || result.SourceTransaction.RecoveryRequired != recovery || result.OK != (want == "committed") {
				t.Fatalf("wrong wire outcome: %+v", result)
			}
			if scenario == "user edit" && client.docs[doc.URI].Text != "concurrent user work" {
				t.Fatal("user bytes changed during failed migration")
			}
			if scenario == "inverse user edit" && client.docs[doc.URI].Text != "user edit before inverse" {
				t.Fatal("inverse overwrote newer user work")
			}
			if disk, err := os.ReadFile(doc.Path); err != nil || string(disk) != "saved file app.tesl" {
				t.Fatal("editor buffer was saved through the filesystem")
			}
			if _, err := os.Stat(created); want == "restored" && !os.IsNotExist(err) || want != "restored" && err != nil {
				t.Fatalf("wrong generated source state: %v", err)
			}
			if recovery {
				if report, err := sourceedit.Recover(context.Background(), filepath.Dir(doc.Path)); err == nil || !report.RecoveryRequired {
					t.Fatal("uncertain wire outcome lost its journal")
				}
			}
		})
	}
}

func TestBuiltCompilerChoiceUpdatesRealMigrationBufferAndChecksAuthoredCode(t *testing.T) {
	repo := os.Getenv("TESL_REPO_ROOT")
	if repo == "" {
		t.Skip("requires TESL_REPO_ROOT and the built compiler")
	}
	root := t.TempDir()
	entry, schema, migration := filepath.Join(root, "app.tesl"), filepath.Join(root, "schema/notes/v-current.tesl"), filepath.Join(root, "migrations/notes/v2.tesl")
	application := "module App exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport NotesSchema.VCurrent\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }\n"
	schemaSource := "module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n"
	if err := os.MkdirAll(filepath.Dir(schema), 0700); err != nil {
		t.Fatal(err)
	}
	for path, text := range map[string]string{filepath.Join(root, "tesl.toml"): "", entry: application, schema: schemaSource} {
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	compiler := tooling.Client{Executable: filepath.Join(repo, "compiler/_build/default/bin/main.exe"), Environment: os.Environ()}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	t.Cleanup(cancel)
	selection := tooling.MigrationSelection{EntryFile: entry, ProjectRoot: root, Database: "App.Main", NewRevision: true}
	{
		preview, result, err := compiler.QueryMigrationPreview(ctx, selection, nil)
		if err != nil {
			t.Fatalf("prepare real revision: %v\n%s\n%s", err, result.Stdout, result.Stderr)
		}
		if _, err := preview.Manifest().Apply(ctx); err != nil {
			t.Fatal(err)
		}
	}
	schemaSource = strings.Replace(schemaSource, "id: String }", "id: String, title: String }", 1)
	if err := os.WriteFile(schema, []byte(schemaSource), 0600); err != nil {
		t.Fatal(err)
	}
	savedMigration, err := os.ReadFile(migration)
	if err != nil {
		t.Fatal(err)
	}
	server := NewServer(compiler)
	input, send := io.Pipe()
	receive, output := io.Pipe()
	finished, readerDone := make(chan struct{}), make(chan struct{})
	client := &migrationWireClient{t: t, writer: protocol.NewWriter(send), frames: make(chan json.RawMessage, 64), docs: map[string]document{}}
	go func() {
		defer close(readerDone)
		reader := protocol.NewReader(receive)
		for {
			raw, err := reader.Read()
			if err != nil {
				return
			}
			client.frames <- raw
		}
	}()
	go func() { defer close(finished); server.Run(ctx, input, output); _ = output.Close() }()
	t.Cleanup(func() {
		cancel()
		_ = send.Close()
		_ = receive.Close()
		awaitSignal(t, finished, "native migration session")
		awaitSignal(t, readerDone, "native migration reader")
	})
	client.send(protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: "initialize", Params: json.RawMessage(`{"capabilities":{"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true,"failureHandling":"transactional"}},"experimental":{"teslMigrationApply":{"version":1,"snapshotBarrier":1}}}}`)})
	client.next()
	for i, file := range []struct{ path, text string }{{migration, string(savedMigration)}, {schema, schemaSource}} {
		doc := document{URI: protocol.PathToURI(file.path), Path: file.path, Text: file.text, Version: 5 + i, openID: uint64(i + 1)}
		client.docs[doc.URI] = doc
		raw, _ := json.Marshal(map[string]any{"textDocument": map[string]any{"uri": doc.URI, "languageId": "tesl", "version": doc.Version, "text": doc.Text}})
		client.send(protocol.Request{JSONRPC: "2.0", Method: "textDocument/didOpen", Params: raw})
	}
	command := func(id int, name string, args any) json.RawMessage {
		raw, _ := json.Marshal(map[string]any{"command": name, "arguments": []any{args}})
		client.send(protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(strconv.Itoa(id)), Method: "workspace/executeCommand", Params: raw})
		response := client.next()
		if response.Method != "" || string(response.ID) != strconv.Itoa(id) {
			t.Fatalf("missing command response: %+v", response)
		}
		result, err := protocol.DecodeResponse(client.lastResponse)
		if err != nil || result.Error != nil {
			t.Fatalf("native migration command refused: %s %v", client.lastResponse, err)
		}
		return result.Result
	}
	generate := map[string]any{"entryFile": entry, "projectRoot": root, "database": "App.Main"}
	var baseline struct {
		InputDigest string `json:"inputDigest"`
		Decisions   []struct {
			ID      string
			Options []struct{ ID string }
		}
	}
	if err := json.Unmarshal(command(10, "tesl.generateMigration", generate), &baseline); err != nil {
		t.Fatal(err)
	}
	if len(baseline.InputDigest) != 64 || len(baseline.Decisions) != 1 {
		t.Fatalf("compiler decision metadata missing: %+v", baseline)
	}
	option := ""
	for _, item := range baseline.Decisions[0].Options {
		if item.ID == "additive-default" {
			option = item.ID
		}
	}
	if option == "" {
		t.Fatal("compiler did not offer its accepted additive default scaffold")
	}
	generate["decisionId"], generate["optionId"], generate["expectedInputDigest"] = baseline.Decisions[0].ID, option, baseline.InputDigest
	var selected struct {
		PreviewID  string `json:"previewId"`
		Compilable bool
	}
	if err := json.Unmarshal(command(11, "tesl.generateMigration", generate), &selected); err != nil || selected.PreviewID == "" {
		t.Fatalf("missing selected preview: %+v %v", selected, err)
	}
	apply := func(id int, previewID string) migrationApplicationResult {
		raw, _ := json.Marshal(map[string]any{"command": "tesl.applyMigration", "arguments": []any{map[string]string{"previewId": previewID}}})
		client.send(protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(strconv.Itoa(id)), Method: "workspace/executeCommand", Params: raw})
		var pending []document
		for {
			request := client.next()
			switch request.Method {
			case "tesl/migrationSnapshot":
				client.changes(pending)
				pending = nil
				client.snapshot(request, false)
			case "tesl/migrationApplyEdit":
				pending = client.edits(request, 256)
				client.send(protocol.Response{JSONRPC: "2.0", ID: request.ID, Result: json.RawMessage(`{"applied":true}`)})
			case "":
				response, err := protocol.DecodeResponse(client.lastResponse)
				var result migrationApplicationResult
				if err != nil || response.Error != nil || json.Unmarshal(response.Result, &result) != nil || string(response.ID) != strconv.Itoa(id) {
					t.Fatalf("native application failed: %s %v", client.lastResponse, err)
				}
				return result
			default:
				t.Fatalf("unexpected native client request %s", request.Method)
			}
		}
	}
	if result := apply(12, selected.PreviewID); !result.OK || result.Compilable {
		t.Fatalf("chosen scaffold must apply with an explicit unresolved source hole: %+v", result)
	}
	actual := client.docs[protocol.PathToURI(migration)]
	if !strings.Contains(actual.Text, "Default title (todo") {
		t.Fatalf("choosing the option did not update the actual open migration buffer: %s", actual.Text)
	}
	if saved, err := os.ReadFile(migration); err != nil || string(saved) != string(savedMigration) {
		t.Fatal("source transaction saved an open buffer behind the editor")
	}
	holes := regexp.MustCompile(`todo "(?:\\.|[^"\\])*"`)
	if len(holes.FindAllString(actual.Text, -1)) != 1 {
		t.Fatalf("unexpected generated custom-code hole: %s", actual.Text)
	}
	actual.Text = holes.ReplaceAllString(actual.Text, `"untitled"`)
	actual.Version++
	client.docs[actual.URI] = actual
	client.changes([]document{actual})
	// This is the developer saving authored code through the editor, after the
	// checked application. The server's filesystem writer never saves it.
	if err := os.WriteFile(migration, []byte(actual.Text), 0600); err != nil {
		t.Fatal(err)
	}
	delete(generate, "decisionId")
	delete(generate, "optionId")
	delete(generate, "expectedInputDigest")
	if err := json.Unmarshal(command(13, "tesl.generateMigration", generate), &selected); err != nil || !selected.Compilable {
		t.Fatalf("authored migration did not compile: %+v %v", selected, err)
	}
	if result := apply(14, selected.PreviewID); !result.OK || !result.Compilable {
		t.Fatalf("checked authored migration did not apply: %+v", result)
	}
	for _, doc := range client.docs {
		if err := os.WriteFile(doc.Path, []byte(doc.Text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if result, err := compiler.Run(ctx, "agent-context", entry); err != nil {
		t.Fatalf("saved authored migration failed full application judgment: %v\n%s\n%s", err, result.Stdout, result.Stderr)
	}
}
