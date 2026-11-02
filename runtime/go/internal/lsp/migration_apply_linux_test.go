//go:build linux

package lsp

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
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
	preview, err := sourceedit.DecodePreview(raw)
	if err != nil || preview == nil {
		t.Fatal(err)
	}
	compiler.preview = preview
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
	answerMigrationSnapshot(t, server, output)
	return id
}

func answerMigrationSnapshot(t *testing.T, server *Server, output *bytes.Buffer) {
	t.Helper()
	if output.Len() == 0 {
		return
	}
	peek, err := protocol.NewReader(bytes.NewReader(output.Bytes())).Read()
	if err != nil {
		t.Fatal(err)
	}
	request, err := protocol.DecodeRequest(peek)
	if err != nil || request.Method != "tesl/migrationSnapshot" {
		return
	}
	if _, err := protocol.NewReader(output).Read(); err != nil {
		t.Fatal(err)
	}
	var params struct {
		PreviewID   string `json:"previewId"`
		ProjectRoot string `json:"projectRoot"`
	}
	if err := json.Unmarshal(request.Params, &params); err != nil {
		t.Fatal(err)
	}
	_, docs, err := server.migrationDocuments(params.ProjectRoot)
	if err != nil {
		t.Fatal(err)
	}
	entries := []any{}
	for _, doc := range docs {
		entries = append(entries, map[string]any{"uri": doc.URI, "version": doc.Version, "source": doc.Text, "openId": strconv.FormatUint(doc.openID, 10)})
	}
	sequence := uint64(1)
	if op := server.migrationApply; op != nil {
		sequence = op.eventSeq + 1
	}
	result, _ := json.Marshal(map[string]any{"version": 1, "previewId": params.PreviewID, "eventSeq": sequence, "documents": entries})
	fence, _ := json.Marshal(map[string]any{"version": 1, "previewId": params.PreviewID, "eventSeq": sequence})
	if err := server.migrationSnapshotFence(fence); err != nil {
		t.Fatal(err)
	}
	if err := server.finishClientRequest(protocol.Response{ID: request.ID, Result: result}); err != nil {
		t.Fatal(err)
	}
}

func nextMigrationClientEdit(t *testing.T, output *bytes.Buffer) (protocol.Request, []*migrationTextDocumentEdit) {
	t.Helper()
	raw, err := protocol.NewReader(output).Read()
	if err != nil {
		t.Fatal(err)
	}
	request, err := protocol.DecodeRequest(raw)
	if err != nil || request.Method != "tesl/migrationApplyEdit" {
		t.Fatalf("expected client edit: %s %v", raw, err)
	}
	var params struct {
		Documents []struct {
			URI                     string `json:"uri"`
			Version                 int    `json:"version"`
			Source, OpenID, NewText string
			Range                   protocol.Range `json:"range"`
		} `json:"documents"`
	}
	if err := json.Unmarshal(request.Params, &params); err != nil || len(params.Documents) == 0 {
		t.Fatalf("empty edit: %s %v", raw, err)
	}
	edits := make([]*migrationTextDocumentEdit, 0, len(params.Documents))
	for _, doc := range params.Documents {
		edits = append(edits, migrationVersionedEdit(document{URI: doc.URI, Version: doc.Version}, doc.Range, doc.NewText))
	}
	return request, edits
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

func acknowledgeMigration(t *testing.T, server *Server, output *bytes.Buffer, request protocol.Request, result string) {
	t.Helper()
	if err := server.finishClientRequest(protocol.Response{ID: request.ID, Result: json.RawMessage(result)}); err != nil {
		t.Fatal(err)
	}
	answerMigrationSnapshot(t, server, output)
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
			acknowledgeMigration(t, server, output, request, `{"applied":true}`)
			requests++
		}
		assertMigrationOutcome(t, server, output, "committed", false)
		if server.migrationResult == nil {
			t.Fatal("missing committed result")
		}
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
	for _, scenario := range []string{"cancelled", "dependency changed"} {
		t.Run(scenario, func(t *testing.T) {
			server, output, doc, created := migrationApplicationFixture(t, false)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			startMigrationApplication(t, ctx, server, output)
			request, edits := nextMigrationClientEdit(t, output)
			observeMigrationEdits(t, server, edits)
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
			acknowledgeMigration(t, server, output, request, `{"applied":true}`)
			inverse, changes := nextMigrationClientEdit(t, output)
			observeMigrationEdits(t, server, changes)
			acknowledgeMigration(t, server, output, inverse, `{"applied":true}`)
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
	for _, scenario := range []string{"timeout", "missing update", "invalid reply", "missing snapshot", "user text", "reopened", "closed target opened", "inverse missing update", "inverse refused"} {
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
				acknowledgeMigration(t, server, output, request, `{"applied":true}`)
			case "invalid reply":
				acknowledgeMigration(t, server, output, request, `{"applied":true,"applied":false}`)
			case "missing snapshot":
				if err := server.finishClientRequest(protocol.Response{ID: request.ID, Result: json.RawMessage(`{"applied":false}`)}); err != nil {
					t.Fatal(err)
				}
				if _, err := protocol.NewReader(output).Read(); err != nil {
					t.Fatal(err)
				}
				observeMigrationEdits(t, server, edits[:1])
				if err := server.expireClientRequests(time.Now().Add(time.Minute)); err != nil {
					t.Fatal(err)
				}
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
				if strings.HasPrefix(scenario, "inverse ") {
					// A positive reply with all updates observed, followed by a
					// stale unedited dependency, gives a known state to invert.
					observeMigrationEdits(t, server, edits[1:])
					uri := protocol.PathToURI(filepath.Join(filepath.Dir(doc.Path), "dependency.tesl"))
					dependency := server.documents[uri]
					dependency.Text = "changed dependency"
					dependency.Version++
					server.documents[uri] = dependency
					acknowledgeMigration(t, server, output, request, `{"applied":true}`)
					inverse, _ := nextMigrationClientEdit(t, output)
					if scenario == "inverse refused" {
						acknowledgeMigration(t, server, output, inverse, `{"applied":false}`)
					} else {
						acknowledgeMigration(t, server, output, inverse, `{"applied":true}`)
					}
				} else {
					acknowledgeMigration(t, server, output, request, `{"applied":false}`)
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
			acknowledgeMigration(t, server, output, request, `{"applied":true}`)
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

func TestMigrationApplicationRemainsUnavailableWithoutSnapshotBarrier(t *testing.T) {
	for _, mode := range []string{"transactional", "textOnlyTransactional", "undo", "abort", ""} {
		server, output, _, created := migrationApplicationFixture(t, true)
		capabilities := server.initializeCapabilities(json.RawMessage(`{"capabilities":{"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true,"resourceOperations":["create"],"failureHandling":"` + mode + `"}}}}`))
		encoded, err := json.Marshal(capabilities)
		if err != nil || server.migrationApplySupported || bytes.Contains(encoded, []byte(`"tesl.applyMigration"`)) {
			t.Fatalf("unproven editor apply was advertised: %s %v", encoded, err)
		}
		startMigrationApplication(t, context.Background(), server, output)
		raw, err := protocol.NewReader(output).Read()
		if err != nil {
			t.Fatal(err)
		}
		response, err := protocol.DecodeResponse(raw)
		if err != nil || response.Error == nil || response.Error.Code != -32602 {
			t.Fatalf("unproven editor apply was accepted: %s %v", raw, err)
		}
		if _, err := os.Stat(created); !os.IsNotExist(err) {
			t.Fatal("disabled application published source")
		}
		if _, err := os.Stat(filepath.Join(filepath.Dir(created), ".tesl-source-edit")); !os.IsNotExist(err) {
			t.Fatal("disabled application created a journal")
		}
	}
}

func TestMigrationApplicationRevalidatesCompilerAndReviewedManifestBeforePublication(t *testing.T) {
	for _, change := range []string{"ABI", "manifest", "selection", "family", "revision", "judgment", "compiler failure"} {
		t.Run(change, func(t *testing.T) {
			server, output, doc, created := migrationApplicationFixture(t, true)
			compiler := server.compiler.(*migrationPreviewCompiler)
			if change == "compiler failure" {
				compiler.failure = errors.New("current compiler unavailable")
			} else {
				var envelope map[string]any
				if err := json.Unmarshal(compiler.preview.JSON(), &envelope); err != nil {
					t.Fatal(err)
				}
				switch change {
				case "ABI":
					envelope["compilerAbi"] = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
				case "manifest":
					envelope["manifest"].(map[string]any)["edits"].([]any)[0].(map[string]any)["afterHex"] = hex.EncodeToString([]byte("different compiler proposal"))
				case "selection":
					envelope["selection"].(map[string]any)["database"] = "Other.Main"
				case "family":
					envelope["selection"].(map[string]any)["family"] = "OtherSchema"
				case "revision":
					envelope["selection"].(map[string]any)["revisionAfter"] = 3
				case "judgment":
					envelope["compilable"] = true
					envelope["diagnostics"] = map[string]any{"version": 1, "diagnostics": []any{}}
				}
				raw, _ := json.Marshal(envelope)
				var err error
				compiler.preview, err = sourceedit.DecodePreview(raw)
				if err != nil {
					t.Fatal(err)
				}
			}
			startMigrationApplication(t, context.Background(), server, output)
			raw, err := protocol.NewReader(output).Read()
			if err != nil {
				t.Fatal(err)
			}
			response, err := protocol.DecodeResponse(raw)
			if err != nil || response.Error == nil || response.Error.Code != -32801 || server.migrationApply != nil || server.migrationPreview != nil {
				t.Fatalf("unverified current compiler was accepted: %s %v", raw, err)
			}
			if _, err := os.Stat(created); !os.IsNotExist(err) {
				t.Fatal("compiler revalidation refusal published source")
			}
			if _, err := os.Stat(filepath.Join(filepath.Dir(doc.Path), ".tesl-source-edit")); !os.IsNotExist(err) {
				t.Fatal("compiler revalidation refusal created a transaction")
			}
			if server.documents[doc.URI] != doc {
				t.Fatal("compiler revalidation refusal changed buffer bytes")
			}
		})
	}
}
