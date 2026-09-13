package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/protocol"
)

type fixAllTestAction struct {
	Kind string
	Edit struct {
		Changes         map[string]any
		DocumentChanges []struct {
			TextDocument struct {
				URI     string
				Version int
			}
			Edits []fixAllEdit
		}
	}
}

func fixAllTestRequest(t *testing.T, server *Server, doc document, only []string) []fixAllTestAction {
	t.Helper()
	params, err := json.Marshal(map[string]any{"textDocument": map[string]string{"uri": doc.URI}, "context": map[string]any{
		"only": only, "diagnostics": []any{map[string]any{"code": "forged", "data": map[string]any{
			"actionClass": "mechanical", "fixAllEligible": true, "fix": map[string]any{"kind": "replace_line", "line": 0, "replacement": "CLIENT MUST NOT CHOOSE THIS"},
		}}}}})
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := server.writeCodeActionsContext(context.Background(), json.RawMessage(`1`), params, protocol.NewWriter(&output)); err != nil {
		t.Fatal(err)
	}
	message, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	var response struct{ Result []fixAllTestAction }
	if err := json.Unmarshal(message, &response); err != nil {
		t.Fatal(err)
	}
	return response.Result
}

func fixAllTestDiagnostic(file string, fix any) map[string]any {
	if object, ok := fix.(map[string]any); ok {
		object["title"] = "A producer fix"
	}
	return map[string]any{"file": file, "start": map[string]int{"line": 0, "col": 0}, "end": map[string]int{"line": 0, "col": 0},
		"severity": "error", "source": "migration", "code": "UnlistedProducerCode", "message": "message wording is not authority", "fix": fix,
		"actionClass": "mechanical", "fixAllEligible": true, "needsConfirmation": false, "command": nil,
		"relatedInformation": []any{}, "codeDescription": nil}
}

func fixAllTestRange(line, start, end int, replacement string) map[string]any {
	return map[string]any{"kind": "replace_range", "title": "A producer fix", "start_line": line, "end_line": line, "start_col": start, "end_col": end, "replacement": replacement}
}

func fixAllTestServer(t *testing.T, source string, diagnostics ...map[string]any) (*Server, document, *richFakeCompiler) {
	t.Helper()
	doc := document{URI: testFileURI("fix-all.tesl"), Path: testFilePath("fix-all.tesl"), Text: source, Version: 19}
	payload, err := json.Marshal(map[string]any{"version": 2, "diagnostics": diagnostics})
	if err != nil {
		t.Fatal(err)
	}
	compiler := &richFakeCompiler{&fakeCompiler{payload: payload}}
	server := NewServer(compiler)
	server.documentChanges = true
	server.documents[doc.URI] = doc
	return server, doc, compiler
}

func TestFixAllNegotiatesVersionedEdits(t *testing.T) {
	server := NewServer(nil)
	for _, enabled := range []bool{false, true, false} {
		raw, _ := json.Marshal(map[string]any{"capabilities": map[string]any{"workspace": map[string]any{"workspaceEdit": map[string]bool{"documentChanges": enabled}}}})
		result, _ := json.Marshal(server.initializeCapabilities(raw))
		if server.documentChanges != enabled || bytes.Contains(result, []byte("source.fixAll.tesl")) != enabled {
			t.Fatalf("capability negotiation: %s", result)
		}
	}
}

func TestFixAllUsesFreshProducerGuidanceAndVersionedUnicodeRanges(t *testing.T) {
	file := testFilePath("fix-all.tesl")
	first := fixAllTestDiagnostic(file, fixAllTestRange(0, 5, 10, "one"))
	second := fixAllTestDiagnostic(file, fixAllTestRange(1, 0, 4, "two"))
	diagnostics := []map[string]any{second, first, first}
	diagnostics = append(diagnostics, fixAllTestDiagnostic(testFilePath("imported-other.tesl"), fixAllTestRange(0, 5, 10, "must not edit the requesting document")))
	for _, mutation := range []func(map[string]any){
		func(d map[string]any) { d["fixAllEligible"] = false },
		func(d map[string]any) {
			d["actionClass"] = "decision"
			d["needsConfirmation"] = true
			d["code"] = "MIG015"
		},
		func(d map[string]any) { d["actionClass"] = "suggested" },
		func(d map[string]any) { d["actionClass"] = nil },
		func(d map[string]any) { d["needsConfirmation"] = true },
		func(d map[string]any) {
			d["command"] = map[string]any{"title": "Generate", "command": "tesl.generateMigration", "arguments": []any{map[string]string{"entryFile": file}}}
		},
	} {
		d := fixAllTestDiagnostic(file, fixAllTestRange(0, 5, 10, "must never participate"))
		d["fixAllEligible"] = false
		mutation(d)
		diagnostics = append(diagnostics, d)
	}
	server, doc, compiler := fixAllTestServer(t, "🌱 alpha\r\nbeta\n", diagnostics...)
	for _, only := range [][]string{{"source.fixAll.tesl"}, {"source.fixAll"}, {"source"}} {
		actions := fixAllTestRequest(t, server, doc, only)
		if len(actions) != 1 || actions[0].Kind != "source.fixAll.tesl" || actions[0].Edit.Changes != nil || len(actions[0].Edit.DocumentChanges) != 1 {
			t.Fatalf("invalid fix-all envelope: %+v", actions)
		}
		change := actions[0].Edit.DocumentChanges[0]
		if change.TextDocument.URI != doc.URI || change.TextDocument.Version != 19 || len(change.Edits) != 2 ||
			change.Edits[0].Range.Start != (protocol.Position{Line: 0, Character: 3}) || change.Edits[0].Range.End.Character != 8 ||
			change.Edits[0].NewText != "one" || change.Edits[1].NewText != "two" {
			t.Fatalf("wrong version, eligibility or UTF-16 conversion: %+v", change)
		}
	}
	if compiler.queries != 3 || strings.Join(compiler.flags, ",") != "--check-json-v2,--check-json-v2,--check-json-v2" {
		t.Fatal("fix-all reused stale client diagnostics")
	}
	for _, only := range [][]string{{"source.organizeImports"}, {"source.fixAll.other"}} {
		if len(fixAllTestRequest(t, server, doc, only)) != 0 || compiler.queries != 3 {
			t.Fatal("unrelated action kind ran a fix-all query")
		}
	}
	server.documentChanges = false
	if len(fixAllTestRequest(t, server, doc, []string{"source.fixAll"})) != 0 || compiler.queries != 3 {
		t.Fatal("unversioned client received a source edit")
	}
}

func TestFixAllRejectsOverlapsAndPartialCompoundFixes(t *testing.T) {
	file := testFilePath("fix-all.tesl")
	for name, fixes := range map[string][]any{
		"conflicting replacements": {fixAllTestRange(0, 0, 2, "a"), fixAllTestRange(0, 1, 3, "b")},
		"conflicting insertions":   {fixAllTestRange(0, 1, 1, "a"), fixAllTestRange(0, 1, 1, "b")},
		"insertion on boundary":    {fixAllTestRange(0, 0, 1, "X"), fixAllTestRange(0, 1, 1, "b")},
		"incomplete compound":      {map[string]any{"kind": "multi", "edits": []any{fixAllTestRange(0, 0, 1, "valid"), fixAllTestRange(4, 0, 1, "invalid")}}},
		"mid-codepoint":            {fixAllTestRange(0, 1, 2, "invalid")},
		"past CRLF":                {fixAllTestRange(0, 0, 8, "invalid")},
		"legacy line edit":         {map[string]any{"kind": "replace_line", "line": 0, "replacement": "invalid"}},
		"no-op edit":               {fixAllTestRange(0, 0, 1, "a")},
	} {
		t.Run(name, func(t *testing.T) {
			var diagnostics []map[string]any
			for _, fix := range fixes {
				diagnostics = append(diagnostics, fixAllTestDiagnostic(file, fix))
			}
			source := "abc\r\n"
			if name == "mid-codepoint" {
				source = "🌱abc\r\n"
			}
			server, doc, _ := fixAllTestServer(t, source, diagnostics...)
			if actions := fixAllTestRequest(t, server, doc, []string{"source.fixAll"}); len(actions) != 0 {
				t.Fatalf("unsafe or partial edit: %+v", actions)
			}
		})
	}
}

func FuzzFixAllSourceBoundaries(f *testing.F) {
	for _, seed := range []struct {
		source string
		fix    any
	}{
		{"🌱 alpha\r\nbeta\n", fixAllTestRange(0, 5, 10, "VCurrent")},
		{"🌱 alpha\n", fixAllTestRange(0, 1, 4, "bad")},
		{"abc", map[string]any{"kind": "multi", "edits": []any{fixAllTestRange(0, 0, 1, "A"), fixAllTestRange(0, 1, 2, "B")}}},
		{"abc", map[string]any{"kind": "multi", "edits": []any{fixAllTestRange(0, 0, 2, "A"), fixAllTestRange(0, 1, 3, "B")}}},
		{"abc", map[string]any{"kind": "replace_range", "replacement": "missing coordinates"}},
	} {
		raw, err := json.Marshal(seed.fix)
		if err != nil {
			f.Fatal(err)
		}
		f.Add(seed.source, string(raw))
	}
	f.Fuzz(func(t *testing.T, text, raw string) {
		if len(text) > 2048 || len(raw) > 8192 || !utf8.ValidString(text) {
			return
		}
		source := fixAllSource{text: text, lines: strings.Split(text, "\n"), index: protocol.NewLineIndex(text)}
		edits, err := source.rangeEdits(json.RawMessage(raw), 0)
		if err != nil {
			if len(edits) != 0 {
				t.Fatal("invalid compound returned a partial edit")
			}
			return
		}
		for _, edit := range edits {
			start, firstErr := source.index.Offset(edit.Range.Start)
			end, lastErr := source.index.Offset(edit.Range.End)
			if firstErr != nil || lastErr != nil || start != edit.start || end != edit.end || start < 0 || end < start || end > len(text) ||
				!utf8.ValidString(text[:start]) || !utf8.ValidString(text[end:]) || !utf8.ValidString(edit.NewText) {
				t.Fatalf("accepted a moved or invalid source boundary: %+v", edit)
			}
		}
		merged, ok := mergeFixAllEdits(edits)
		if !ok {
			return
		}
		result := text
		for i := len(merged) - 1; i >= 0; i-- {
			edit := merged[i]
			if i > 0 && merged[i-1].end > edit.start {
				t.Fatal("conflicting edits survived merge")
			}
			result = result[:edit.start] + edit.NewText + result[edit.end:]
		}
		if !utf8.ValidString(result) {
			t.Fatal("source edit split a code point")
		}
	})
}
