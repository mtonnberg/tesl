package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/protocol"
)

func (server *Server) initializeCapabilities(raw json.RawMessage) map[string]any {
	var params struct {
		Capabilities struct {
			Workspace struct {
				WorkspaceEdit struct {
					DocumentChanges bool `json:"documentChanges"`
				} `json:"workspaceEdit"`
			} `json:"workspace"`
		} `json:"capabilities"`
	}
	server.documentChanges = json.Unmarshal(raw, &params) == nil && params.Capabilities.Workspace.WorkspaceEdit.DocumentChanges
	result := initializeResult()
	if server.documentChanges {
		capabilities := result["capabilities"].(map[string]any)
		capabilities["codeActionProvider"] = map[string]any{"codeActionKinds": []string{"quickfix", "source.fixAll.tesl"}}
	}
	if _, supported := server.compiler.(migrationCompiler); supported {
		result["capabilities"].(map[string]any)["executeCommandProvider"] = map[string]any{"commands": []string{"tesl.generateMigration", "tesl.migrationPreviewFile"}}
	}
	return result
}

func codeActionKindRequested(only []string, kind string) bool {
	for _, requested := range only {
		if requested == kind || requested != "" && strings.HasPrefix(kind, requested+".") {
			return true
		}
	}
	return false
}

type fixAllEdit struct {
	Range   protocol.Range `json:"range"`
	NewText string         `json:"newText"`
	start   int
	end     int
}

// Fix-all consumes producer eligibility, not diagnostic codes or message text.
// Commands and decisions never enter it. The resulting single-document edit is
// pinned to the buffer version that the compiler checked; clients without that
// capability receive no fix-all action.
func (server *Server) writeFixAll(ctx context.Context, id json.RawMessage, doc document, writer *protocol.Writer) error {
	actions := []map[string]any{}
	if !server.documentChanges || server.compiler == nil {
		return server.writeResult(writer, id, actions)
	}
	groups, err := server.diagnosticsForDocument(ctx, doc)
	if err != nil {
		return err
	}
	var edits []fixAllEdit
	source := fixAllSource{text: doc.Text, lines: strings.Split(doc.Text, "\n"), index: protocol.NewLineIndex(doc.Text)}
	for _, diagnostic := range groups[doc.URI] {
		data, _ := json.Marshal(diagnostic)
		var candidate codeActionDiagnostic
		if err := json.Unmarshal(data, &candidate); err != nil {
			return fmt.Errorf("invalid compiler code action: %w", err)
		}
		guidance := candidate.Data
		if guidance.ActionClass != "mechanical" || !guidance.FixAllEligible || guidance.NeedsConfirmation ||
			(len(guidance.Command) != 0 && !bytes.Equal(bytes.TrimSpace(guidance.Command), []byte("null"))) {
			continue
		}
		parts, err := source.rangeEdits(guidance.Fix, 0)
		if err != nil {
			// A malformed member cannot turn a compound fix into a partial edit.
			continue
		}
		if len(edits)+len(parts) > 256 {
			return server.writeResult(writer, id, actions)
		}
		edits = append(edits, parts...)
	}
	edits, ok := mergeFixAllEdits(edits)
	if ok && len(edits) > 0 {
		actions = append(actions, map[string]any{
			"title": "Apply all safe Tesl fixes", "kind": "source.fixAll.tesl",
			"edit": map[string]any{"documentChanges": []map[string]any{{
				"textDocument": map[string]any{"uri": doc.URI, "version": doc.Version}, "edits": edits,
			}}},
		})
	}
	return server.writeResult(writer, id, actions)
}

// Only explicit ranges participate initially. Legacy whole-line/span edits
// remain individual quick fixes. Every byte coordinate must be a real UTF-8
// boundary; the ordinary LSP clamping rules must not move an automatic edit.
type fixAllSource struct {
	text  string
	lines []string
	index *protocol.LineIndex
}

func (source fixAllSource) rangeEdits(raw json.RawMessage, depth int) ([]fixAllEdit, error) {
	if depth > 8 || len(raw) > 1<<20 {
		return nil, fmt.Errorf("fix-all payload exceeds bounds")
	}
	var fix struct {
		Kind        string            `json:"kind"`
		StartLine   *int              `json:"start_line"`
		StartCol    *int              `json:"start_col"`
		EndLine     *int              `json:"end_line"`
		EndCol      *int              `json:"end_col"`
		Replacement *string           `json:"replacement"`
		Edits       []json.RawMessage `json:"edits"`
	}
	if err := json.Unmarshal(raw, &fix); err != nil {
		return nil, err
	}
	if fix.Kind == "multi" {
		if len(fix.Edits) == 0 || len(fix.Edits) > 256 {
			return nil, fmt.Errorf("invalid compound fix")
		}
		var result []fixAllEdit
		for _, raw := range fix.Edits {
			parts, err := source.rangeEdits(raw, depth+1)
			if err != nil || len(result)+len(parts) > 256 {
				return nil, fmt.Errorf("invalid compound fix member")
			}
			result = append(result, parts...)
		}
		return result, nil
	}
	if fix.Kind != "replace_range" || fix.StartLine == nil || fix.StartCol == nil || fix.EndLine == nil || fix.EndCol == nil || fix.Replacement == nil || !utf8.ValidString(*fix.Replacement) {
		return nil, fmt.Errorf("fix-all requires an explicit replacement range")
	}
	position := func(line, column int) (protocol.Position, int, error) {
		if line < 0 || line >= len(source.lines) || column < 0 {
			return protocol.Position{}, 0, fmt.Errorf("fix-all position is outside the document")
		}
		text := strings.TrimSuffix(source.lines[line], "\r")
		if column > len(text) || !utf8.ValidString(text[:column]) {
			return protocol.Position{}, 0, fmt.Errorf("fix-all column is not a source boundary")
		}
		p := protocol.Position{Line: line, Character: protocol.ByteToUTF16Column(text, column)}
		offset, err := source.index.Offset(p)
		return p, offset, err
	}
	start, from, err := position(*fix.StartLine, *fix.StartCol)
	if err != nil {
		return nil, err
	}
	end, to, err := position(*fix.EndLine, *fix.EndCol)
	if err != nil || to < from {
		return nil, fmt.Errorf("invalid fix-all end position")
	}
	if source.text[from:to] == *fix.Replacement {
		return nil, nil
	}
	return []fixAllEdit{{Range: protocol.Range{Start: start, End: end}, NewText: *fix.Replacement, start: from, end: to}}, nil
}

func mergeFixAllEdits(edits []fixAllEdit) ([]fixAllEdit, bool) {
	if len(edits) > 256 {
		return nil, false
	}
	sort.Slice(edits, func(i, j int) bool {
		if edits[i].start != edits[j].start {
			return edits[i].start < edits[j].start
		}
		if edits[i].end != edits[j].end {
			return edits[i].end < edits[j].end
		}
		return edits[i].NewText < edits[j].NewText
	})
	var result []fixAllEdit
	for _, edit := range edits {
		if len(result) > 0 {
			previous := result[len(result)-1]
			if previous.start == edit.start && previous.end == edit.end && previous.NewText == edit.NewText {
				continue
			}
			if previous.end > edit.start || previous.end == edit.start && (previous.start == previous.end || edit.start == edit.end) {
				return nil, false // No arbitrary winner between conflicting fixes.
			}
		}
		result = append(result, edit)
	}
	return result, true
}
