package lsp

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/sourceedit"
	"tesl.dev/runtime/go/internal/tooling"
)

type migrationCompiler interface {
	QueryMigrationPreview(context.Context, tooling.MigrationSelection, []tooling.MigrationDocument) (*sourceedit.Preview, tooling.Result, error)
}

// Keep one bounded compiler preview per editor session. Starting another preview
// expires the previous handle, including when the newer request fails or cancels.
type migrationPreviewState struct {
	id        string
	preview   *sourceedit.Preview
	documents map[string]document
}

func (server *Server) writeMigrationCommand(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params struct {
		Command   string            `json:"command"`
		Arguments []json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(raw, &params); err != nil {
		return server.writeError(writer, id, -32602, "invalid workspace command")
	}
	if params.Command == "tesl.generateMigration" {
		server.migrationPreview = nil
	}
	if len(params.Arguments) != 1 {
		return server.writeError(writer, id, -32602, "migration commands require one selection argument")
	}
	switch params.Command {
	case "tesl.generateMigration":
		return server.writeMigrationPreview(ctx, id, params.Arguments[0], writer)
	case "tesl.migrationPreviewFile":
		return server.writeMigrationPreviewFile(id, params.Arguments[0], writer)
	default:
		return server.writeError(writer, id, -32602, "unsupported workspace command")
	}
}

func (server *Server) writeMigrationPreview(ctx context.Context, id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	server.migrationPreview = nil
	compiler, supported := server.compiler.(migrationCompiler)
	if !supported {
		return server.writeError(writer, id, -32602, "compiler does not support guarded migration previews")
	}
	var params struct {
		EntryFile   string `json:"entryFile"`
		ProjectRoot string `json:"projectRoot"`
		Database    string `json:"database"`
		NewRevision bool   `json:"newRevision"`
	}
	if err := json.Unmarshal(raw, &params); err != nil || params.EntryFile == "" || params.ProjectRoot == "" {
		return server.writeError(writer, id, -32602, "migration preview requires entryFile and projectRoot")
	}
	selection := tooling.MigrationSelection{EntryFile: params.EntryFile, ProjectRoot: params.ProjectRoot, Database: params.Database, NewRevision: params.NewRevision}
	documents, snapshots, err := server.migrationDocuments(selection.ProjectRoot)
	if err != nil {
		return server.writeError(writer, id, -32602, err.Error())
	}
	preview, result, err := compiler.QueryMigrationPreview(ctx, selection, documents)
	if err != nil {
		// Preserve the compiler's refusal and candidate list for the UI; it is
		// diagnostic data only and can never populate the retained preview.
		var refusal struct {
			Version int               `json:"version"`
			Kind    string            `json:"kind"`
			OK      *bool             `json:"ok"`
			Errors  []json.RawMessage `json:"errors"`
		}
		if len(result.Stdout) < protocol.DefaultMaxMessageBytes/2 && json.Unmarshal(result.Stdout, &refusal) == nil &&
			refusal.Version == 1 && refusal.Kind == "migration-source-preview" && refusal.OK != nil && !*refusal.OK && len(refusal.Errors) > 0 {
			return server.writeResult(writer, id, map[string]any{"version": 1, "kind": "migration-editor-preview", "ok": false, "errors": refusal.Errors})
		}
		return err
	}
	if preview == nil {
		return fmt.Errorf("compiler returned no migration preview")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return err
	}
	handle := hex.EncodeToString(nonce[:])
	// Source diagnostics are about the proposed files. Keep their original
	// logical paths, including files that have not been created on disk.
	var envelope struct {
		Diagnostics json.RawMessage `json:"diagnostics"`
	}
	if err := json.Unmarshal(preview.JSON(), &envelope); err != nil {
		return err
	}
	response := map[string]any{"version": 1, "kind": "migration-editor-preview", "ok": true, "previewId": handle,
		"database": preview.Database(), "entryFile": preview.EntryFile(), "operation": preview.Operation(), "compilable": preview.Compilable(),
		"files": preview.Manifest().FileEdits(), "diagnostics": envelope.Diagnostics}
	encoded, err := json.Marshal(response)
	if err != nil {
		return err
	}
	if len(encoded) > protocol.DefaultMaxMessageBytes/2 {
		return fmt.Errorf("migration preview summary exceeds the editor message limit")
	}
	server.migrationPreview = &migrationPreviewState{id: handle, preview: preview, documents: snapshots}
	if err := server.writeResult(writer, id, json.RawMessage(encoded)); err != nil {
		server.migrationPreview = nil
		return err
	}
	if ctx.Err() != nil {
		server.migrationPreview = nil
	}
	return nil
}

func (server *Server) migrationDocuments(root string) ([]tooling.MigrationDocument, map[string]document, error) {
	var documents []tooling.MigrationDocument
	snapshots := make(map[string]document)
	for _, doc := range server.documents {
		if !strings.EqualFold(filepath.Ext(doc.Path), ".tesl") {
			continue
		}
		rel, err := filepath.Rel(root, doc.Path)
		if err != nil || !filepath.IsLocal(rel) {
			continue
		}
		if doc.Version < math.MinInt32 || doc.Version > math.MaxInt32 {
			return nil, nil, fmt.Errorf("migration buffer version exceeds the LSP integer range")
		}
		if _, exists := snapshots[doc.Path]; exists {
			return nil, nil, fmt.Errorf("multiple open documents name the same migration source")
		}
		snapshots[doc.Path] = doc
		documents = append(documents, tooling.MigrationDocument{Path: doc.Path, Version: int32(doc.Version), Source: doc.Text})
	}
	sort.Slice(documents, func(i, j int) bool { return documents[i].Path < documents[j].Path })
	return documents, snapshots, nil
}

func (server *Server) writeMigrationPreviewFile(id json.RawMessage, raw json.RawMessage, writer *protocol.Writer) error {
	var params struct {
		PreviewID string `json:"previewId"`
		Path      string `json:"path"`
	}
	if err := json.Unmarshal(raw, &params); err != nil || server.migrationPreview == nil || params.PreviewID != server.migrationPreview.id {
		return server.writeError(writer, id, -32602, "migration preview expired; request a fresh preview")
	}
	before, after, found := server.migrationPreview.preview.Manifest().FileContents(params.Path)
	if !found {
		return server.writeError(writer, id, -32602, "file is not part of this migration preview")
	}
	if !utf8.Valid(before) || !utf8.Valid(after) {
		return fmt.Errorf("migration preview file is not UTF-8")
	}
	if len(before)+len(after) > protocol.DefaultMaxMessageBytes/2 {
		return fmt.Errorf("migration file diff exceeds the editor message limit")
	}
	response, err := json.Marshal(map[string]any{"version": 1, "kind": "migration-editor-file", "path": params.Path, "before": string(before), "after": string(after)})
	if err != nil {
		return err
	}
	if len(response) > protocol.DefaultMaxMessageBytes/2 {
		return fmt.Errorf("migration file diff exceeds the editor message limit")
	}
	return server.writeResult(writer, id, json.RawMessage(response))
}
