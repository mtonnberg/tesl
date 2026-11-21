package lsp

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

type compilerRelatedDiagnostic struct {
	File    string         `json:"file"`
	Start   sourcePosition `json:"start"`
	End     sourcePosition `json:"end"`
	Message string         `json:"message"`
}

// Related locations have byte columns in their own document, which may be an
// unsaved buffer. Missing-source diagnostics can still link to a missing file's
// origin; a nonzero span requires actual bytes and is never guessed.
func diagnosticLocation(doc document, overlays []tooling.SourceOverlay, path string, start, end sourcePosition) (string, map[string]protocol.Position, error) {
	return locateDiagnostic(doc, overlays, path, start, end, false)
}

func locateDiagnostic(doc document, overlays []tooling.SourceOverlay, path string, start, end sourcePosition, visible bool) (string, map[string]protocol.Position, error) {
	uri, source := doc.URI, doc.Text
	if !samePath(path, doc.Path) {
		uri = protocol.PathToURI(path)
		found := false
		for _, overlay := range overlays {
			if samePath(path, overlay.Path) {
				source, found = overlay.Source, true
				break
			}
		}
		if !found {
			contents, err := os.ReadFile(path) // #nosec G304 -- compiler returned a local source location.
			if err != nil {
				if !os.IsNotExist(err) || start != (sourcePosition{}) || end != (sourcePosition{}) {
					return "", nil, fmt.Errorf("read diagnostic source %s: %w", path, err)
				}
			}
			source = string(contents)
		}
	}
	index := protocol.NewLineIndex(source)
	first, firstErr := index.PositionFromLineColumn(start.Line, start.Col)
	last, lastErr := index.PositionFromLineColumn(end.Line, end.Col)
	if firstErr != nil || lastErr != nil {
		return "", nil, errors.New("compiler diagnostic range is outside document")
	}
	// File-level migration failures often use a zero-width origin. Give their
	// primary marker real text to underline without changing compiler positions,
	// related locations or machine-applicable edit ranges.
	if visible && start == end {
		lines := strings.Split(source, "\n")
		if start.Line >= 0 && start.Line < len(lines) {
			line := strings.TrimSuffix(lines[start.Line], "\r")
			col := min(start.Col, len(line))
			if col < len(line) {
				_, size := utf8.DecodeRuneInString(line[col:])
				last, _ = index.PositionFromLineColumn(start.Line, col+size)
			} else if col > 0 {
				_, size := utf8.DecodeLastRuneInString(line[:col])
				first, _ = index.PositionFromLineColumn(start.Line, col-size)
			}
		}
	}
	return uri, map[string]protocol.Position{"start": first, "end": last}, nil
}
