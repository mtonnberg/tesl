package sourceedit

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// This literal is a producer-independent format vector. It includes an absent
// file, an existing empty file and a virtual preimage; those are distinct states.
func vector(t *testing.T) []byte {
	t.Helper()
	root := t.TempDir()
	q := func(s string) string { b, _ := json.Marshal(s); return string(b) }
	empty := `"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"`
	return []byte(`{"version":1,"projectRoot":` + q(root) + `,"documents":[{"path":` + q(filepath.Join(root, "c.tesl")) + `,"version":-4}],"imports":[],"inputs":[` +
		`{"path":` + q(filepath.Join(root, "a.tesl")) + `,"sourceHash":null,"diskHash":null},` +
		`{"path":` + q(filepath.Join(root, "b.tesl")) + `,"sourceHash":` + empty + `,"diskHash":` + empty + `},` +
		`{"path":` + q(filepath.Join(root, "c.tesl")) + `,"sourceHash":` + empty + `,"diskHash":null}],` +
		`"directories":[{"path":` + q(root) + `,"sourceHash":` + empty + `,"diskHash":` + empty + `}],` +
		`"edits":[{"path":` + q(filepath.Join(root, "a.tesl")) + `,"beforeHex":null,"afterHex":"61","documentVersion":null},` +
		`{"path":` + q(filepath.Join(root, "b.tesl")) + `,"beforeHex":"","afterHex":"6262","documentVersion":null},` +
		`{"path":` + q(filepath.Join(root, "c.tesl")) + `,"beforeHex":"","afterHex":"636363","documentVersion":-4}]}`)
}
func TestSourceManifestIndependentVector(t *testing.T) {
	raw := vector(t)
	m, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(raw, m.JSON()) || hash(raw) != m.Digest() {
		t.Fatalf("canonical vector changed: %s", m.JSON())
	}
	for path, version := range m.DocumentVersions() {
		if !m.MatchesDocument(path, version, "") || m.MatchesDocument(path, version+1, "") || m.MatchesDocument(path, version, "changed") || m.MatchesDocument(path+"x", version, "") {
			t.Fatal("editor guard did not bind exact version and bytes")
		}
	}
	returned := m.JSON()
	returned[0] = '!'
	if !bytes.Equal(raw, m.JSON()) {
		t.Fatal("mutable validated manifest")
	}
	raw[0] = '!'
	if m.JSON()[0] != '{' {
		t.Fatal("retains caller-owned input bytes")
	}
}
func TestSourceManifestEmptyAndNullRemainDistinct(t *testing.T) {
	raw := vector(t)
	m, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if m.wire.Edits[0].BeforeHex != nil || m.wire.Edits[1].BeforeHex == nil || *m.wire.Edits[1].BeforeHex != "" {
		t.Fatal("collapsed absent and empty preimages")
	}
	if m.wire.Inputs[2].DiskHash != nil || m.wire.Inputs[2].SourceHash == nil {
		t.Fatal("collapsed disk and source view")
	}
}

func TestSourceManifestOpenDocumentRequiresPresentSource(t *testing.T) {
	var object map[string]any
	if err := json.Unmarshal(vector(t), &object); err != nil {
		t.Fatal(err)
	}
	object["inputs"].([]any)[2].(map[string]any)["sourceHash"] = json.RawMessage("null")
	data, err := json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Decode(data); err == nil || !strings.Contains(err.Error(), "document lacks input guard") {
		t.Fatalf("open buffer can masquerade as absent source: %v", err)
	}
}

func TestSourceManifestFilePreviewsAreIndependent(t *testing.T) {
	m, err := Decode(vector(t))
	if err != nil {
		t.Fatal(err)
	}
	files := m.FileEdits()
	if len(files) != 3 || !files[0].Creates || files[1].Creates || files[2].DocumentVersion == nil || *files[2].DocumentVersion != -4 {
		t.Fatalf("preview lost create/empty/open distinctions: %+v", files)
	}
	before, after, found := m.FileContents(files[2].Path)
	if !found || len(before) != 0 || len(after) != 3 || string(after) != "ccc" {
		t.Fatal("wrong preview contents")
	}
	after[0] = '!'
	*files[2].DocumentVersion = 99
	_, again, _ := m.FileContents(files[2].Path)
	fresh := m.FileEdits()
	if string(again) != "ccc" || len(fresh) != 3 || fresh[2].DocumentVersion == nil || *fresh[2].DocumentVersion != -4 {
		t.Fatal("preview mutated manifest authority")
	}
	if before, after, found := m.FileContents(files[2].Path + "x"); found || before != nil || after != nil {
		t.Fatal("invented preview source")
	}
}
func TestSourceManifestCanonicalUnicodeAndPunctuation(t *testing.T) {
	for _, text := range []string{"å<>&\u2028\u2029", "tab\tline\nreturn\rback\bform\f", "😀"} {
		got := quote(text)
		var decoded string
		if err := json.Unmarshal([]byte(got), &decoded); err != nil || decoded != text {
			t.Fatalf("quote: %q, %v", got, err)
		}
		if strings.Contains(got, `\u003c`) || strings.Contains(got, `\u2028`) || strings.Contains(got, `\n`) {
			t.Fatalf("not the compiler's byte encoding: %q", got)
		}
	}
	raw := vector(t)
	var v map[string]any
	_ = json.Unmarshal(raw, &v)
	root := v["projectRoot"].(string)
	newRoot := root + "å<>&\u2028\u2029😀"
	raw = bytes.ReplaceAll(raw, []byte(root), []byte(newRoot))
	m, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(raw, m.JSON()) {
		t.Fatal("UTF-8 canonical bytes changed")
	}
}
func TestSourceManifestWhitespaceDoesNotChangeIdentity(t *testing.T) {
	raw := vector(t)
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, raw, "", "  "); err != nil {
		t.Fatal(err)
	}
	a, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Decode(pretty.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if a.Digest() != b.Digest() {
		t.Fatal("identity hashes formatting instead of canonical manifest")
	}
}
func TestSourceManifestRejectsAmbiguousJSON(t *testing.T) {
	raw := vector(t)
	for _, change := range []struct {
		name   string
		change func([]byte) []byte
	}{
		{"duplicate key", func(b []byte) []byte {
			return bytes.Replace(b, []byte(`"version":1`), []byte(`"version":1,"version":1`), 1)
		}},
		{"nested duplicate", func(b []byte) []byte {
			return bytes.Replace(b, []byte(`"sourceHash":null`), []byte(`"sourceHash":null,"sourceHash":null`), 1)
		}},
		{"case alias", func(b []byte) []byte { return bytes.Replace(b, []byte(`"version":1`), []byte(`"Version":1`), 1) }},
		{"trailing object", func(b []byte) []byte { return append(b, []byte(`{}`)...) }},
		{"invalid UTF8", func(b []byte) []byte { return append(b, 0xff) }},
		{"lone high surrogate", func(b []byte) []byte { return bytes.Replace(b, []byte(`a.tesl`), []byte(`\ud800.tesl`), 1) }},
		{"lone low surrogate", func(b []byte) []byte { return bytes.Replace(b, []byte(`a.tesl`), []byte(`\udc00.tesl`), 1) }},
		{"high then non-low", func(b []byte) []byte { return bytes.Replace(b, []byte(`a.tesl`), []byte(`\ud800\u0041.tesl`), 1) }},
	} {
		t.Run(change.name, func(t *testing.T) {
			if _, err := Decode(change.change(bytes.Clone(raw))); err == nil {
				t.Fatal("ambiguous JSON accepted")
			}
		})
	}
}
func TestSourceManifestRejectsIncompleteOrInconsistentGuards(t *testing.T) {
	raw := vector(t)
	records := func(m map[string]any, key string) []any { return m[key].([]any) }
	first := func(m map[string]any, key string) map[string]any { return records(m, key)[0].(map[string]any) }
	cases := []struct {
		name   string
		change func(map[string]any)
	}{
		{"version", func(m map[string]any) { m["version"] = 2 }},
		{"fractional version", func(m map[string]any) { m["version"] = 1.5 }},
		{"missing collection", func(m map[string]any) { delete(m, "inputs") }},
		{"null collection", func(m map[string]any) { m["edits"] = nil }},
		{"unknown field", func(m map[string]any) { m["extra"] = true }},
		{"missing nullable guard", func(m map[string]any) { delete(first(m, "inputs"), "diskHash") }},
		{"null replacement", func(m map[string]any) { first(m, "edits")["afterHex"] = nil }},
		{"missing replacement", func(m map[string]any) { delete(first(m, "edits"), "afterHex") }},
		{"null document version", func(m map[string]any) { first(m, "documents")["version"] = nil }},
		{"large document version", func(m map[string]any) { first(m, "documents")["version"] = 2147483648 }},
		{"unknown preimage", func(m map[string]any) { first(m, "edits")["beforeHex"] = "" }},
		{"invalid source hash", func(m map[string]any) { first(m, "inputs")["sourceHash"] = "bad" }},
		{"uppercase hash", func(m map[string]any) { records(m, "inputs")[1].(map[string]any)["diskHash"] = strings.Repeat("A", 64) }},
		{"odd hex", func(m map[string]any) { first(m, "edits")["afterHex"] = "a" }},
		{"uppercase hex", func(m map[string]any) { first(m, "edits")["afterHex"] = "AA" }},
		{"false preimage", func(m map[string]any) { records(m, "edits")[1].(map[string]any)["beforeHex"] = "00" }},
		{"no-op edit", func(m map[string]any) { records(m, "edits")[1].(map[string]any)["afterHex"] = "" }},
		{"unguarded edit", func(m map[string]any) {
			first(m, "edits")["path"] = filepath.Join(m["projectRoot"].(string), "other.tesl")
		}},
		{"duplicate input", func(m map[string]any) { m["inputs"] = append(records(m, "inputs"), records(m, "inputs")[0]) }},
		{"unsorted inputs", func(m map[string]any) { v := records(m, "inputs"); v[0], v[1] = v[1], v[0] }},
		{"file-directory conflict", func(m map[string]any) { m["directories"] = append(records(m, "directories"), first(m, "inputs")) }},
		{"missing root guard", func(m map[string]any) { m["directories"] = []any{} }},
		{"absent project", func(m map[string]any) { first(m, "directories")["diskHash"] = nil }},
		{"missing parent guard", func(m map[string]any) {
			first(m, "inputs")["path"] = filepath.Join(m["projectRoot"].(string), "new", "a.tesl")
		}},
		{"outside input", func(m map[string]any) {
			first(m, "inputs")["path"] = filepath.Join(filepath.Dir(m["projectRoot"].(string)), "outside.tesl")
		}},
		{"relative root", func(m map[string]any) { m["projectRoot"] = "project" }},
		{"traversal spelling", func(m map[string]any) {
			first(m, "inputs")["path"] = m["projectRoot"].(string) + string(filepath.Separator) + "child/../a.tesl"
		}},
		{"version mismatch", func(m map[string]any) { records(m, "edits")[2].(map[string]any)["documentVersion"] = 8 }},
		{"closed document has version", func(m map[string]any) { first(m, "edits")["documentVersion"] = 1 }},
		{"missing open version", func(m map[string]any) { records(m, "edits")[2].(map[string]any)["documentVersion"] = nil }},
		{"untracked import", func(m map[string]any) {
			m["imports"] = []any{map[string]any{"source": first(m, "inputs")["path"], "module": "Other", "sourceResolved": filepath.Join(m["projectRoot"].(string), "other.tesl"), "diskResolved": filepath.Join(m["projectRoot"].(string), "other.tesl")}}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var m map[string]any
			if err := json.Unmarshal(raw, &m); err != nil {
				t.Fatal(err)
			}
			c.change(m)
			bad, _ := json.Marshal(m)
			if _, err := Decode(bad); err == nil {
				t.Fatalf("accepted inconsistent manifest: %s", bad)
			}
		})
	}
}
func compilerManifest(t *testing.T, prepare ...func(string)) (string, map[string]string, json.RawMessage) {
	t.Helper()
	// The compiler and this consumer must independently agree on exact canonical
	// bytes, nullable guards and digest; a manually duplicated Go fixture is not
	// the producer/consumer oracle.
	repo := os.Getenv("TESL_REPO_ROOT")
	if repo == "" {
		t.Skip("requires TESL_REPO_ROOT and built compiler")
	}
	compiler := filepath.Join(repo, "compiler", "_build", "default", "bin", "main.exe")
	if _, err := os.Stat(compiler); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	path := func(s string) string { return filepath.Join(root, filepath.FromSlash(s)) }
	sources := map[string]string{
		"tesl.toml":                   "",
		"app.tesl":                    "module App exposing []\nimport Tesl.Database exposing [Database, Memory]\nimport NotesSchema.VCurrent\ndatabase Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }\n",
		"schema/notes/v-current.tesl": "module NotesSchema.VCurrent exposing [Note]\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String }\n",
	}
	for name, source := range sources {
		if err := os.MkdirAll(filepath.Dir(path(name)), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path(name), []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range prepare {
		f(root)
	}
	for name := range sources {
		if strings.HasSuffix(name, ".tesl") {
			cmd := exec.Command(compiler, "agent-context", path(name))
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("fixture diagnostics: %s %v", out, err)
			}
		}
	}
	cmd := exec.Command(compiler, "migrate", "generate", path("app.tesl"), "--manifest-json")
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	var response struct {
		OK         bool            `json:"ok"`
		Compilable bool            `json:"compilable"`
		Manifest   json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(out, &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || !response.Compilable {
		t.Fatalf("preview: %s", out)
	}
	return root, sources, response.Manifest
}
func TestSourceManifestCompilerOracle(t *testing.T) {
	root, sources, raw := compilerManifest(t)
	path := func(s string) string { return filepath.Join(root, filepath.FromSlash(s)) }
	m, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(raw, m.JSON()) || hash(raw) != m.Digest() {
		t.Fatalf("compiler/consumer canonical mismatch\n%s\n%s", raw, m.JSON())
	}
	if m.ProjectRoot() != root || len(m.wire.Edits) != 2 {
		t.Fatalf("bad selected project or edit count: %+v", m.wire)
	}
	for name, source := range sources {
		got, err := os.ReadFile(path(name))
		if err != nil || string(got) != source {
			t.Fatal("consumer wrote source")
		}
	}
}

func TestSourceManifestEscapedSurrogatePair(t *testing.T) {
	raw := vector(t)
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	root := decoded["projectRoot"].(string)
	actual := bytes.ReplaceAll(raw, []byte(root), []byte(root+"😀"))
	escaped := bytes.ReplaceAll(actual, []byte("😀"), []byte(`\ud83d\ude00`))
	a, err := Decode(actual)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Decode(escaped)
	if err != nil {
		t.Fatal(err)
	}
	if a.Digest() != b.Digest() {
		t.Fatal("UTF-16 pair changes decoded path identity")
	}
}
func FuzzSourceManifestDecode(f *testing.F) {
	root := filepath.Join(os.TempDir(), "tesl-manifest-fuzz")
	digest := strings.Repeat("0", 64)
	seed := encode(wireManifest{Version: 1, ProjectRoot: root, Directories: []directory{{Path: root, SourceHash: &digest, DiskHash: &digest}}})
	f.Add(seed)
	f.Add([]byte(`{"version":1,"version":2}`))
	f.Add([]byte(`null`))
	f.Add([]byte("\xff"))
	f.Fuzz(func(t *testing.T, raw []byte) {
		if len(raw) > 1<<20 {
			t.Skip()
		}
		m, err := Decode(raw)
		if err != nil {
			return
		}
		again, err := Decode(m.JSON())
		if err != nil {
			t.Fatalf("accepted manifest cannot roundtrip: %v", err)
		}
		if m.Digest() != again.Digest() || !bytes.Equal(m.JSON(), again.JSON()) {
			t.Fatal("canonical manifest is unstable")
		}
		if m.Digest() != hash(m.JSON()) {
			t.Fatal("manifest digest differs from its canonical bytes")
		}
	})
}
