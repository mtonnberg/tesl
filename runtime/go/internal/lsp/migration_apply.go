package lsp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/sourceedit"
)

// The dispatcher owns this continuation and the source journal throughout every
// client request. It never saves an open buffer through the filesystem.
type migrationApplyState struct {
	server   *Server
	state    *migrationPreviewState
	plan     *migrationEditPlan
	tx       *sourceedit.EditorTransaction
	ctx      context.Context
	id       json.RawMessage
	writer   *protocol.Writer
	next     int
	written  []string
	restored []string
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
		return server.writeError(writer, id, -32602, "migration application requires applyEdit, versioned documentChanges and create support")
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
	op := &migrationApplyState{server: server, state: state, plan: plan, ctx: ctx, id: append(json.RawMessage{}, id...), writer: writer}
	if err := op.preflight(); err != nil {
		return server.writeError(writer, id, -32602, err.Error())
	}
	documents, err := op.documents(false)
	if err != nil {
		return server.writeError(writer, id, -32801, err.Error())
	}
	tx, report, err := plan.manifest.PrepareEditor(ctx, documents)
	server.migrationPreview = nil // One reviewed proposal authorizes one attempt.
	server.migrationResult = nil
	if err != nil {
		return op.finish(report, err)
	}
	op.tx = tx
	server.migrationApply = op
	if report, err = tx.Publish(ctx); err != nil {
		return op.abort(err)
	}
	if len(plan.open) == 0 {
		report, err = tx.CommitWithoutClient(ctx, documents)
		if err != nil && report.Outcome != "committed" {
			return op.abort(err)
		}
		return op.finish(report, err)
	}
	if report, err = tx.BeginClientEdits(ctx); err != nil {
		if report.Outcome == "editor-pending" {
			return op.finish(report, err)
		}
		return op.abort(err)
	}
	server.requests.deferResponse(id)
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
	check := func(edits []*migrationTextDocumentEdit) error {
		// Reserve the largest request id and label, including inverse requests.
		raw, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": "tesl-client-18446744073709551615",
			"method": "workspace/applyEdit", "params": map[string]any{"label": "Restore Tesl migration source",
				"edit": map[string]any{"documentChanges": edits}}})
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
		if err := check([]*migrationTextDocumentEdit{forward}); err != nil {
			return err
		}
		inverse := migrationVersionedEdit(edit.before, edit.inverseRange, edit.before.Text)
		inverse.TextDocument.Version = 2147483647
		if err := check([]*migrationTextDocumentEdit{inverse}); err != nil {
			return err
		}
		batch = append(batch, forward)
	}
	if op.server.migrationBatchEdits {
		return check(batch)
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
	label := "Apply Tesl migration source"
	if inverse {
		label = "Restore Tesl migration source"
	}
	_, err := op.server.sendClientRequest(op.writer, "workspace/applyEdit", map[string]any{
		"label": label, "edit": map[string]any{"documentChanges": edits},
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
		return server.writeResult(writer, id, op.result(op.tx.Report(), true, nil))
	}
	if result := server.migrationResult; result != nil && result.PreviewID == previewID {
		return server.writeResult(writer, id, result)
	}
	return server.writeError(writer, id, -32602, "migration application result expired or unavailable")
}
