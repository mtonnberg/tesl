package lsp

import (
	"encoding/json"
	"fmt"
	"time"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/sourceedit"
)

// The extension flushes its ordered document notifications, then captures a
// complete snapshot in the same event turn as this response. The dispatcher
// consumes that fence after the notifications. An apply acknowledgement alone
// is never evidence of the editor's current text or document lifetime.
func (op *migrationApplyState) snapshot(phase string, complete func() error) error {
	op.fenceSeen = false
	fail := func(err error) error {
		report := sourceedit.Report{Outcome: "unchanged"}
		if op.tx != nil {
			report = op.tx.Report()
		}
		return op.finish(report, err)
	}
	_, err := op.server.sendClientRequest(op.writer, "tesl/migrationSnapshot", map[string]any{
		"version": 1, "previewId": op.state.id, "projectRoot": op.plan.manifest.ProjectRoot(), "phase": phase,
	}, 30*time.Second, func(response protocol.Response, err error) error {
		if err != nil {
			return fail(err)
		}
		if response.Error != nil {
			return fail(fmt.Errorf("editor snapshot failed; retain recovery state"))
		}
		if err := op.acceptSnapshot(response.Result, phase == "before"); err != nil {
			return fail(err)
		}
		op.snapshotFresh = phase != "before"
		return complete()
	})
	if err != nil {
		return fail(err)
	}
	return nil
}

func (op *migrationApplyState) acceptSnapshot(raw json.RawMessage, first bool) error {
	fields, err := clientResponseFields(raw, "version", "previewId", "eventSeq", "documents")
	var version *int
	var previewID *string
	var sequence *uint64
	var entries []json.RawMessage
	if err != nil || json.Unmarshal(fields["version"], &version) != nil || version == nil || *version != 1 ||
		json.Unmarshal(fields["previewId"], &previewID) != nil || previewID == nil || *previewID != op.state.id ||
		json.Unmarshal(fields["eventSeq"], &sequence) != nil || sequence == nil || *sequence > 1<<53-1 || (!first && *sequence < op.eventSeq) || !op.fenceSeen || *sequence != op.fenceSeq ||
		json.Unmarshal(fields["documents"], &entries) != nil || entries == nil {
		return fmt.Errorf("invalid editor snapshot fence; retain recovery state")
	}
	_, current, err := op.server.migrationDocuments(op.plan.manifest.ProjectRoot())
	if err != nil {
		return err
	}
	if len(entries) != len(current) {
		return fmt.Errorf("editor snapshot document set does not match flushed notifications")
	}
	ids := make(map[string]string, len(entries))
	seenIDs := make(map[string]bool, len(entries))
	for _, raw := range entries {
		fields, err := clientResponseFields(raw, "uri", "version", "source", "openId")
		var uri, text, openID *string
		var version *int32
		if err != nil || json.Unmarshal(fields["uri"], &uri) != nil || uri == nil ||
			json.Unmarshal(fields["version"], &version) != nil || version == nil ||
			json.Unmarshal(fields["source"], &text) != nil || text == nil || !utf8.ValidString(*text) ||
			json.Unmarshal(fields["openId"], &openID) != nil || openID == nil || *openID == "" || len(*openID) > 128 {
			return fmt.Errorf("invalid editor document snapshot")
		}
		path, err := protocol.URIToPath(*uri)
		doc, exists := current[path]
		if err != nil || !exists || doc.URI != *uri || doc.Version != int(*version) || doc.Text != *text || ids[path] != "" || seenIDs[*openID] {
			return fmt.Errorf("editor snapshot does not match flushed document notifications")
		}
		if !first && op.clientOpenIDs[path] != "" && op.clientOpenIDs[path] != *openID {
			return fmt.Errorf("editor document closed or reopened; preserve its current contents: %s", path)
		}
		ids[path], seenIDs[*openID] = *openID, true
	}
	if first {
		op.clientOpenIDs = ids
	} else if *sequence == op.eventSeq {
		changed := len(current) != len(op.clientDocuments)
		for path, doc := range current {
			if previous, exists := op.clientDocuments[path]; !exists || previous != doc {
				changed = true
			}
		}
		if changed {
			return fmt.Errorf("editor event sequence did not advance with document changes")
		}
	}
	op.clientDocuments = current
	op.eventSeq = *sequence
	return nil
}

// vscode-languageclient flushes pending full-text changes before writing this
// custom notification. It crosses the same ordered queue as those changes and
// the subsequent snapshot reply; no compiler query or thread reads buffers here.
func (server *Server) migrationSnapshotFence(raw json.RawMessage) error {
	fields, err := clientResponseFields(raw, "version", "previewId", "eventSeq")
	var version *int
	var id *string
	var seq *uint64
	if err != nil || json.Unmarshal(fields["version"], &version) != nil || version == nil || *version != 1 ||
		json.Unmarshal(fields["previewId"], &id) != nil || id == nil ||
		json.Unmarshal(fields["eventSeq"], &seq) != nil || seq == nil || *seq > 1<<53-1 {
		return fmt.Errorf("invalid editor snapshot fence")
	}
	if op := server.migrationApply; op != nil && op.state.id == *id && *seq >= op.eventSeq {
		op.fenceSeq, op.fenceSeen = *seq, true
	}
	return nil
}
