package lsp

import (
	"context"
	"crypto/md5" // #nosec G501 -- compiler fixture consistency tokens.
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"tesl.dev/runtime/go/internal/protocol"
	"tesl.dev/runtime/go/internal/tooling"
)

func workspacePayload(t *testing.T, path, source string, locations []tooling.WorkspaceLocation, rename string) []byte {
	t.Helper()
	refs := []map[string]any{}
	edits := []map[string]any{}
	for i, loc := range locations {
		role := "read"
		if i == 0 {
			role = "declaration"
		}
		refs = append(refs, map[string]any{"location": loc, "role": role})
		edits = append(edits, map[string]any{"location": loc, "new_text": rename})
	}
	hash := fmt.Sprintf("%x", md5.Sum([]byte(source))) // #nosec G401 -- test fixture.
	response := map[string]any{"version": 1, "workspace_root": filepath.Dir(path), "snapshot": "snapshot", "coordinate_encoding": "utf-8", "complete": true, "problems": []any{}, "inputs": []any{map[string]any{"file": path, "content_hash": hash}}, "symbol": map[string]any{"id": "symbol", "name": "value", "kind": "term", "definition": locations[0], "read_only": false}, "references": refs}
	if rename != "" {
		response["rename"] = map[string]any{"safe": true, "new_name": rename, "expected_snapshot": "snapshot", "reason": nil, "checked": "binding-identity-and-type-proof-check", "files": []any{map[string]any{"file": path, "content_hash": hash, "edits": edits}}}
	}
	payload, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func workspaceCompiler(t *testing.T) tooling.Client {
	t.Helper()
	_, current, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(current), "../../../.."))
	compiler := filepath.Join(root, "compiler/_build/default/bin/main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Skip("build compiler for workspace integration")
	}
	client := tooling.Client{Executable: compiler, Sessions: tooling.NewWorkspaceSessions(), Environment: append(os.Environ(), "TESL_REPO_ROOT="+root)}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

func workspaceProject(t *testing.T) (string, string, string) {
	t.Helper()
	root := t.TempDir()
	lib := "module Lib exposing [double]\r\nimport Tesl.Prelude exposing [Int]\r\nfn double(n: Int) -> Int = n * 2\r\n"
	main := "module Main exposing [show]\r\nimport Tesl.Prelude exposing [Int, String]\r\nimport Lib exposing [double]\r\nfn show(n: Int) -> String = \"😀 ${double n}\"\r\n"
	for name, text := range map[string]string{"tesl.toml": "[project]\nname=\"test\"\n", "lib.tesl": lib, "main.tesl": main} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return root, lib, main
}

func workspaceParams(uri string, position protocol.Position) map[string]any {
	return map[string]any{"textDocument": map[string]string{"uri": uri}, "position": position}
}

func TestWorkspaceNavigationAndRenameRealCompiler(t *testing.T) {
	root, lib, main := workspaceProject(t)
	server := NewServer(workspaceCompiler(t))
	server.workspaceEditsSupported = true // Fixture bypasses initialize.
	path := filepath.Join(root, "main.tesl")
	uri := protocol.PathToURI(path)
	// Both files are dirty: declarations and callers must resolve from the same
	// retained mirror, while the saved files still contain the original name.
	main = strings.ReplaceAll(main, "double", "triple")
	lib = strings.ReplaceAll(lib, "double", "triple")
	libPath := filepath.Join(root, "lib.tesl")
	libURI := protocol.PathToURI(libPath)
	server.documents[uri] = document{Path: path, URI: uri, Text: main, Version: 7}
	server.documents[libURI] = document{Path: libPath, URI: libURI, Text: lib, Version: 9}
	offset := strings.LastIndex(main, "triple n")
	position, err := protocol.NewLineIndex(main).Position(offset)
	if err != nil {
		t.Fatal(err)
	}
	params := workspaceParams(uri, position)
	definition := completionResponseFor(t, server, "textDocument/definition", params)
	if definition.Error != nil || !strings.Contains(string(definition.Result), libURI) {
		t.Fatalf("definition = %+v", definition)
	}
	params["context"] = map[string]bool{"includeDeclaration": false}
	refs := completionResponseFor(t, server, "textDocument/references", params)
	var locations []struct {
		URI   string `json:"uri"`
		Range struct {
			Start protocol.Position `json:"start"`
		} `json:"range"`
	}
	if refs.Error != nil || json.Unmarshal(refs.Result, &locations) != nil || len(locations) != 3 {
		t.Fatalf("references = %+v", refs)
	}
	found := false
	for _, location := range locations {
		if location.URI == uri && location.Range.Start == position {
			found = true
		}
	}
	if !found {
		t.Fatalf("interpolation byte -> UTF16 conversion missing %+v in %s", position, refs.Result)
	}
	prepare := completionResponseFor(t, server, "textDocument/prepareRename", params)
	if prepare.Error != nil || !strings.Contains(string(prepare.Result), "triple") {
		t.Fatalf("prepare = %+v", prepare)
	}
	params["newName"] = "twice"
	rename := completionResponseFor(t, server, "textDocument/rename", params)
	var edit struct {
		Changes []struct {
			Document struct {
				URI     string `json:"uri"`
				Version int    `json:"version"`
			} `json:"textDocument"`
			Edits []json.RawMessage `json:"edits"`
		} `json:"documentChanges"`
	}
	if rename.Error != nil || json.Unmarshal(rename.Result, &edit) != nil || len(edit.Changes) != 2 {
		t.Fatalf("rename = %+v", rename)
	}
	count := 0
	for _, change := range edit.Changes {
		count += len(change.Edits)
		if change.Document.URI == uri && change.Document.Version != 7 || change.Document.URI == libURI && change.Document.Version != 9 {
			t.Fatalf("lost document version: %+v", change)
		}
	}
	if count != 4 {
		t.Fatalf("edits = %d, want 4", count)
	}
	saved, err := os.ReadFile(libPath)
	if err != nil || !strings.Contains(string(saved), "double") {
		t.Fatalf("proposal changed saved source: %s %v", saved, err)
	}
}

type changingWorkspaceCompiler struct {
	tooling.Client
	change  func()
	queries int
}

func (compiler *changingWorkspaceCompiler) QuerySourcesJSON(ctx context.Context, flag, path string, overlays []tooling.SourceOverlay, args ...string) ([]byte, tooling.Result, error) {
	payload, result, err := compiler.Client.QuerySourcesJSON(ctx, flag, path, overlays, args...)
	if flag == "--workspace-rename-json" {
		compiler.queries++
		compiler.change()
	}
	return payload, result, err
}

func TestWorkspaceRenameRejectsUnopenedFileChanges(t *testing.T) {
	for _, mutation := range []string{"change-existing", "create-file"} {
		t.Run(mutation, func(t *testing.T) {
			root, lib, main := workspaceProject(t)
			client := workspaceCompiler(t)
			compiler := &changingWorkspaceCompiler{Client: client, change: func() {
				name, text := "lib.tesl", strings.ReplaceAll(lib, "n * 2", "n * 3")
				if mutation == "create-file" {
					name, text = "other.tesl", "module Other exposing []\n"
				}
				if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0600); err != nil {
					t.Fatal(err)
				}
			}}
			server := NewServer(compiler)
			server.workspaceEditsSupported = true // Fixture bypasses initialize.
			path := filepath.Join(root, "main.tesl")
			uri := protocol.PathToURI(path)
			server.documents[uri] = document{Path: path, URI: uri, Text: main, Version: 1}
			params := workspaceParams(uri, protocol.Position{Line: 2, Character: 21})
			params["newName"] = "twice"
			response := completionResponseFor(t, server, "textDocument/rename", params)
			if compiler.queries != 1 || response.Error == nil || response.Error.Code != -32801 {
				t.Fatalf("stale unopened input accepted: %+v, queries=%d", response, compiler.queries)
			}
		})
	}
}

func TestWorkspaceReferencesNeverHideIncompleteIndex(t *testing.T) {
	root, _, main := workspaceProject(t)
	if err := os.WriteFile(filepath.Join(root, "broken.tesl"), []byte("module Broken exposing ["), 0600); err != nil {
		t.Fatal(err)
	}
	server := NewServer(workspaceCompiler(t))
	server.workspaceEditsSupported = true // Fixture bypasses initialize.
	path := filepath.Join(root, "main.tesl")
	uri := protocol.PathToURI(path)
	server.documents[uri] = document{Path: path, URI: uri, Text: main, Version: 1}
	response := completionResponseFor(t, server, "textDocument/references", workspaceParams(uri, protocol.Position{Line: 2, Character: 21}))
	if response.Error == nil || !strings.Contains(response.Error.Message, "incomplete") {
		t.Fatalf("partial index presented as complete: %+v", response)
	}
}

func TestWorkspaceRenameNegotiatesAtomicClientEdits(t *testing.T) {
	for _, mode := range []string{"transactional", "textOnlyTransactional", "abort", "undo", ""} {
		t.Run(mode, func(t *testing.T) {
			server := NewServer(&fakeCompiler{})
			response := completionResponseFor(t, server, "initialize", map[string]any{"capabilities": map[string]any{"workspace": map[string]any{"workspaceEdit": map[string]any{"documentChanges": true, "failureHandling": mode}}}})
			supported := mode == "transactional" || mode == "textOnlyTransactional"
			if response.Error != nil || server.workspaceEditsSupported != supported {
				t.Fatalf("capability negotiation = %+v, enabled=%v", response, server.workspaceEditsSupported)
			}
			if !supported {
				rejected := completionResponseFor(t, server, "textDocument/rename", map[string]any{"newName": "changed"})
				if rejected.Error == nil {
					t.Fatal("non-atomic client offered rename")
				}
			}
		})
	}
}
