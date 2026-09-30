package tooling

import (
	"context"
	"crypto/md5" // #nosec G501 -- compiler consistency token, never an authenticity check.
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

type WorkspaceLocation struct {
	File    string `json:"file"`
	Line    int    `json:"line"`
	Col     int    `json:"col"`
	EndLine int    `json:"end_line"`
	EndCol  int    `json:"end_col"`
}
type WorkspaceInput struct {
	File        string `json:"file"`
	ContentHash string `json:"content_hash"`
}
type WorkspaceReference struct {
	Location WorkspaceLocation `json:"location"`
	Role     string            `json:"role"`
}
type WorkspaceSymbol struct {
	ID         string            `json:"id"`
	Name       string            `json:"name"`
	Kind       string            `json:"kind"`
	Definition WorkspaceLocation `json:"definition"`
	ReadOnly   bool              `json:"read_only"`
}
type WorkspaceEdit struct {
	Location WorkspaceLocation `json:"location"`
	NewText  string            `json:"new_text"`
}
type WorkspaceFileEdits struct {
	File        string          `json:"file"`
	ContentHash string          `json:"content_hash"`
	Edits       []WorkspaceEdit `json:"edits"`
}
type WorkspaceRename struct {
	Safe             bool                 `json:"safe"`
	NewName          string               `json:"new_name"`
	ExpectedSnapshot string               `json:"expected_snapshot"`
	Reason           *string              `json:"reason"`
	Checked          string               `json:"checked"`
	Files            []WorkspaceFileEdits `json:"files"`
}
type WorkspaceResponse struct {
	Version            int    `json:"version"`
	Root               string `json:"workspace_root"`
	Snapshot           string `json:"snapshot"`
	CoordinateEncoding string `json:"coordinate_encoding"`
	Complete           bool   `json:"complete"`
	Problems           []struct {
		Code    string `json:"code"`
		File    string `json:"file"`
		Message string `json:"message"`
	} `json:"problems"`
	Inputs     []WorkspaceInput     `json:"inputs"`
	Symbol     *WorkspaceSymbol     `json:"symbol"`
	References []WorkspaceReference `json:"references"`
	Rename     *WorkspaceRename     `json:"rename"`
}

func workspaceFlag(flag string) bool {
	return flag == "--workspace-definition-json" || flag == "--workspace-references-json" || flag == "--workspace-rename-json"
}

func validateWorkspaceJSON(flag string, root map[string]any, payload []byte) error {
	for _, field := range []string{"workspace_root", "snapshot", "coordinate_encoding"} {
		if text, err := requiredString(root, field); err != nil || text == "" {
			return fmt.Errorf("invalid workspace %s", field)
		}
	}
	if _, ok := root["complete"].(bool); !ok {
		return errors.New("workspace complete must be boolean")
	}
	for _, field := range []string{"problems", "inputs", "references"} {
		if _, err := requiredArray(root, field); err != nil {
			return err
		}
	}
	if err := validateNullableObject(root, "symbol", func(symbol map[string]any) error {
		for _, field := range []string{"id", "name", "kind"} {
			if text, err := requiredString(symbol, field); err != nil || text == "" {
				return fmt.Errorf("invalid symbol %s", field)
			}
		}
		if _, ok := symbol["read_only"].(bool); !ok {
			return errors.New("symbol read_only must be boolean")
		}
		loc, err := valueObject(symbol["definition"], "definition")
		if err != nil {
			return err
		}
		return validateLocation(loc, "definition", true)
	}); err != nil {
		return err
	}
	if err := validateObjectArray(root, "references", func(value map[string]any, name string) error {
		if _, err := requiredString(value, "role"); err != nil {
			return err
		}
		loc, err := valueObject(value["location"], name)
		if err != nil {
			return err
		}
		return validateLocation(loc, name, true)
	}); err != nil {
		return err
	}
	if flag == "--workspace-rename-json" {
		rename, err := valueObject(root["rename"], "rename")
		if err != nil {
			return err
		}
		if _, ok := rename["safe"].(bool); !ok {
			return errors.New("rename safe must be boolean")
		}
		for _, field := range []string{"new_name", "expected_snapshot", "checked"} {
			if _, err := requiredString(rename, field); err != nil {
				return err
			}
		}
		if _, err := requiredArray(rename, "files"); err != nil {
			return err
		}
		if _, present := rename["reason"]; !present {
			return errors.New("rename reason missing")
		}
		if err := validateObjectArray(rename, "files", func(file map[string]any, name string) error {
			return validateObjectArray(file, "edits", func(edit map[string]any, name string) error {
				if _, err := requiredString(edit, "new_text"); err != nil {
					return err
				}
				loc, err := valueObject(edit["location"], name)
				if err != nil {
					return err
				}
				return validateLocation(loc, name, true)
			})
		}); err != nil {
			return err
		}
	}
	var response WorkspaceResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		return err
	}
	if !filepath.IsAbs(response.Root) || response.CoordinateEncoding != "utf-8" || response.Complete != (len(response.Problems) == 0) {
		return errors.New("invalid workspace scope or completeness")
	}
	inputs := make(map[string]string)
	for _, input := range response.Inputs {
		decoded, err := hex.DecodeString(input.ContentHash)
		if !filepath.IsAbs(input.File) || strings.ContainsRune(input.File, 0) || err != nil || len(decoded) != md5.Size || inputs[input.File] != "" {
			return errors.New("invalid or duplicate workspace input")
		}
		inputs[input.File] = input.ContentHash
	}
	for _, problem := range response.Problems {
		if problem.Code == "" || problem.File == "" || problem.Message == "" {
			return errors.New("incomplete workspace problem")
		}
	}
	if response.Symbol == nil && len(response.References) != 0 {
		return errors.New("workspace references have no symbol")
	}
	if response.Symbol != nil {
		if inputs[response.Symbol.Definition.File] == "" {
			return errors.New("workspace definition has no input precondition")
		}
		switch response.Symbol.Kind {
		case "term", "type", "constructor":
		default:
			return errors.New("invalid workspace symbol namespace")
		}
	}
	refs := make(map[WorkspaceLocation]bool)
	for _, ref := range response.References {
		if inputs[ref.Location.File] == "" || refs[ref.Location] {
			return errors.New("reference missing input or duplicated")
		}
		switch ref.Role {
		case "read", "declaration", "exposing":
		default:
			return errors.New("invalid workspace reference role")
		}
		refs[ref.Location] = true
	}
	if rename := response.Rename; rename != nil {
		if !rename.Safe {
			if len(rename.Files) != 0 || rename.Reason == nil || *rename.Reason == "" {
				return errors.New("unsafe rename exposes edits or lacks a reason")
			}
			return nil
		}
		if !response.Complete || response.Symbol == nil || response.Symbol.ReadOnly || rename.ExpectedSnapshot != response.Snapshot || rename.Reason != nil || rename.Checked != "binding-identity-and-type-proof-check" {
			return errors.New("rename safety preconditions are inconsistent")
		}
		seenFiles := make(map[string]bool)
		edits := make(map[WorkspaceLocation]bool)
		for _, file := range rename.Files {
			if !pathWithinRoot(response.Root, file.File) || inputs[file.File] == "" || file.ContentHash != inputs[file.File] || seenFiles[file.File] || len(file.Edits) == 0 {
				return errors.New("invalid rename file precondition")
			}
			seenFiles[file.File] = true
			sorted := append([]WorkspaceEdit(nil), file.Edits...)
			sort.Slice(sorted, func(i, j int) bool {
				a, b := sorted[i].Location, sorted[j].Location
				return a.Line < b.Line || a.Line == b.Line && a.Col < b.Col
			})
			for i, edit := range sorted {
				loc := edit.Location
				if loc.File != file.File || edit.NewText != rename.NewName || !refs[loc] || edits[loc] || loc.Line == loc.EndLine && loc.Col == loc.EndCol {
					return errors.New("rename edit is not a unique semantic reference")
				}
				if i > 0 {
					prev := sorted[i-1].Location
					if prev.EndLine > loc.Line || prev.EndLine == loc.Line && prev.EndCol > loc.Col {
						return errors.New("overlapping rename edits")
					}
				}
				edits[loc] = true
			}
		}
		if len(edits) == 0 || len(edits) != len(refs) {
			return errors.New("rename does not cover all semantic references")
		}
	}
	return nil
}

// WorkspaceInputTexts checks every compiler precondition, including unopened
// documents and external library files. Returned bytes are the only source for
// converting cross-file byte columns to client coordinates.
func WorkspaceInputTexts(ctx context.Context, response WorkspaceResponse, overlays []SourceOverlay) (map[string]string, error) {
	override := make(map[string]string)
	for _, overlay := range overlays {
		path, err := filepath.Abs(overlay.Path)
		if err != nil {
			return nil, err
		}
		override[filepath.Clean(path)] = overlay.Source
	}
	texts := make(map[string]string)
	for _, input := range response.Inputs {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		source, found := override[filepath.Clean(input.File)]
		if !found {
			data, err := readFileBounded(input.File, DefaultMaxOverlayBytes)
			if err != nil {
				return nil, err
			}
			source = string(data)
		}
		digest := md5.Sum([]byte(source)) // #nosec G401 -- matches the compiler's opaque consistency token.
		if hex.EncodeToString(digest[:]) != input.ContentHash {
			return nil, fmt.Errorf("workspace input changed: %s", input.File)
		}
		texts[input.File] = source
	}
	if response.Symbol != nil {
		if _, _, err := WorkspaceRangeOffsets(texts[response.Symbol.Definition.File], response.Symbol.Definition); err != nil {
			return nil, err
		}
	}
	for _, ref := range response.References {
		source := texts[ref.Location.File]
		first, last, err := WorkspaceRangeOffsets(source, ref.Location)
		if err != nil {
			return nil, err
		}
		if response.Rename != nil && response.Rename.Safe && (response.Symbol == nil || source[first:last] != response.Symbol.Name) {
			return nil, errors.New("rename span does not contain the expected symbol")
		}
	}
	return texts, nil
}

// WorkspaceRangeOffsets rejects out-of-range and mid-rune byte coordinates.
// Unlike display-oriented position recovery, rename must never clamp a span.
func WorkspaceRangeOffsets(source string, location WorkspaceLocation) (int, int, error) {
	lines := strings.Split(source, "\n")
	offset := func(line, column int) (int, error) {
		if line < 0 || line >= len(lines) || column < 0 {
			return 0, errors.New("workspace position is outside source")
		}
		text := strings.TrimSuffix(lines[line], "\r")
		if column > len(text) || !utf8.ValidString(text[:column]) {
			return 0, errors.New("workspace position is not a source byte boundary")
		}
		value := column
		for _, preceding := range lines[:line] {
			value += len(preceding) + 1
		}
		return value, nil
	}
	first, err := offset(location.Line, location.Col)
	if err != nil {
		return 0, 0, err
	}
	last, err := offset(location.EndLine, location.EndCol)
	if err != nil {
		return 0, 0, err
	}
	if last < first {
		return 0, 0, errors.New("reversed workspace source range")
	}
	return first, last, nil
}
