//go:build linux

package lsp

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/sourceedit"
)

// An independent wire fixture exercises actual journal/file operations without
// invoking the compiler for every client failure. The native compiler journey
// separately checks that its generated proposal works through this coordinator.
func migrationApplicationFixture(t *testing.T, batch bool) (*Server, *bytes.Buffer, document, string) {
	t.Helper()
	server, doc, created, compiler := migrationEditorSourceFixture(t, "old\r\n🌱", "new\r\n🌱")
	root := filepath.Dir(doc.Path)
	hash := func(text string) string { value := sha256.Sum256([]byte(text)); return hex.EncodeToString(value[:]) }
	var envelope map[string]any
	if err := json.Unmarshal(compiler.preview.JSON(), &envelope); err != nil {
		t.Fatal(err)
	}
	m := envelope["manifest"].(map[string]any)
	var inputs, documents, edits []any
	for i, name := range []string{"app.tesl", "b.tesl", "dependency.tesl"} {
		path := filepath.Join(root, name)
		before, after, disk := "old\r\n🌱", "new\r\n🌱", "saved file "+name
		if err := os.WriteFile(path, []byte(disk), 0600); err != nil {
			t.Fatal(err)
		}
		opened := document{URI: protocol.PathToURI(path), Path: path, Version: 19 + i, Text: before, openID: uint64(i + 1)}
		server.documents[opened.URI] = opened
		if i == 0 {
			doc = opened
		}
		inputs = append(inputs, map[string]any{"path": path, "sourceHash": hash(before), "diskHash": hash(disk)})
		documents = append(documents, map[string]any{"path": path, "version": opened.Version})
		if i < 2 {
			edits = append(edits, map[string]any{"path": path, "beforeHex": hex.EncodeToString([]byte(before)), "afterHex": hex.EncodeToString([]byte(after)), "documentVersion": opened.Version})
		}
	}
	inputs = append(inputs, map[string]any{"path": created, "sourceHash": nil, "diskHash": nil})
	edits = append(edits, map[string]any{"path": created, "beforeHex": nil, "afterHex": hex.EncodeToString([]byte("new closed file\n")), "documentVersion": nil})
	directoryHash := hash("tesl-directory-v1\x00app.tesl\x00b.tesl\x00dependency.tesl\x00")
	m["inputs"], m["documents"], m["edits"] = inputs, documents, edits
	m["directories"] = []any{map[string]any{"path": root, "sourceHash": directoryHash, "diskHash": directoryHash}}
	raw, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	compiler.preview, err = sourceedit.DecodePreview(raw)
	if err != nil {
		t.Fatal(err)
	}
	server.migrationApplySupported, server.migrationBatchEdits = true, batch
	previewMigrationEditPlan(t, server, doc)
	t.Cleanup(server.closeClientRequests)
	return server, &bytes.Buffer{}, doc, created
}

func startMigrationApplication(t *testing.T, ctx context.Context, server *Server, output *bytes.Buffer) string {
	t.Helper()
	if server.migrationPreview == nil {
		t.Fatal("missing preview")
	}
	id := server.migrationPreview.id
	raw, _ := json.Marshal(map[string]string{"previewId": id})
	if err := server.writeMigrationApply(ctx, json.RawMessage(`44`), raw, protocol.NewWriter(output)); err != nil {
		t.Fatal(err)
	}
	return id
}

func nextMigrationClientEdit(t *testing.T, output *bytes.Buffer) (protocol.Request, []*migrationTextDocumentEdit) {
	t.Helper()
	raw, err := protocol.NewReader(output).Read()
	if err != nil {
		t.Fatal(err)
	}
	request, err := protocol.DecodeRequest(raw)
	if err != nil || request.Method != "workspace/applyEdit" {
		t.Fatalf("expected client edit: %s %v", raw, err)
	}
	var params struct {
		Edit struct {
			DocumentChanges []*migrationTextDocumentEdit `json:"documentChanges"`
		} `json:"edit"`
	}
	if err := json.Unmarshal(request.Params, &params); err != nil || len(params.Edit.DocumentChanges) == 0 {
		t.Fatalf("empty edit: %s %v", raw, err)
	}
	return request, params.Edit.DocumentChanges
}

func observeMigrationEdits(t *testing.T, server *Server, edits []*migrationTextDocumentEdit) {
	t.Helper()
	for _, edit := range edits {
		doc, ok := server.documents[edit.TextDocument.URI]
		if !ok || doc.Version != edit.TextDocument.Version {
			t.Fatal("client was given an unguarded edit")
		}
		doc.Text = applyMigrationTestEdit(t, doc.Text, edit)
		doc.Version += 3 // The coordinator must observe, not guess, the new version.
		server.documents[doc.URI] = doc
	}
}

func acknowledgeMigration(t *testing.T, server *Server, request protocol.Request, result string) {
	t.Helper()
	if err := server.finishClientRequest(protocol.Response{ID: request.ID, Result: json.RawMessage(result)}); err != nil {
		t.Fatal(err)
	}
}

func assertMigrationOutcome(t *testing.T, server *Server, output *bytes.Buffer, outcome string, recovery bool) {
	t.Helper()
	if server.migrationApply != nil || server.migrationResult == nil {
		t.Fatal("application has no terminal result")
	}
	result := server.migrationResult
	if result.SourceTransaction.Outcome != outcome || result.SourceTransaction.RecoveryRequired != recovery || result.OK != (outcome == "committed") {
		t.Fatalf("incorrect application result: %+v", result)
	}
	raw, err := protocol.NewReader(output).Read()
	if err != nil {
		t.Fatal(err)
	}
	response, err := protocol.DecodeResponse(raw)
	if err != nil || response.Error != nil || !bytes.Contains(response.Result, []byte(`"kind":"migration-editor-application"`)) {
		t.Fatalf("final application reply: %s %v", raw, err)
	}
}

func TestMigrationApplicationCommitsOnlyObservedBuffers(t *testing.T) {
	for _, batch := range []bool{false, true} {
		server, output, doc, created := migrationApplicationFixture(t, batch)
		id := startMigrationApplication(t, context.Background(), server, output)
		if _, err := os.Stat(created); err != nil {
			t.Fatal("closed file was not published before client edit")
		}
		if report, err := sourceedit.Recover(context.Background(), filepath.Dir(doc.Path)); err == nil || !report.RecoveryRequired {
			t.Fatal("recovery stole active journal")
		}
		requests := 0
		for server.migrationApply != nil {
			request, edits := nextMigrationClientEdit(t, output)
			if batch && len(edits) != 2 || !batch && len(edits) != 1 {
				t.Fatal("negotiated batching was ignored")
			}
			observeMigrationEdits(t, server, edits)
			acknowledgeMigration(t, server, request, `{"applied":true}`)
			requests++
		}
		assertMigrationOutcome(t, server, output, "committed", false)
		if (batch && requests != 1) || (!batch && requests != 2) || len(server.migrationResult.BuffersWritten) != 2 {
			t.Fatal("wrong edit accounting")
		}
		if disk, err := os.ReadFile(doc.Path); err != nil || string(disk) != "saved file app.tesl" {
			t.Fatal("open buffer was saved by source writer")
		}
		status := migrationEditorCommand(t, server, "tesl.migrationApplicationStatus", map[string]string{"previewId": id}, 0)
		if !bytes.Contains(status, []byte(`"outcome":"committed"`)) {
			t.Fatal("completed result is unavailable")
		}
		migrationEditorCommand(t, server, "tesl.applyMigration", map[string]string{"previewId": id}, -32602)
	}
}

func TestMigrationApplicationRestoresPartialEditsAndCancellation(t *testing.T) {
	for _, scenario := range []string{"first refused", "second refused", "partial batch", "cancelled", "dependency changed"} {
		t.Run(scenario, func(t *testing.T) {
			server, output, doc, created := migrationApplicationFixture(t, scenario == "partial batch")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			startMigrationApplication(t, ctx, server, output)
			request, edits := nextMigrationClientEdit(t, output)
			if scenario == "first refused" {
				acknowledgeMigration(t, server, request, `{"applied":false}`)
			} else {
				observeMigrationEdits(t, server, edits[:1])
				if scenario == "cancelled" {
					cancel()
				}
				if scenario == "dependency changed" {
					uri := protocol.PathToURI(filepath.Join(filepath.Dir(doc.Path), "dependency.tesl"))
					changed := server.documents[uri]
					changed.Text = "new user work"
					changed.Version++
					server.documents[uri] = changed
				}
				if scenario == "partial batch" {
					acknowledgeMigration(t, server, request, `{"applied":false,"failedChange":1}`)
				} else {
					acknowledgeMigration(t, server, request, `{"applied":true}`)
					if scenario == "second refused" {
						request, _ = nextMigrationClientEdit(t, output)
						acknowledgeMigration(t, server, request, `{"applied":false}`)
					}
				}
				inverse, changes := nextMigrationClientEdit(t, output)
				observeMigrationEdits(t, server, changes)
				acknowledgeMigration(t, server, inverse, `{"applied":true}`)
			}
			assertMigrationOutcome(t, server, output, "restored", false)
			if server.documents[doc.URI].Text != doc.Text {
				t.Fatal("inverse did not restore original buffer")
			}
			if _, err := os.Stat(created); !os.IsNotExist(err) {
				t.Fatal("closed-file inverse was not completed")
			}
			if scenario == "dependency changed" {
				uri := protocol.PathToURI(filepath.Join(filepath.Dir(doc.Path), "dependency.tesl"))
				if server.documents[uri].Text != "new user work" {
					t.Fatal("inverse overwrote unrelated user work")
				}
			}
		})
	}
}

func TestMigrationApplicationUnknownRepliesAndUserChangesRetainRecovery(t *testing.T) {
	for _, scenario := range []string{"timeout", "missing update", "invalid reply", "user text", "reopened", "closed target opened", "inverse missing update", "inverse refused"} {
		t.Run(scenario, func(t *testing.T) {
			server, output, doc, created := migrationApplicationFixture(t, true)
			startMigrationApplication(t, context.Background(), server, output)
			request, edits := nextMigrationClientEdit(t, output)
			switch scenario {
			case "timeout":
				if err := server.expireClientRequests(time.Now().Add(time.Minute)); err != nil {
					t.Fatal(err)
				}
			case "missing update":
				acknowledgeMigration(t, server, request, `{"applied":true}`)
			case "invalid reply":
				acknowledgeMigration(t, server, request, `{"applied":true,"applied":false}`)
			default:
				observeMigrationEdits(t, server, edits[:1])
				after := server.documents[doc.URI]
				switch scenario {
				case "user text":
					after.Text = "user work after application"
					after.Version++
				case "reopened":
					after.openID++
				case "closed target opened":
					server.documents[protocol.PathToURI(created)] = document{URI: protocol.PathToURI(created), Path: created, Text: "new user work", Version: 1, openID: 90}
				}
				server.documents[doc.URI] = after
				acknowledgeMigration(t, server, request, `{"applied":false}`)
				if strings.HasPrefix(scenario, "inverse ") {
					inverse, _ := nextMigrationClientEdit(t, output)
					if scenario == "inverse refused" {
						acknowledgeMigration(t, server, inverse, `{"applied":false}`)
					} else {
						acknowledgeMigration(t, server, inverse, `{"applied":true}`)
					}
				}
			}
			assertMigrationOutcome(t, server, output, "editor-pending", true)
			if _, err := os.Stat(created); err != nil {
				t.Fatal("uncertain editor outcome rolled disk back")
			}
			if report, err := sourceedit.Recover(context.Background(), filepath.Dir(doc.Path)); err == nil || !report.RecoveryRequired {
				t.Fatal("unknown editor outcome was recovered from disk alone")
			}
			if scenario == "user text" && server.documents[doc.URI].Text != "user work after application" {
				t.Fatal("user text was overwritten")
			}
			acknowledgeMigration(t, server, request, `{"applied":true}`)
			if output.Len() != 0 {
				t.Fatal("late reply produced another outcome")
			}
		})
	}
}

func TestMigrationApplyAcknowledgementIsStrict(t *testing.T) {
	for _, raw := range []string{`null`, `{}`, `{"applied":null}`, `{"applied":1}`, `{"applied":true,"failedChange":0}`, `{"applied":false,"failedChange":-1}`, `{"applied":false,"failureReason":null}`, `{"Applied":true}`} {
		if _, err := migrationApplyAcknowledgement(protocol.Response{Result: json.RawMessage(raw)}); err == nil {
			t.Errorf("accepted %s", raw)
		}
	}
	for _, raw := range []string{`{"applied":true}`, `{"applied":false}`, `{"applied":false,"failedChange":0,"failureReason":"stale version"}`} {
		if _, err := migrationApplyAcknowledgement(protocol.Response{Result: json.RawMessage(raw)}); err != nil {
			t.Errorf("refused %s: %v", raw, err)
		}
	}
}
