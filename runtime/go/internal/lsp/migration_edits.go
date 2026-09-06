package lsp

import (
	"fmt"
	"math"
	"strings"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/sourceedit"
)

// Planning is read-only. The original manifest remains the sole filesystem
// authority; no document/version guards are removed to make it a saved-file
// manifest. The later coordinator must hold its journal while applying buffers.
type migrationEditPlan struct {
	manifest *sourceedit.Manifest
	open     []migrationBufferEdit
	closed   []string
}

type migrationBufferEdit struct {
	before       document
	after        string
	forwardRange protocol.Range
	inverseRange protocol.Range
}

type migrationTextDocumentEdit struct {
	TextDocument struct {
		URI     string `json:"uri"`
		Version int    `json:"version"`
	} `json:"textDocument"`
	Edits []migrationTextEdit `json:"edits"`
}

type migrationTextEdit struct {
	Range   protocol.Range `json:"range"`
	NewText string         `json:"newText"`
}

func (server *Server) prepareMigrationEdits(state *migrationPreviewState) (*migrationEditPlan, error) {
	if state == nil || state.preview == nil {
		return nil, fmt.Errorf("migration preview expired; request a fresh preview")
	}
	manifest := state.preview.Manifest()
	documents, current, err := server.migrationDocuments(manifest.ProjectRoot())
	if err != nil {
		return nil, err
	}
	if len(documents) != len(manifest.DocumentVersions()) || len(current) != len(state.documents) {
		return nil, fmt.Errorf("open migration documents changed; request a fresh preview")
	}
	for _, doc := range documents {
		original, exists := state.documents[doc.Path]
		if !exists || original.openID != current[doc.Path].openID || original.URI != current[doc.Path].URI ||
			!manifest.MatchesDocument(doc.Path, doc.Version, doc.Source) {
			return nil, fmt.Errorf("migration source changed since preview: %s", doc.Path)
		}
	}
	plan := &migrationEditPlan{manifest: manifest}
	for _, file := range manifest.FileEdits() {
		if file.DocumentVersion == nil {
			plan.closed = append(plan.closed, file.Path)
			continue
		}
		doc, exists := current[file.Path]
		if !exists || doc.Version == math.MaxInt32 {
			return nil, fmt.Errorf("migration document cannot accept a versioned edit: %s", file.Path)
		}
		before, after, found := manifest.FileContents(file.Path)
		if !found || string(before) != doc.Text {
			return nil, fmt.Errorf("migration edit preimage differs from the open document: %s", file.Path)
		}
		forward, err := migrationDocumentRange(doc.Text)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", file.Path, err)
		}
		inverse, err := migrationDocumentRange(string(after))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", file.Path, err)
		}
		plan.open = append(plan.open, migrationBufferEdit{before: doc, after: string(after), forwardRange: forward, inverseRange: inverse})
	}
	return plan, nil
}

func migrationDocumentRange(source string) (protocol.Range, error) {
	if !utf8.ValidString(source) {
		return protocol.Range{}, fmt.Errorf("migration buffer is not UTF-8")
	}
	// The shared source index models LF and CRLF. Refuse bare CR instead of
	// relying on a client's position clamping and risking a partial replacement.
	if strings.Contains(strings.ReplaceAll(source, "\r\n", ""), "\r") {
		return protocol.Range{}, fmt.Errorf("migration buffer edits require LF or CRLF line endings")
	}
	index := protocol.NewLineIndex(source)
	end, err := index.Position(len(source))
	if err != nil {
		return protocol.Range{}, err
	}
	if offset, err := index.Offset(end); err != nil || offset != len(source) {
		return protocol.Range{}, fmt.Errorf("migration edit range does not cover the complete buffer")
	}
	return protocol.Range{End: end}, nil
}

func (edit migrationBufferEdit) forward(current document) (*migrationTextDocumentEdit, error) {
	if current != edit.before {
		return nil, fmt.Errorf("migration buffer changed before application: %s", edit.before.Path)
	}
	return migrationVersionedEdit(current, edit.forwardRange, edit.after), nil
}

func (edit migrationBufferEdit) inverse(current document) (*migrationTextDocumentEdit, error) {
	if current.URI != edit.before.URI || current.Path != edit.before.Path || current.openID != edit.before.openID {
		return nil, fmt.Errorf("migration buffer closed or reopened before restoration: %s", edit.before.Path)
	}
	if current.Text == edit.before.Text {
		return nil, nil // Already restored; leave subsequent editor versions alone.
	}
	if current.Text != edit.after || current.Version <= edit.before.Version || current.Version >= math.MaxInt32 {
		return nil, fmt.Errorf("migration buffer changed; preserve its contents for recovery: %s", edit.before.Path)
	}
	return migrationVersionedEdit(current, edit.inverseRange, edit.before.Text), nil
}

func migrationVersionedEdit(doc document, span protocol.Range, text string) *migrationTextDocumentEdit {
	edit := &migrationTextDocumentEdit{Edits: []migrationTextEdit{{Range: span, NewText: text}}}
	edit.TextDocument.URI = doc.URI
	edit.TextDocument.Version = doc.Version
	return edit
}
