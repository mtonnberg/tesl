package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

func completionResponseFor(t *testing.T, server *Server, method string, params any) protocol.Response {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	_, err = server.handle(context.Background(), protocol.Request{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: method, Params: raw}, protocol.NewWriter(&output))
	if err != nil {
		t.Fatal(err)
	}
	message, err := protocol.NewReader(&output).Read()
	if err != nil {
		t.Fatal(err)
	}
	var response protocol.Response
	if err := json.Unmarshal(message, &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func completionFixture(t *testing.T, source string, item map[string]any) (*Server, protocol.Response) {
	t.Helper()
	payload, err := json.Marshal(map[string]any{"version": 1, "completions": []any{item}})
	if err != nil {
		t.Fatal(err)
	}
	compiler := &fakeCompiler{responses: map[string][]byte{"--completions-json": payload}}
	server := NewServer(compiler)
	server.documents["file:///tmp/demo.tesl"] = document{URI: "file:///tmp/demo.tesl", Path: "/tmp/demo.tesl", Text: source, Version: 7}
	return server, completionResponseFor(t, server, "textDocument/completion", map[string]any{
		"textDocument": map[string]string{"uri": "file:///tmp/demo.tesl"}, "position": protocol.Position{},
	})
}

func completionItemFor(t *testing.T, response protocol.Response) map[string]any {
	t.Helper()
	if response.Error != nil {
		t.Fatalf("completion failed: %+v", response.Error)
	}
	var list struct {
		Items []map[string]any `json:"items"`
	}
	if err := json.Unmarshal(response.Result, &list); err != nil {
		t.Fatal(err)
	}
	if len(list.Items) != 1 {
		t.Fatalf("expected one item: %s", response.Result)
	}
	return list.Items[0]
}

func rangeEdit(line, start, end int, text string) map[string]any {
	return map[string]any{"kind": "replace_range", "title": "Complete symbol", "start_line": line,
		"start_col": start, "end_line": line, "end_col": end, "replacement": text}
}

func TestCompletionRichMetadataAndEdits(t *testing.T) {
	_, response := completionFixture(t, "module Demo exposing []\nString.le\n", map[string]any{
		"label": "String.length", "detail": "String -> Int", "kind": "function", "module": "Tesl.String",
		"documentation": "Count characters.", "requires_import": true, "sort_text": "2:String.length",
		"text_edit":   rangeEdit(1, 0, 9, "String.length"),
		"import_edit": map[string]any{"kind": "insert_line", "line": 1, "text": "import Tesl.String exposing [String.length]", "title": "Import function"},
	})
	// Same-position inserts would overlap the replacement and must be refused.
	if response.Error == nil || !strings.Contains(response.Error.Message, "overlapping") {
		t.Fatalf("overlapping edits accepted: %+v", response)
	}
	_, response = completionFixture(t, "module Demo exposing []\n\nString.le\n", map[string]any{
		"label": "String.length", "detail": "String -> Int", "kind": "function", "module": "Tesl.String",
		"documentation": "Count characters.", "requires_import": true, "sort_text": "2:String.length",
		"text_edit":   rangeEdit(2, 0, 9, "String.length"),
		"import_edit": map[string]any{"kind": "insert_line", "line": 1, "text": "import Tesl.String exposing [String.length]", "title": "Import function"},
	})
	item := completionItemFor(t, response)
	if item["kind"] != float64(3) || item["sortText"] != "2:String.length" || !strings.Contains(item["detail"].(string), "Tesl.String (auto-import)") {
		t.Fatalf("missing discovery metadata: %#v", item)
	}
	if item["documentation"].(map[string]any)["value"] != "Count characters." || item["additionalTextEdits"] == nil || item["textEdit"] == nil {
		t.Fatalf("missing documentation/edits: %#v", item)
	}
}

func TestCompletionSymbolKinds(t *testing.T) {
	for name, expected := range map[string]int{"function": 3, "field": 10, "type": 7, "constructor": 4, "module": 9, "capability": 21, "fact": 8, "variable": 6} {
		t.Run(name, func(t *testing.T) {
			_, response := completionFixture(t, "name", map[string]any{"label": "name", "detail": "detail", "kind": name})
			if got := completionItemFor(t, response)["kind"]; got != float64(expected) {
				t.Fatalf("kind = %v, want %d", got, expected)
			}
		})
	}
}

func TestCompletionUnicodeAndCRLF(t *testing.T) {
	_, response := completionFixture(t, "module Demo exposing []\r\n😀 String.le\r\n", map[string]any{
		"label": "String.length", "detail": "String -> Int", "kind": "function",
		"text_edit":   rangeEdit(1, 5, 14, "String.length"),
		"import_edit": map[string]any{"kind": "insert_line", "line": 1, "text": "import Tesl.String", "title": "Import"},
	})
	item := completionItemFor(t, response)
	edit := item["textEdit"].(map[string]any)
	rangeValue := edit["range"].(map[string]any)
	if rangeValue["start"].(map[string]any)["character"] != float64(3) || rangeValue["end"].(map[string]any)["character"] != float64(12) {
		t.Fatalf("wrong UTF-16 range: %#v", rangeValue)
	}
	imports := item["additionalTextEdits"].([]any)
	if imports[0].(map[string]any)["newText"] != "import Tesl.String\r\n" {
		t.Fatalf("line endings changed: %#v", imports)
	}
}

func TestCompletionRejectsInvalidEdits(t *testing.T) {
	for name, edit := range map[string]any{
		"past line end": rangeEdit(0, 0, 100, "x"),
		"past document": rangeEdit(99, 0, 0, "x"),
		"inside utf8":   rangeEdit(0, 1, 4, "x"),
		"backwards":     rangeEdit(0, 5, 0, "x"),
		"negative":      rangeEdit(0, -1, 0, "x"),
		"wrong kind":    map[string]any{"kind": "insert_line", "line": 0, "text": "x", "title": "bad primary"},
		"malformed":     map[string]any{"kind": "replace_range", "title": "missing fields"},
	} {
		t.Run(name, func(t *testing.T) {
			_, response := completionFixture(t, "😀 name\n", map[string]any{"label": "x", "detail": "Int", "kind": "variable", "text_edit": edit})
			if response.Error == nil {
				t.Fatalf("invalid edit accepted: %s", response.Result)
			}
		})
	}
}

func TestCompletionResolveRejectsChangedAndClosedBuffers(t *testing.T) {
	for _, closed := range []bool{false, true} {
		t.Run(fmt.Sprintf("closed=%v", closed), func(t *testing.T) {
			server, response := completionFixture(t, "String.le", map[string]any{"label": "String.length", "detail": "String -> Int", "kind": "function", "sort_text": "2:String.length"})
			item := completionItemFor(t, response)
			if closed {
				delete(server.documents, "file:///tmp/demo.tesl")
			} else {
				doc := server.documents["file:///tmp/demo.tesl"]
				doc.Version++
				server.documents[doc.URI] = doc
			}
			resolved := completionResponseFor(t, server, "completionItem/resolve", item)
			if resolved.Error == nil || resolved.Error.Code != -32801 {
				t.Fatalf("stale completion accepted: %+v", resolved)
			}
		})
	}
}

func TestCompletionDoesNotBorrowDocumentationForLocalName(t *testing.T) {
	server, response := completionFixture(t, "identity", map[string]any{
		"label": "identity", "detail": "String -> String", "kind": "function", "sort_text": "0:identity", "module": nil, "documentation": nil,
	})
	compiler := server.compiler.(*fakeCompiler)
	compiler.responses["--doc-json"] = []byte(`{"version":1,"entries":[{"name":"identity","doc":"WRONG library documentation"}]}`)
	resolved := completionResponseFor(t, server, "completionItem/resolve", completionItemFor(t, response))
	if resolved.Error != nil || bytes.Contains(resolved.Result, []byte("WRONG")) || len(compiler.flags) != 1 {
		t.Fatalf("local symbol used library documentation: %s, flags=%v", resolved.Result, compiler.flags)
	}
}

func TestCompletionResolveRejectsChangedDependencySnapshots(t *testing.T) {
	for _, change := range []string{"overlay", "disk-notification", "invalid-handle"} {
		t.Run(change, func(t *testing.T) {
			server, response := completionFixture(t, "May", map[string]any{"label": "Maybe", "detail": "Maybe a", "kind": "type", "sort_text": "2:Maybe"})
			item := completionItemFor(t, response)
			switch change {
			case "overlay":
				server.documents["file:///tmp/types.tesl"] = document{URI: "file:///tmp/types.tesl", Path: "/tmp/types.tesl", Text: "module Types exposing []", Version: 1}
			case "disk-notification":
				server.fileChangeVersion++
			case "invalid-handle":
				item["data"].(map[string]any)["snapshot"] = map[string]any{"invalid": true}
			}
			resolved := completionResponseFor(t, server, "completionItem/resolve", item)
			if resolved.Error == nil || resolved.Error.Code != -32801 {
				t.Fatalf("accepted changed dependency: %+v", resolved)
			}
		})
	}
}

func TestBuiltCompilerProjectTypeUsesUnsavedDependency(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	repo := filepath.Clean(filepath.Join(filepath.Dir(file), "../../../.."))
	compiler := filepath.Join(repo, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("compiler build unavailable")
	}
	client := tooling.Client{Executable: compiler, Sessions: tooling.NewWorkspaceSessions()}
	t.Cleanup(func() { _ = client.Close() })
	server := NewServer(client)
	root := t.TempDir()
	entry, dependency := filepath.Join(root, "app.tesl"), filepath.Join(root, "model.tesl")
	disk := "module Model exposing [OldType]\nrecord OldType { n: Int }\n"
	if err := os.WriteFile(dependency, []byte(disk), 0600); err != nil {
		t.Fatal(err)
	}
	uri, dependencyURI := protocol.PathToURI(entry), protocol.PathToURI(dependency)
	source := "module App exposing []\n\nrecord Box { value: NewT }\n"
	server.documents[uri] = document{URI: uri, Path: entry, Text: source, Version: 1}
	server.documents[dependencyURI] = document{URI: dependencyURI, Path: dependency, Text: "module Model exposing [NewType]\nrecord NewType { n: Int }\n", Version: 7}
	response := completionResponseFor(t, server, "textDocument/completion", map[string]any{
		"textDocument": map[string]string{"uri": uri}, "position": protocol.Position{Line: 2, Character: len("record Box { value: NewT")},
	})
	item := completionItemFor(t, response)
	if item["label"] != "NewType" || item["additionalTextEdits"] == nil || !strings.Contains(item["detail"].(string), "Model (auto-import)") {
		t.Fatalf("missing project import: %#v", item)
	}
	onDisk, err := os.ReadFile(dependency)
	if err != nil || string(onDisk) != disk {
		t.Fatal("query changed dependency on disk")
	}
	doc := server.documents[dependencyURI]
	doc.Text = disk
	doc.Version++
	server.documents[dependencyURI] = doc
	resolved := completionResponseFor(t, server, "completionItem/resolve", item)
	if resolved.Error == nil || resolved.Error.Code != -32801 {
		t.Fatal("accepted stale project type")
	}
	response = completionResponseFor(t, server, "textDocument/completion", map[string]any{
		"textDocument": map[string]string{"uri": uri}, "position": protocol.Position{Line: 2, Character: len("record Box { value: NewT")},
	})
	if response.Error != nil || bytes.Contains(response.Result, []byte(`"label":"NewType"`)) {
		t.Fatalf("stale project candidate: %s, %+v", response.Result, response.Error)
	}
}

func TestBuiltCompilerCompletionUsesUnsavedBuffer(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "../../../.."))
	compiler := filepath.Join(root, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("compiler build unavailable")
	}
	client := tooling.Client{Executable: compiler, Sessions: tooling.NewWorkspaceSessions()}
	t.Cleanup(func() { _ = client.Close() })
	server := NewServer(client)
	path := filepath.Join(t.TempDir(), "demo.tesl")
	if err := os.WriteFile(path, []byte("module Demo exposing []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	uri := protocol.PathToURI(path)
	source := "module Demo exposing []\nimport Tesl.Prelude exposing [String, Int]\nfn size(s: String) -> Int = String.le s\n"
	server.documents[uri] = document{URI: uri, Path: path, Text: source, Version: 4}
	response := completionResponseFor(t, server, "textDocument/completion", map[string]any{
		"textDocument": map[string]string{"uri": uri}, "position": protocol.Position{Line: 2, Character: len("fn size(s: String) -> Int = String.le")},
	})
	if response.Error != nil || !bytes.Contains(response.Result, []byte(`"label":"String.length"`)) || !bytes.Contains(response.Result, []byte(`additionalTextEdits`)) {
		t.Fatalf("real completion failed: error=%+v result=%s", response.Error, response.Result)
	}
	onDisk, err := os.ReadFile(path)
	if err != nil || string(onDisk) != "module Demo exposing []\n" {
		t.Fatalf("unsaved query modified disk: %q, %v", onDisk, err)
	}
}

func TestBuiltCompilerTypeSelectionImportsAndChecks(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "../../../.."))
	compiler := filepath.Join(root, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("compiler build unavailable")
	}
	for _, newline := range []string{"\n", "\r\n"} {
		for _, imported := range []string{"", "import Tesl.Maybe exposing [Nothing]", "import Tesl.Maybe exposing [Maybe(..)]"} {
			t.Run(fmt.Sprintf("crlf=%v/import=%s", newline == "\r\n", imported), func(t *testing.T) {
				client := tooling.Client{Executable: compiler, Sessions: tooling.NewWorkspaceSessions()}
				t.Cleanup(func() { _ = client.Close() })
				server := NewServer(client)
				path := filepath.Join(t.TempDir(), "demo.tesl")
				uri := protocol.PathToURI(path)
				source := strings.Join([]string{"module Demo exposing [Box]", "import Tesl.Prelude exposing [Int]", imported, "record Box {", "  value: May Int", "}", ""}, newline)
				server.documents[uri] = document{URI: uri, Path: path, Text: source, Version: 4}
				response := completionResponseFor(t, server, "textDocument/completion", map[string]any{
					"textDocument": map[string]string{"uri": uri}, "position": protocol.Position{Line: 4, Character: 12},
				})
				if response.Error != nil {
					t.Fatalf("completion: %+v", response.Error)
				}
				item := completionItemFor(t, response)
				if item["label"] != "Maybe" || item["kind"] != float64(7) {
					t.Fatalf("expected type candidate: %#v", item)
				}
				resolved := completionResponseFor(t, server, "completionItem/resolve", item)
				if resolved.Error != nil {
					t.Fatalf("resolve: %+v", resolved.Error)
				}
				var selected struct {
					TextEdit struct {
						Range   protocol.Range `json:"range"`
						NewText string         `json:"newText"`
					} `json:"textEdit"`
					Additional []struct {
						Range   protocol.Range `json:"range"`
						NewText string         `json:"newText"`
					} `json:"additionalTextEdits"`
				}
				if err := json.Unmarshal(resolved.Result, &selected); err != nil {
					t.Fatal(err)
				}
				if got, want := len(selected.Additional), 1; imported != "import Tesl.Maybe exposing [Maybe(..)]" && got != want {
					t.Fatalf("expected auto-import edit: %s", resolved.Result)
				}
				if imported == "import Tesl.Maybe exposing [Maybe(..)]" && len(selected.Additional) != 0 {
					t.Fatalf("duplicate import: %s", resolved.Result)
				}
				changes := append(selected.Additional, selected.TextEdit)
				sort.Slice(changes, func(i, j int) bool { return comparePosition(changes[i].Range.Start, changes[j].Range.Start) > 0 })
				for _, change := range changes {
					index := protocol.NewLineIndex(source)
					start, err := index.Offset(change.Range.Start)
					if err != nil {
						t.Fatal(err)
					}
					end, err := index.Offset(change.Range.End)
					if err != nil {
						t.Fatal(err)
					}
					source = source[:start] + change.NewText + source[end:]
				}
				if strings.Count(source, "import Tesl.Maybe") != 1 || !strings.Contains(source, "value: Maybe Int") {
					t.Fatalf("incorrect accepted completion:\n%s", source)
				}
				if newline == "\r\n" && strings.Contains(strings.ReplaceAll(source, newline, ""), "\n") {
					t.Fatalf("introduced LF into CRLF document: %q", source)
				}
				payload, _, err := client.QuerySourceJSON(context.Background(), "--check-json", path, source)
				if err != nil {
					t.Fatal(err)
				}
				var checked struct {
					Diagnostics []struct {
						Severity string `json:"severity"`
					} `json:"diagnostics"`
				}
				if err := json.Unmarshal(payload, &checked); err != nil {
					t.Fatal(err)
				}
				for _, diagnostic := range checked.Diagnostics {
					if diagnostic.Severity == "error" {
						t.Fatalf("accepted type failed to check:\n%s\n%s", source, payload)
					}
				}
				if _, err := os.Stat(path); !os.IsNotExist(err) {
					t.Fatalf("completion query wrote unsaved document: %v", err)
				}
			})
		}
	}
}
