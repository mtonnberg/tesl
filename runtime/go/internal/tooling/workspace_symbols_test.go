package tooling

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func symbolsPayload(t *testing.T, edit func(map[string]any)) []byte {
	t.Helper()
	response := map[string]any{"version": 1, "workspace_root": "/project", "snapshot": "s", "coordinate_encoding": "utf-8",
		"complete": true, "problems": []any{}, "inputs": []any{map[string]any{"file": "/project/lib.tesl", "content_hash": strings.Repeat("a", 32)}},
		"query": "dou", "truncated": false,
		"symbols": []any{map[string]any{"name": "double", "kind": "term", "container": "Lib", "read_only": false,
			"definition": map[string]any{"file": "/project/lib.tesl", "line": 2, "col": 3, "end_line": 2, "end_col": 9}}}}
	if edit != nil {
		edit(response)
	}
	payload, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func TestWorkspaceSymbolsValidation(t *testing.T) {
	if err := ValidateCompilerJSON("--workspace-symbols-json", symbolsPayload(t, nil)); err != nil {
		t.Fatalf("valid response rejected: %v", err)
	}
	symbol := func(response map[string]any) map[string]any {
		return response["symbols"].([]any)[0].(map[string]any)
	}
	for name, edit := range map[string]func(map[string]any){
		"unknown kind":          func(r map[string]any) { symbol(r)["kind"] = "module" },
		"missing container":     func(r map[string]any) { delete(symbol(r), "container") },
		"definition not input":  func(r map[string]any) { symbol(r)["definition"].(map[string]any)["file"] = "/project/other.tesl" },
		"truncated not boolean": func(r map[string]any) { r["truncated"] = "no" },
		"complete with problem": func(r map[string]any) {
			r["problems"] = []any{map[string]any{"code": "parse-error", "file": "/project/x.tesl", "message": "bad"}}
		},
		"relative root":   func(r map[string]any) { r["workspace_root"] = "project" },
		"oversize query":  func(r map[string]any) { r["query"] = strings.Repeat("q", MaxWorkspaceSymbolQuery+1) },
		"missing symbols": func(r map[string]any) { delete(r, "symbols") },
	} {
		if err := ValidateCompilerJSON("--workspace-symbols-json", symbolsPayload(t, edit)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestWorkspaceSymbolsSessionArgumentsAndCapability(t *testing.T) {
	without := &workspaceProcess{capabilities: map[string]bool{"workspace-navigation": true}}
	if _, _, err := without.query(context.Background(), "snapshot", "--workspace-symbols-json", "file", []string{"q"}, 1024); err == nil ||
		!strings.Contains(err.Error(), "symbol search capability") {
		t.Fatalf("older compiler session accepted symbol search: %v", err)
	}
	process := &workspaceProcess{capabilities: map[string]bool{"workspace-navigation": true, "workspace-symbols-v1": true}}
	for _, args := range [][]string{nil, {"0", "0"}, {"a", "b", "c"}} {
		if _, _, err := process.query(context.Background(), "snapshot", "--workspace-symbols-json", "file", args, 1024); err == nil {
			t.Fatalf("invalid symbol arguments accepted: %v", args)
		}
	}
}

func TestWorkspaceTypeDefinitionRequiresCapability(t *testing.T) {
	process := &workspaceProcess{capabilities: map[string]bool{"workspace-navigation": true}}
	if _, _, err := process.query(context.Background(), "snapshot", "--workspace-type-definition-json", "file", []string{"0", "0"}, 1024); err == nil ||
		!strings.Contains(err.Error(), "type definition capability") {
		t.Fatalf("older compiler session accepted type definition: %v", err)
	}
}
