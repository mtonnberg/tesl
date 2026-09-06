package sourceedit

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func previewVector(t *testing.T) []byte {
	t.Helper()
	fields := map[string]any{
		"version": 1, "kind": "migration-source-preview", "ok": true, "operation": "start",
		"compilerAbi": "tesl-source-abi-v1:" + strings.Repeat("a", 64), "compilable": true,
		"selection":   map[string]any{"entryFile": "app.tesl", "databaseFile": "app.tesl", "database": "App.Main", "family": "NotesSchema", "schemaRoot": "NotesSchema.VCurrent", "previousVersion": nil, "revisionBefore": 1, "revisionAfter": 2},
		"diagnostics": map[string]any{"version": 1, "diagnostics": []any{}}, "manifest": json.RawMessage(vector(t)),
	}
	data, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
func TestSourcePreviewDecoder(t *testing.T) {
	raw := previewVector(t)
	p, err := DecodePreview(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !p.Compilable() || p.CompilerABI() != "tesl-source-abi-v1:"+strings.Repeat("a", 64) {
		t.Fatal("lost compiler judgment")
	}
	if p.EntryFile() != "app.tesl" || p.Database() != "App.Main" || p.Operation() != "start" {
		t.Fatal("lost selected application or operation")
	}
	versions := p.Manifest().DocumentVersions()
	for path, version := range versions {
		versions[path] = version + 1
		if p.Manifest().DocumentVersions()[path] != version {
			t.Fatal("mutable document guards")
		}
	}
	snapshot := p.JSON()
	raw[0] = '!'
	snapshot[0] = '!'
	if p.JSON()[0] != '{' {
		t.Fatal("preview is mutable through caller bytes")
	}
	m, err := Decode(p.Manifest().JSON())
	if err != nil || m.Digest() != p.Manifest().Digest() {
		t.Fatal("lost immutable manifest")
	}
	raw = previewVector(t)
	raw = bytes.Replace(raw, []byte(`"compilable":true`), []byte(`"compilable":false`), 1)
	raw = bytes.Replace(raw, []byte(`"diagnostics":[]`), []byte(`"diagnostics":[{"severity":"error","code":"MIG003"}]`), 1)
	p, err = DecodePreview(raw)
	if err != nil || p.Compilable() {
		t.Fatalf("decision holes must remain applicable sources: %v", err)
	}
}
func TestSourcePreviewRejectsUnsupportedJudgment(t *testing.T) {
	for _, mutation := range [][2]string{
		{`"version":1`, `"version":2`}, {`"ok":true`, `"ok":false`}, {`"ok":true`, `"ok":null`},
		{`"operation":"start"`, `"operation":"unknown"`}, {`"kind":"migration-source-preview"`, `"kind":"database-plan"`},
		{`"compilable":true`, `"compilable":null`}, {`"compilable":true`, `"compilable":false`},
		{`"diagnostics":[]`, `"diagnostics":null`}, {`"diagnostics":[]`, `"diagnostics":[{"severity":"error"}]`},
		{`"diagnostics":[]`, `"diagnostics":[{"severity":"guessed"}]`}, {`"ok":true`, `"ok":true,"ok":true`},
		{`"ok":true`, `"OK":true`}, {`tesl-source-abi-v1:`, `unknown-abi:`}, {`"selection":{`, `"selection":{"unexpected":1,`},
		{`"entryFile":"app.tesl"`, `"entryFile":null`}, {`"database":"App.Main"`, `"database":19`},
	} {
		t.Run(mutation[1], func(t *testing.T) {
			raw := bytes.ReplaceAll(previewVector(t), []byte(mutation[0]), []byte(mutation[1]))
			if _, err := DecodePreview(raw); err == nil {
				t.Fatal("invalid preview accepted")
			}
		})
	}
}
