package tooling

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
)

func workspaceJSONFixture(t *testing.T) map[string]any {
	t.Helper()
	file := filepath.Join(t.TempDir(), "main.tesl")
	location := map[string]any{"file": file, "line": 0, "col": 0, "end_line": 0, "end_col": 5}
	hash := fmt.Sprintf("%x", md5.Sum([]byte("value"))) // #nosec G401 -- test fixture.
	return map[string]any{"version": 1, "workspace_root": filepath.Dir(file), "snapshot": "snapshot", "coordinate_encoding": "utf-8", "complete": true, "problems": []any{},
		"inputs": []any{map[string]any{"file": file, "content_hash": hash}}, "symbol": map[string]any{"id": "id", "name": "value", "kind": "term", "definition": location, "read_only": false},
		"references": []any{map[string]any{"location": location, "role": "declaration"}},
		"rename":     map[string]any{"safe": true, "new_name": "changed", "expected_snapshot": "snapshot", "reason": nil, "checked": "binding-identity-and-type-proof-check", "files": []any{map[string]any{"file": file, "content_hash": hash, "edits": []any{map[string]any{"location": location, "new_text": "changed"}}}}}}
}

func TestWorkspaceSchemaRejectsUnsafeClaims(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"missing completeness", func(v map[string]any) { delete(v, "complete") }},
		{"partial no reason", func(v map[string]any) { v["complete"] = false }},
		{"wrong coordinates", func(v map[string]any) { v["coordinate_encoding"] = "utf-16" }},
		{"unversioned input", func(v map[string]any) { v["inputs"] = []any{} }},
		{"unknown role", func(v map[string]any) { v["references"].([]any)[0].(map[string]any)["role"] = "text" }},
		{"missing column", func(v map[string]any) { delete(v["symbol"].(map[string]any)["definition"].(map[string]any), "col") }},
		{"stale rename", func(v map[string]any) { v["rename"].(map[string]any)["expected_snapshot"] = "old" }},
		{"unsafe edits", func(v map[string]any) { v["rename"].(map[string]any)["safe"] = false }},
		{"wrong renamed text", func(v map[string]any) { v["rename"].(map[string]any)["new_name"] = "different" }},
		{"incomplete rename", func(v map[string]any) { v["rename"].(map[string]any)["files"] = []any{} }},
		{"duplicate edit", func(v map[string]any) {
			f := v["rename"].(map[string]any)["files"].([]any)[0].(map[string]any)
			f["edits"] = append(f["edits"].([]any), f["edits"].([]any)[0])
		}},
		{"external rename", func(v map[string]any) { v["symbol"].(map[string]any)["read_only"] = true }},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := workspaceJSONFixture(t)
			valid, _ := json.Marshal(fixture)
			if err := ValidateCompilerJSON("--workspace-rename-json", valid); err != nil {
				t.Fatal(err)
			}
			test.mutate(fixture)
			invalid, _ := json.Marshal(fixture)
			if err := ValidateCompilerJSON("--workspace-rename-json", invalid); err == nil {
				t.Fatalf("accepted invalid workspace: %s", invalid)
			}
		})
	}
}

func TestWorkspaceInputBytesAndStrictRanges(t *testing.T) {
	fixture := workspaceJSONFixture(t)
	payload, _ := json.Marshal(fixture)
	var response WorkspaceResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		t.Fatal(err)
	}
	file := response.Inputs[0].File
	if err := os.WriteFile(file, []byte("other"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := WorkspaceInputTexts(context.Background(), response, nil); err == nil {
		t.Fatal("stale unopened file accepted")
	}
	if _, err := WorkspaceInputTexts(context.Background(), response, []SourceOverlay{{Path: file, Source: "value"}}); err != nil {
		t.Fatalf("current dirty overlay rejected: %v", err)
	}
	for _, loc := range []WorkspaceLocation{{Col: 1, EndCol: 4}, {Col: 0, EndCol: 9}, {Line: 3, EndLine: 3}, {Col: 4, EndCol: 0}} {
		if _, _, err := WorkspaceRangeOffsets("😀x\r\n", loc); err == nil {
			t.Fatalf("invalid byte range accepted: %+v", loc)
		}
	}
	first, last, err := WorkspaceRangeOffsets("😀x\r\nvalue", WorkspaceLocation{Line: 1, EndLine: 1, EndCol: 5})
	if err != nil || first != 7 || last != 12 {
		t.Fatalf("CRLF byte offsets: %d %d %v", first, last, err)
	}
}

func TestWorkspaceCapabilityAndRenameFraming(t *testing.T) {
	client := sessionTestClient(t)
	root := t.TempDir()
	path := filepath.Join(root, "main.tesl")
	source := "module Main exposing [value]\nimport Tesl.Prelude exposing [Int]\nfn value(n: Int) -> Int = n\n"
	if err := os.WriteFile(path, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	payload, _, err := client.QuerySourceJSON(context.Background(), "--workspace-references-json", path, source, "2", "3")
	if err != nil {
		t.Fatal(err)
	}
	var response WorkspaceResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		t.Fatal(err)
	}
	if response.Root != root || strings.Contains(string(payload), "tesl-workspace-") {
		t.Fatalf("mirror path escaped: %s", payload)
	}
	for _, name := range []string{"first", "second"} {
		payload, _, err = client.QuerySourceJSON(context.Background(), "--workspace-rename-json", path, source, "2", "3", name, response.Snapshot)
		if err != nil {
			t.Fatal(err)
		}
		var renamed WorkspaceResponse
		_ = json.Unmarshal(payload, &renamed)
		if renamed.Rename == nil || !renamed.Rename.Safe || renamed.Rename.NewName != name {
			t.Fatalf("rename arguments omitted from framing/cache: %s", payload)
		}
	}
	if _, _, err = client.QuerySourceJSON(context.Background(), "--type-at-json", path, source, "2", "26"); err != nil {
		t.Fatalf("five-frame request after rename: %v", err)
	}
	if client.Sessions == nil {
		t.Fatal("workspace queries did not retain a compiler session")
	}
	if client.Sessions.starts != 1 {
		t.Fatalf("session restarted: %d", client.Sessions.starts)
	}
	legacy := Client{Executable: testExecutable(t), Sessions: NewWorkspaceSessions(), Environment: withEnvironment(os.Environ(), "TESL_SESSION_TEST_HELPER", "ok")}
	defer func() { _ = legacy.Close() }()
	if _, _, err = legacy.QuerySourceJSON(context.Background(), "--workspace-references-json", path, source, "2", "3"); err == nil || !strings.Contains(err.Error(), "capability") {
		t.Fatalf("legacy capability not rejected: %v", err)
	}
}

func TestWorkspaceCanonicalTemporaryDirectoryNeverEscapesMapping(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinked temporary-parent fixture requires Unix symlink permissions")
	}
	client := sessionTestClient(t)
	root := t.TempDir()
	entry := filepath.Join(root, "main.tesl")
	source := "module Main exposing [value]\nimport Tesl.Prelude exposing [Int]\nfn value(n: Int) -> Int = n\n"
	if err := os.WriteFile(entry, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	parent := t.TempDir()
	real := filepath.Join(parent, "real")
	alias := filepath.Join(parent, "alias")
	if err := os.Mkdir(real, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, alias); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", alias)
	for _, retained := range []bool{false, true} {
		t.Run(fmt.Sprintf("retained=%v", retained), func(t *testing.T) {
			queryClient := client
			if !retained {
				queryClient.Sessions = nil
			}
			payload, _, err := queryClient.QuerySourceJSON(context.Background(), "--workspace-references-json", entry, source, "2", "3")
			if err != nil {
				t.Fatal(err)
			}
			var response WorkspaceResponse
			if err := json.Unmarshal(payload, &response); err != nil {
				t.Fatal(err)
			}
			if response.Root != root || len(response.Inputs) != 1 || response.Inputs[0].File != entry || strings.Contains(string(payload), parent) {
				t.Fatalf("canonical temporary path leaked into response: %s", payload)
			}
			payload, _, err = queryClient.QuerySourceJSON(context.Background(), "--workspace-rename-json", entry, source, "2", "3", "renamed", response.Snapshot)
			if err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(payload, &response); err != nil {
				t.Fatal(err)
			}
			if response.Rename == nil || !response.Rename.Safe || len(response.Rename.Files) != 1 || response.Rename.Files[0].File != entry {
				t.Fatalf("rename failed or returned a temporary path: %s", payload)
			}
		})
	}
}

func TestWorkspaceInvalidRenameArgumentsNeverWriteFrames(t *testing.T) {
	process := &workspaceProcess{capabilities: map[string]bool{"workspace-navigation": true, "workspace-rename-arguments-v1": true}}
	for _, args := range [][]string{nil, {"0"}, {"0", "0"}, {"0", "0", "name"}} {
		if _, _, err := process.query(context.Background(), "snapshot", "--workspace-rename-json", "file", args, 1024); err == nil {
			t.Fatalf("invalid rename arguments accepted: %v", args)
		}
	}
}
