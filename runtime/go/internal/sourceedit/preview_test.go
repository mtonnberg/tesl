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

func TestContractSourcePreviewUsesExistingGuards(t *testing.T) {
	raw := bytes.Replace(previewVector(t), []byte(`"operation":"start"`), []byte(`"operation":"contract"`), 1)
	preview, err := DecodePreview(raw)
	if err != nil || preview == nil {
		t.Fatal(err)
	}
	if preview.Operation() != "contract" || preview.Manifest().Digest() == "" {
		t.Fatal("contract lost exact source guards")
	}
	raw = bytes.Replace(raw, []byte(`"manifest":`), []byte(`"untrustedManifest":`), 1)
	if _, err := DecodePreview(raw); err == nil {
		t.Fatal("contract bypassed exact envelope")
	}
}

func TestSourcePreviewAdvisoryDecisionsKeepAuthoritySeparate(t *testing.T) {
	base := previewVector(t)
	old, err := DecodePreview(base)
	if err != nil {
		t.Fatal(err)
	}
	decision := `[{"id":"entity:Note","entity":"Note","file":"migration.tesl","line":20,"col":4,"reason":"choose a value","options":[{"id":"additive-default","label":"Choose defaults","template":"Additive [Default title (todo \"Choose a String literal\")]","help":"Replace the typed hole and recheck","needsCustomCode":true}]}]`
	with := func(value string) []byte {
		return append(append(bytes.Clone(base[:len(base)-1]), []byte(`,"decisions":`+value)...), '}')
	}
	p, err := DecodePreview(with(decision))
	if err != nil {
		t.Fatal(err)
	}
	if p.Manifest().Digest() != old.Manifest().Digest() || p.Compilable() != old.Compilable() {
		t.Fatal("advisory options changed source authority or compiler judgment")
	}
	for _, invalid := range []string{
		`null`, `{}`, `[{}]`, strings.Replace(decision, `"line":20`, `"line":-1`, 1),
		strings.Replace(decision, `"options":[`, `"options":null,"unknown":[`, 1),
		strings.Replace(decision, `"needsCustomCode":true`, `"needsCustomCode":null`, 1),
		strings.Replace(decision, `"entity":"Note"`, `"entity":null`, 1),
		strings.Replace(decision, `"line":20`, `"line":"20"`, 1),
	} {
		if _, err := DecodePreview(with(invalid)); err == nil {
			t.Fatalf("invalid advisory metadata accepted: %s", invalid)
		}
	}
}

func TestSourcePreviewInputDigestPinsChoiceWithoutGrantingWrites(t *testing.T) {
	base := previewVector(t)
	before, err := DecodePreview(base)
	if err != nil {
		t.Fatal(err)
	}
	if before.InputDigest() != "" {
		t.Fatal("legacy proposal invented a choice precondition")
	}
	with := func(value string) []byte {
		return append(append(bytes.Clone(base[:len(base)-1]), []byte(`,"inputDigest":`+value)...), '}')
	}
	digest := strings.Repeat("a", 64)
	p, err := DecodePreview(with(`"` + digest + `"`))
	if err != nil || p.InputDigest() != digest {
		t.Fatalf("lost compiler choice precondition: %v", err)
	}
	if p.Manifest().Digest() != before.Manifest().Digest() || p.Compilable() != before.Compilable() {
		t.Fatal("choice precondition changed source authority or compiler judgment")
	}
	for _, invalid := range []string{`null`, `42`, `true`, `""`, `"abc"`, `"` + strings.Repeat("A", 64) + `"`, `"` + strings.Repeat("g", 64) + `"`} {
		if _, err := DecodePreview(with(invalid)); err == nil {
			t.Fatalf("accepted invalid choice digest %s", invalid)
		}
	}
}
