package lsp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/sourceedit"
)

// The dispatcher owns this continuation and the source journal throughout every
// client request. It never saves an open buffer through the filesystem.
type migrationApplyState struct {
	server          *Server
	state           *migrationPreviewState
	plan            *migrationEditPlan
	tx              *sourceedit.EditorTransaction
	ctx             context.Context
	id              json.RawMessage
	writer          *protocol.Writer
	next            int
	written         []string
	restored        []string
	clientOpenIDs   map[string]string
	clientDocuments map[string]document
	eventSeq        uint64
	fenceSeq        uint64
	fenceSeen       bool
	snapshotFresh   bool
}

type migrationApplicationResult struct {
	Version           int               `json:"version"`
	Kind              string            `json:"kind"`
	PreviewID         string            `json:"previewId"`
	OK                bool              `json:"ok"`
	Compilable        bool              `json:"compilable"`
	Active            bool              `json:"active"`
	SourceTransaction sourceedit.Report `json:"sourceTransaction"`
	BuffersWritten    []string          `json:"buffersWritten"`
	BuffersRestored   []string          `json:"buffersRestored"`
	Error             string            `json:"error,omitempty"`
}

func migrationPreviewID(raw json.RawMessage) (string, error) {
	fields, err := clientResponseFields(raw, "previewId")
	var id string
	if err != nil || json.Unmarshal(fields["previewId"], &id) != nil || id == "" {
		return "", fmt.Errorf("migration application requires one previewId")
	}
	return id, nil
}

func (server *Server) writeMigrationApply(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	previewID, err := migrationPreviewID(raw)
	if err != nil {
		return server.writeError(writer, id, -32602, err.Error())
	}
	if !server.migrationApplySupported {
		return server.writeError(writer, id, -32602, "migration application requires the checked Tesl editor snapshot protocol")
	}
	if server.migrationApply != nil {
		return server.writeError(writer, id, -32602, "migration application is still active")
	}
	state := server.migrationPreview
	if state == nil || state.id != previewID {
		return server.writeError(writer, id, -32602, "migration preview expired; request a fresh preview")
	}
	plan, err := server.prepareMigrationEdits(state)
	if err != nil {
		return server.writeError(writer, id, -32801, err.Error())
	}
	// Re-run the same compiler-owned selection immediately before application.
	// This checks the running compiler ABI as well as all source/selection guards;
	// the reviewed immutable manifest remains the only filesystem write authority.
	documents, _, err := server.migrationDocuments(plan.manifest.ProjectRoot())
	if err != nil {
		return server.writeError(writer, id, -32801, err.Error())
	}
	compiler, supported := server.compiler.(migrationCompiler)
	if !supported {
		return server.writeError(writer, id, -32801, "compiler cannot revalidate the reviewed migration proposal")
	}
	verified, _, err := compiler.QueryMigrationPreview(ctx, state.selection, documents)
	if err != nil || verified == nil || verified.CompilerABI() != state.preview.CompilerABI() || verified.Manifest().Digest() != state.preview.Manifest().Digest() ||
		verified.EntryFile() != state.preview.EntryFile() || verified.Database() != state.preview.Database() || verified.Operation() != state.preview.Operation() || verified.Compilable() != state.preview.Compilable() {
		server.migrationPreview = nil
		return server.writeError(writer, id, -32801, "compiler or migration inputs changed after review; request a fresh migration preview")
	}
	if !migrationSameCompilerSelection(state.preview, verified) {
		server.migrationPreview = nil
		return server.writeError(writer, id, -32801, "compiler migration family or revision changed after review; request a fresh migration preview")
	}
	op := &migrationApplyState{server: server, state: state, plan: plan, ctx: ctx, id: append(json.RawMessage{}, id...), writer: writer}
	if err := op.preflight(); err != nil {
		return server.writeError(writer, id, -32602, err.Error())
	}
	server.migrationApply = op
	server.requests.deferResponse(id)
	return op.snapshot("before", func() error { return op.prepare() })
}

func migrationSameCompilerSelection(before, after *sourceedit.Preview) bool {
	selection := func(preview *sourceedit.Preview) (string, error) {
		var envelope struct {
			Selection any `json:"selection"`
		}
		if err := json.Unmarshal(preview.JSON(), &envelope); err != nil {
			return "", err
		}
		raw, err := json.Marshal(envelope.Selection)
		return string(raw), err
	}
	left, err := selection(before)
	if err != nil {
		return false
	}
	right, err := selection(after)
	return err == nil && left == right
}

func (op *migrationApplyState) prepare() error {
	documents, err := op.documents(false)
	if err != nil {
		return op.finish(sourceedit.Report{Outcome: "unchanged"}, err)
	}
	tx, report, err := op.plan.manifest.PrepareEditor(op.ctx, documents)
	op.server.migrationPreview = nil // One reviewed proposal authorizes one attempt.
	op.server.migrationResult = nil
	if err != nil {
		return op.finish(report, err)
	}
	if tx == nil {
		return op.finish(report, fmt.Errorf("source preparation returned no transaction"))
	}
	op.tx = tx
	if report, err = tx.Publish(op.ctx); err != nil {
		return op.abort(err)
	}
	if len(op.plan.open) == 0 {
		// Publishing may take time. Even a proposal with only closed edits needs
		// another client fence before those files can become committed.
		if report, err := tx.BeginClientObservation(op.ctx); err != nil {
			return op.finish(report, err)
		}
		return op.snapshot("afterApply", func() error { return op.forward() })
	}
	if report, err = tx.BeginClientEdits(op.ctx); err != nil {
		if report.Outcome == "editor-pending" {
			return op.finish(report, err)
		}
		return op.abort(err)
	}
	return op.forward()
}

// Before commit, every original input must still be present in the same editor
// lifetime. During inverse, unrelated user buffer changes are allowed, but a
// closed target opened during publication must never be rolled back underneath it.
func (op *migrationApplyState) documents(inverse bool) ([]sourceedit.EditorDocument, error) {
	current, snapshots, err := op.server.migrationDocuments(op.plan.manifest.ProjectRoot())
	if err != nil {
		return nil, err
	}
	for _, path := range op.plan.closed {
		if _, opened := snapshots[path]; opened {
			return nil, fmt.Errorf("published source was opened during application; preserve it for recovery: %s", path)
		}
	}
	if !inverse && len(snapshots) != len(op.state.documents) {
		return nil, fmt.Errorf("open migration inputs changed during application")
	}
	for path, before := range op.state.documents {
		if inverse {
			edited := false
			for _, edit := range op.plan.open {
				edited = edited || edit.before.Path == path
			}
			if !edited {
				continue
			}
		}
		after, exists := snapshots[path]
		if !exists || before.URI != after.URI || before.openID != after.openID {
			return nil, fmt.Errorf("migration input closed or reopened: %s", path)
		}
		if !inverse {
			expected := before
			for i, edit := range op.plan.open {
				if i < op.next && edit.before.Path == path && after.Version > before.Version {
					expected.Text, expected.Version = edit.after, after.Version
				}
			}
			if after != expected {
				return nil, fmt.Errorf("migration input changed during application: %s", path)
			}
		}
	}
	documents := make([]sourceedit.EditorDocument, 0, len(current))
	for _, doc := range current {
		documents = append(documents, sourceedit.EditorDocument{Path: doc.Path, Version: doc.Version, Source: doc.Source})
	}
	return documents, nil
}

func (op *migrationApplyState) preflight() error {
	if op.server.clientClosed || op.server.shutdown || len(op.server.clientRequests) >= maxClientRequests {
		return fmt.Errorf("editor cannot accept migration requests")
	}
	check := func(edits []*migrationTextDocumentEdit, inverse bool) error {
		documents := make([]map[string]any, 0, len(edits))
		for _, edit := range edits {
			doc := op.server.documents[edit.TextDocument.URI]
			source := doc.Text
			if inverse {
				for _, candidate := range op.plan.open {
					if candidate.before.URI == doc.URI {
						source = candidate.after
					}
				}
			}
			documents = append(documents, map[string]any{"uri": doc.URI, "version": 2147483647, "source": source, "openId": strings.Repeat("x", 128), "newText": edit.Edits[0].NewText, "range": edit.Edits[0].Range})
		}
		// Reserve the largest request id and label, including inverse requests.
		raw, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": "tesl-client-18446744073709551615",
			"method": "tesl/migrationApplyEdit", "params": map[string]any{"version": 1, "previewId": op.state.id, "label": "Restore Tesl migration source", "documents": documents}})
		if err != nil || len(raw) > protocol.DefaultMaxMessageBytes/2 {
			return fmt.Errorf("migration buffer edits exceed the editor message limit")
		}
		return nil
	}
	var batch []*migrationTextDocumentEdit
	for _, edit := range op.plan.open {
		forward, err := edit.forward(edit.before)
		if err != nil {
			return err
		}
		if err := check([]*migrationTextDocumentEdit{forward}, false); err != nil {
			return err
		}
		inverse := migrationVersionedEdit(edit.before, edit.inverseRange, edit.before.Text)
		inverse.TextDocument.Version = 2147483647
		if err := check([]*migrationTextDocumentEdit{inverse}, true); err != nil {
			return err
		}
		batch = append(batch, forward)
	}
	if op.server.migrationBatchEdits {
		if err := check(batch, false); err != nil {
			return err
		}
	}
	for _, applied := range []bool{false, true} {
		entries := make([]map[string]any, 0, len(op.state.documents))
		for _, doc := range op.state.documents {
			source := doc.Text
			if applied {
				for _, edit := range op.plan.open {
					if edit.before.URI == doc.URI {
						source = edit.after
					}
				}
			}
			entries = append(entries, map[string]any{"uri": doc.URI, "version": 2147483647, "source": source, "openId": strings.Repeat("x", 128)})
		}
		raw, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": "tesl-client-18446744073709551615", "result": map[string]any{"version": 1, "previewId": op.state.id, "eventSeq": 9007199254740991, "documents": entries}})
		if err != nil || len(raw) > protocol.DefaultMaxMessageBytes/2 {
			return fmt.Errorf("migration snapshots exceed the editor message limit")
		}
	}
	return nil
}

func (op *migrationApplyState) forward() error {
	if err := op.ctx.Err(); err != nil {
		return op.inverse(err)
	}
	if op.next == len(op.plan.open) {
		documents, err := op.documents(false)
		if err != nil {
			return op.inverse(err)
		}
		report, err := op.tx.Commit(op.ctx, documents)
		if err != nil && report.Outcome != "committed" {
			return op.inverse(err)
		}
		return op.finish(report, err)
	}
	if _, err := op.documents(false); err != nil {
		return op.inverse(err)
	}
	last := op.next + 1
	if op.server.migrationBatchEdits {
		last = len(op.plan.open)
	}
	batch := op.plan.open[op.next:last]
	edits := make([]*migrationTextDocumentEdit, 0, len(batch))
	for _, edit := range batch {
		forward, err := edit.forward(op.server.documents[edit.before.URI])
		if err != nil {
			return op.inverse(err)
		}
		edits = append(edits, forward)
	}
	return op.send(edits, false, func(applied bool, failure error) error {
		return op.snapshot("afterApply", func() error {
			if !applied {
				return op.inverse(failure)
			}
			for _, edit := range batch {
				after := op.server.documents[edit.before.URI]
				if after.Path != edit.before.Path || after.openID != edit.before.openID || after.Text != edit.after || after.Version <= edit.before.Version {
					return op.finish(op.tx.Report(), fmt.Errorf("editor acknowledged an edit without its expected document update; outcome needs reconciliation: %s", edit.before.Path))
				}
				op.written = append(op.written, edit.before.Path)
			}
			op.next = last
			return op.forward()
		})
	})
}

func migrationApplyAcknowledgement(response protocol.Response) (bool, error) {
	if response.Error != nil {
		return false, fmt.Errorf("editor returned an RPC error; application outcome needs reconciliation")
	}
	fields, err := clientResponseFields(response.Result, "applied", "failureReason", "failedChange")
	var applied *bool
	if err != nil || json.Unmarshal(fields["applied"], &applied) != nil || applied == nil {
		return false, fmt.Errorf("editor returned an invalid applyEdit acknowledgement")
	}
	if reason, exists := fields["failureReason"]; exists {
		var value *string
		if json.Unmarshal(reason, &value) != nil || value == nil {
			return false, fmt.Errorf("editor returned an invalid applyEdit failure reason")
		}
	}
	if index, exists := fields["failedChange"]; exists {
		var value *uint32
		if json.Unmarshal(index, &value) != nil || value == nil || *applied {
			return false, fmt.Errorf("editor returned an invalid failed edit index")
		}
	}
	return *applied, nil
}

func (op *migrationApplyState) send(edits []*migrationTextDocumentEdit, inverse bool, complete func(bool, error) error) error {
	op.snapshotFresh = false
	label := "Apply Tesl migration source"
	if inverse {
		label = "Restore Tesl migration source"
	}
	documents := make([]map[string]any, 0, len(edits))
	for _, edit := range edits {
		doc, exists := op.server.documents[edit.TextDocument.URI]
		if !exists || doc.Version != edit.TextDocument.Version || len(edit.Edits) != 1 {
			return op.finish(op.tx.Report(), fmt.Errorf("migration preimage is unavailable"))
		}
		documents = append(documents, map[string]any{"uri": doc.URI, "version": doc.Version, "source": doc.Text,
			"openId": op.clientOpenIDs[doc.Path], "newText": edit.Edits[0].NewText, "range": edit.Edits[0].Range})
	}
	_, err := op.server.sendClientRequest(op.writer, "tesl/migrationApplyEdit", map[string]any{
		"version": 1, "previewId": op.state.id, "label": label, "documents": documents,
	}, 30*time.Second, func(response protocol.Response, err error) error {
		if err != nil {
			return op.finish(op.tx.Report(), err)
		}
		applied, err := migrationApplyAcknowledgement(response)
		if err != nil {
			return op.finish(op.tx.Report(), err)
		}
		if !applied {
			err = fmt.Errorf("editor refused migration buffer edits")
		}
		return complete(applied, err)
	})
	if err != nil {
		return op.finish(op.tx.Report(), err)
	}
	return nil
}

func (op *migrationApplyState) inverse(cause error) error {
	if !op.snapshotFresh {
		return op.snapshot("afterApply", func() error { return op.inverse(cause) })
	}
	if _, err := op.documents(true); err != nil {
		return op.finish(op.tx.Report(), errors.Join(cause, err))
	}
	// Inspect all targets, including a partially applied failed batch. Guard each
	// inverse against its actual post-edit version; never overwrite newer user text.
	for i := len(op.plan.open) - 1; i >= 0; i-- {
		edit := op.plan.open[i]
		inverse, err := edit.inverse(op.server.documents[edit.before.URI])
		if err != nil {
			return op.finish(op.tx.Report(), errors.Join(cause, err))
		}
		if inverse == nil {
			continue
		}
		found := false
		for _, path := range op.written {
			found = found || path == edit.before.Path
		}
		if !found {
			op.written = append(op.written, edit.before.Path)
		}
		return op.send([]*migrationTextDocumentEdit{inverse}, true, func(applied bool, failure error) error {
			return op.snapshot("afterRestore", func() error {
				if !applied {
					return op.finish(op.tx.Report(), errors.Join(cause, failure))
				}
				after := op.server.documents[edit.before.URI]
				if after.openID != edit.before.openID || after.Path != edit.before.Path || after.Text != edit.before.Text || after.Version <= inverse.TextDocument.Version {
					return op.finish(op.tx.Report(), errors.Join(cause, fmt.Errorf("restored buffer update was not observed; retain recovery state")))
				}
				op.restored = append(op.restored, edit.before.Path)
				return op.inverse(cause)
			})
		})
	}
	documents, err := op.documents(true)
	if err != nil {
		return op.finish(op.tx.Report(), errors.Join(cause, err))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	report, err := op.tx.Restore(ctx, documents)
	return op.finish(report, errors.Join(cause, err))
}

func (op *migrationApplyState) abort(cause error) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	report, err := op.tx.Abort(ctx)
	return op.finish(report, errors.Join(cause, err))
}

func (op *migrationApplyState) result(report sourceedit.Report, active bool, err error) migrationApplicationResult {
	result := migrationApplicationResult{Version: 1, Kind: "migration-editor-application", PreviewID: op.state.id,
		OK: !active && err == nil && report.Outcome == "committed", Active: active,
		Compilable: op.state.preview.Compilable(), SourceTransaction: report,
		BuffersWritten: append([]string{}, op.written...), BuffersRestored: append([]string{}, op.restored...)}
	if err != nil {
		result.Error = err.Error()
	}
	return result
}

func (op *migrationApplyState) finish(report sourceedit.Report, err error) error {
	if op.tx != nil {
		err = errors.Join(err, op.tx.Close())
		report = op.tx.Report()
	}
	result := op.result(report, false, err)
	op.server.migrationApply = nil
	op.server.migrationResult = &result
	op.server.fileChangeVersion++
	if op.server.clientClosed {
		return nil
	}
	// A cancelled executeCommand still has a retrievable operation result; its
	// cancellation response must not imply that already committed files reverted.
	return op.server.writeResult(op.writer, op.id, result)
}

func (server *Server) writeMigrationApplicationStatus(id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	previewID, err := migrationPreviewID(raw)
	if err != nil {
		return server.writeError(writer, id, -32602, err.Error())
	}
	if op := server.migrationApply; op != nil && op.state.id == previewID {
		report := sourceedit.Report{Outcome: "unchanged"}
		if op.tx != nil {
			report = op.tx.Report()
		}
		return server.writeResult(writer, id, op.result(report, true, nil))
	}
	if result := server.migrationResult; result != nil && result.PreviewID == previewID {
		return server.writeResult(writer, id, result)
	}
	return server.writeError(writer, id, -32602, "migration application result expired or unavailable")
}
