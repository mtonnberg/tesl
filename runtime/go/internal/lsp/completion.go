package lsp

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/protocol"
)

// Resolve must not reuse an auto-import after an open dependency was edited or
// a watched disk input changed. Source versions alone cover only the entry.
func (server *Server) completionSnapshot() string {
	hash := sha256.New()
	fmt.Fprintf(hash, "%d\n", server.fileChangeVersion)
	for _, overlay := range server.sourceOverlays() {
		fmt.Fprintf(hash, "%q:%x\n", overlay.Path, sha256.Sum256([]byte(overlay.Source)))
	}
	return fmt.Sprintf("%x", hash.Sum(nil))
}

// Completion edits must fit the actual buffer. The generic position adapter's
// clamping is useful for display, but must never turn malformed edits into writes
// at a different location. Keep compiler byte columns until validation finishes.
func (server *Server) completionEdit(doc document, raw json.RawMessage, primary bool) (map[string]any, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var fix fixPayload
	if err := json.Unmarshal(raw, &fix); err != nil {
		return nil, fmt.Errorf("compiler: invalid completion edit: %w", err)
	}
	lines := strings.Split(doc.Text, "\n")
	valid := func(line, col int) bool {
		if line < 0 || line >= len(lines) || col < 0 {
			return false
		}
		text := strings.TrimSuffix(lines[line], "\r")
		return col <= len(text) && (col == len(text) || utf8.RuneStart(text[col]))
	}
	if primary && (fix.Kind != "replace_range" || fix.StartLine != fix.EndLine) {
		return nil, fmt.Errorf("compiler: primary completion edit must replace a single-line range")
	}
	switch fix.Kind {
	case "replace_range":
		if !valid(fix.StartLine, fix.StartCol) || !valid(fix.EndLine, fix.EndCol) {
			return nil, fmt.Errorf("compiler: completion range outside source or inside UTF-8 character")
		}
	case "insert_line":
		if !valid(fix.Line, 0) {
			return nil, fmt.Errorf("compiler: completion import line outside source")
		}
	case "replace_span":
		if !valid(fix.StartLine, 0) || !valid(fix.EndLine, 0) {
			return nil, fmt.Errorf("compiler: completion import span outside source")
		}
	default:
		return nil, fmt.Errorf("compiler: unsupported completion edit %q", fix.Kind)
	}
	edits := server.fixEdits(doc, fix)
	if len(edits) != 1 {
		return nil, fmt.Errorf("compiler: completion edit did not yield one edit")
	}
	if strings.Contains(doc.Text, "\r\n") {
		text := edits[0]["newText"].(string)
		edits[0]["newText"] = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\n", "\r\n")
	}
	return edits[0], nil
}

func completionEditsOverlap(left, right map[string]any) bool {
	a := left["range"].(protocol.Range)
	b := right["range"].(protocol.Range)
	if a.Start == b.Start {
		return true
	}
	return comparePosition(a.Start, b.End) < 0 && comparePosition(b.Start, a.End) < 0
}
