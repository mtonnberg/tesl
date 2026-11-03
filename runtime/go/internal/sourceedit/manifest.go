// Package sourceedit consumes compiler-owned source edit manifests. A manifest
// grants no database execution authority and does not attest program correctness.
package sourceedit

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"
)

const maxManifestBytes = 64 << 20

type document struct {
	Path    string `json:"path"`
	Version int32  `json:"version"`
}
type input struct {
	Path       string  `json:"path"`
	SourceHash *string `json:"sourceHash"`
	DiskHash   *string `json:"diskHash"`
}
type directory = input
type importGuard struct {
	Source         string `json:"source"`
	Module         string `json:"module"`
	SourceResolved string `json:"sourceResolved"`
	DiskResolved   string `json:"diskResolved"`
}
type edit struct {
	Path            string  `json:"path"`
	BeforeHex       *string `json:"beforeHex"`
	AfterHex        string  `json:"afterHex"`
	DocumentVersion *int32  `json:"documentVersion"`
}
type wireManifest struct {
	Version     int           `json:"version"`
	ProjectRoot string        `json:"projectRoot"`
	Documents   []document    `json:"documents"`
	Imports     []importGuard `json:"imports"`
	Inputs      []input       `json:"inputs"`
	Directories []directory   `json:"directories"`
	Edits       []edit        `json:"edits"`
}

// Manifest is immutable after decoding. Accessors return copies, never mutable
// references to validated guards. Decode does no filesystem operations.
type Manifest struct {
	wire      wireManifest
	canonical []byte
	digest    string
}

func (m *Manifest) ProjectRoot() string { return m.wire.ProjectRoot }
func (m *Manifest) Digest() string      { return m.digest }
func (m *Manifest) JSON() []byte        { return bytes.Clone(m.canonical) }
func (m *Manifest) DocumentVersions() map[string]int32 {
	versions := make(map[string]int32, len(m.wire.Documents))
	for _, document := range m.wire.Documents {
		versions[document.Path] = document.Version
	}
	return versions
}

// MatchesDocument checks both the editor version and the exact source captured
// by the compiler. A version alone cannot detect an accidentally ignored overlay.
func (m *Manifest) MatchesDocument(path string, version int32, source string) bool {
	found := false
	for _, document := range m.wire.Documents {
		if document.Path == path && document.Version == version {
			found = true
			break
		}
	}
	if !found {
		return false
	}
	for _, input := range m.wire.Inputs {
		if input.Path == path {
			return input.SourceHash != nil && *input.SourceHash == hash([]byte(source))
		}
	}
	return false
}

type FileEdit struct {
	Path            string `json:"path"`
	Creates         bool   `json:"creates"`
	DocumentVersion *int32 `json:"documentVersion"`
}

// FileEdits is a compact inventory for an editor preview. FileContents decodes
// only the selected file, so a multi-file preview need not send the full manifest.
func (m *Manifest) FileEdits() []FileEdit {
	files := make([]FileEdit, 0, len(m.wire.Edits))
	for _, edit := range m.wire.Edits {
		file := FileEdit{Path: edit.Path, Creates: edit.BeforeHex == nil}
		if edit.DocumentVersion != nil {
			version := *edit.DocumentVersion
			file.DocumentVersion = &version
		}
		files = append(files, file)
	}
	return files
}

func (m *Manifest) FileContents(path string) (before, after []byte, found bool) {
	for _, edit := range m.wire.Edits {
		if edit.Path == path {
			if edit.BeforeHex != nil {
				before, _ = hex.DecodeString(*edit.BeforeHex)
			}
			after, _ = hex.DecodeString(edit.AfterHex)
			return before, after, true
		}
	}
	return nil, nil, false
}
func hash(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func validHex(s string) bool {
	if len(s)%2 != 0 {
		return false
	}
	for _, c := range s {
		if c >= '0' && c <= '9' {
			continue
		}
		if c >= 'a' && c <= 'f' {
			continue
		}
		return false
	}
	return true
}

func validHash(s *string) bool { return s == nil || (len(*s) == 64 && validHex(*s)) }
func same[T comparable](a, b *T) bool {
	return (a == nil && b == nil) || (a != nil && b != nil && *a == *b)
}

// JSON object keys are case-sensitive and unique. encoding/json alone accepts
// duplicate keys and folds case when matching struct fields, which cannot be
// allowed to reinterpret a reviewed source operation.
func strictJSON(data []byte) error {
	if len(data) > maxManifestBytes || !utf8.Valid(data) {
		return fmt.Errorf("manifest exceeds its byte limit or is not UTF-8")
	}
	// Reject lone escaped UTF-16 surrogates instead of silently replacing them.
	for i := 0; i < len(data); i++ {
		if data[i] != '"' {
			continue
		}
		i++
		for ; i < len(data) && data[i] != '"'; i++ {
			if data[i] != '\\' {
				continue
			}
			i++
			if i >= len(data) {
				break
			}
			if data[i] != 'u' {
				continue
			}
			if i+4 >= len(data) {
				break
			}
			n, err := strconv.ParseUint(string(data[i+1:i+5]), 16, 16)
			if err != nil {
				return err
			}
			i += 4
			if n >= 0xdc00 && n <= 0xdfff {
				return fmt.Errorf("unpaired JSON surrogate")
			}
			if n >= 0xd800 && n <= 0xdbff {
				if i+6 >= len(data) || data[i+1] != '\\' || data[i+2] != 'u' {
					return fmt.Errorf("unpaired JSON surrogate")
				}
				low, err := strconv.ParseUint(string(data[i+3:i+7]), 16, 16)
				if err != nil || low < 0xdc00 || low > 0xdfff {
					return fmt.Errorf("unpaired JSON surrogate")
				}
				i += 6
			}
		}
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var value func(int) error
	value = func(depth int) error {
		if depth > 64 {
			return fmt.Errorf("manifest nesting limit exceeded")
		}
		token, err := d.Token()
		if err != nil {
			return err
		}
		delimiter, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delimiter {
		case '{':
			seen := map[string]bool{}
			for d.More() {
				k, err := d.Token()
				if err != nil {
					return err
				}
				key, ok := k.(string)
				if !ok || seen[key] {
					return fmt.Errorf("invalid or duplicate JSON key %v", k)
				}
				seen[key] = true
				if err := value(depth + 1); err != nil {
					return err
				}
			}
		case '[':
			for d.More() {
				if err := value(depth + 1); err != nil {
					return err
				}
			}
		default:
			return fmt.Errorf("unexpected JSON delimiter")
		}
		_, err = d.Token()
		return err
	}
	if err := value(0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return fmt.Errorf("trailing JSON data")
	}
	return nil
}
func object(data []byte, keys ...string) (map[string]json.RawMessage, error) {
	var result map[string]json.RawMessage
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, err
	}
	if len(result) != len(keys) {
		return nil, fmt.Errorf("missing or unknown manifest fields")
	}
	for _, k := range keys {
		if _, ok := result[k]; !ok {
			return nil, fmt.Errorf("missing manifest field %s", k)
		}
	}
	return result, nil
}
func arrayObjects(data []byte, keys ...string) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || data[0] != '[' {
		return fmt.Errorf("manifest collection must be an array")
	}
	var values []json.RawMessage
	if err := json.Unmarshal(data, &values); err != nil {
		return err
	}
	for _, v := range values {
		if _, err := object(v, keys...); err != nil {
			return err
		}
	}
	return nil
}
func Decode(data []byte) (*Manifest, error) {
	if err := strictJSON(data); err != nil {
		return nil, err
	}
	fields, err := object(data, "version", "projectRoot", "documents", "imports", "inputs", "directories", "edits")
	if err != nil {
		return nil, err
	}
	for _, spec := range [][]string{{"documents", "path", "version"}, {"imports", "source", "module", "sourceResolved", "diskResolved"}, {"inputs", "path", "sourceHash", "diskHash"}, {"directories", "path", "sourceHash", "diskHash"}, {"edits", "path", "beforeHex", "afterHex", "documentVersion"}} {
		if err := arrayObjects(fields[spec[0]], spec[1:]...); err != nil {
			return nil, fmt.Errorf("%s: %w", spec[0], err)
		}
	}
	var w wireManifest
	if err := json.Unmarshal(data, &w); err != nil {
		return nil, err
	}
	// JSON null is legal only in nullable guard/preimage/version fields. Scalar
	// null must not become a default Go string/integer (notably version zero).
	var docs []map[string]json.RawMessage
	_ = json.Unmarshal(fields["documents"], &docs)
	for _, doc := range docs {
		if bytes.Equal(bytes.TrimSpace(doc["version"]), []byte("null")) {
			return nil, fmt.Errorf("document version cannot be null")
		}
	}
	var edits []map[string]json.RawMessage
	_ = json.Unmarshal(fields["edits"], &edits)
	for _, edit := range edits {
		if bytes.Equal(bytes.TrimSpace(edit["afterHex"]), []byte("null")) {
			return nil, fmt.Errorf("replacement bytes cannot be null")
		}
	}
	if err := validate(w); err != nil {
		return nil, err
	}
	canonical := encode(w)
	return &Manifest{wire: w, canonical: canonical, digest: hash(canonical)}, nil
}
func (w wireManifest) path(path string, allowRoot bool) error {
	if path == "" || !utf8.ValidString(path) || strings.ContainsRune(path, 0) || !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return fmt.Errorf("noncanonical manifest path %q", path)
	}
	rel, err := filepath.Rel(w.ProjectRoot, path)
	if err != nil || !filepath.IsLocal(rel) || (!allowRoot && rel == ".") {
		return fmt.Errorf("path outside manifest project: %q", path)
	}
	return nil
}
func validate(w wireManifest) error {
	if w.Version != 1 {
		return fmt.Errorf("unsupported source manifest version %d", w.Version)
	}
	if w.ProjectRoot == "" || strings.ContainsRune(w.ProjectRoot, 0) || !filepath.IsAbs(w.ProjectRoot) || filepath.Clean(w.ProjectRoot) != w.ProjectRoot {
		return fmt.Errorf("invalid manifest project root")
	}
	files := map[string]input{}
	dirs := map[string]directory{}
	docs := map[string]int32{}
	previous := ""
	for _, g := range w.Inputs {
		if err := w.path(g.Path, false); err != nil {
			return err
		}
		if g.Path <= previous || !validHash(g.SourceHash) || !validHash(g.DiskHash) {
			return fmt.Errorf("unordered/duplicate input or invalid hash: %s", g.Path)
		}
		files[g.Path] = g
		previous = g.Path
	}
	previous = ""
	for _, g := range w.Directories {
		if err := w.path(g.Path, true); err != nil {
			return err
		}
		if g.Path <= previous || !validHash(g.SourceHash) || !validHash(g.DiskHash) {
			return fmt.Errorf("unordered/duplicate directory or invalid hash: %s", g.Path)
		}
		if _, ok := files[g.Path]; ok {
			return fmt.Errorf("file/directory conflict: %s", g.Path)
		}
		dirs[g.Path] = g
		previous = g.Path
	}
	if root, ok := dirs[w.ProjectRoot]; !ok || root.SourceHash == nil || root.DiskHash == nil {
		return fmt.Errorf("missing existing project directory guard")
	}
	parentGuards := func(path string) error {
		for parent := filepath.Dir(path); ; parent = filepath.Dir(parent) {
			if _, ok := dirs[parent]; !ok {
				return fmt.Errorf("missing parent directory guard: %s", parent)
			}
			if parent == w.ProjectRoot {
				return nil
			}
		}
	}
	for path := range files {
		if err := parentGuards(path); err != nil {
			return err
		}
	}
	for path := range dirs {
		if path != w.ProjectRoot {
			if err := parentGuards(path); err != nil {
				return err
			}
		}
	}
	previous = ""
	for _, d := range w.Documents {
		if input, ok := files[d.Path]; !ok || input.SourceHash == nil {
			return fmt.Errorf("document lacks input guard: %s", d.Path)
		}
		if d.Path <= previous {
			return fmt.Errorf("unordered or duplicate document")
		}
		docs[d.Path] = d.Version
		previous = d.Path
	}
	previous = ""
	for _, e := range w.Edits {
		g, ok := files[e.Path]
		if !ok || !strings.HasSuffix(e.Path, ".tesl") {
			return fmt.Errorf("edit needs a guarded Tesl source: %s", e.Path)
		}
		if e.Path <= previous {
			return fmt.Errorf("unordered or duplicate edit")
		}
		previous = e.Path
		if !validHex(e.AfterHex) || (e.BeforeHex != nil && !validHex(*e.BeforeHex)) {
			return fmt.Errorf("noncanonical source hex")
		}
		var beforeHash *string
		if e.BeforeHex != nil {
			before, _ := hex.DecodeString(*e.BeforeHex)
			h := hash(before)
			beforeHash = &h
		}
		if !same(beforeHash, g.SourceHash) {
			return fmt.Errorf("edit preimage disagrees with source guard: %s", e.Path)
		}
		if e.BeforeHex != nil && *e.BeforeHex == e.AfterHex {
			return fmt.Errorf("redundant edit")
		}
		version, open := docs[e.Path]
		if (e.DocumentVersion != nil) != open || (open && *e.DocumentVersion != version) {
			return fmt.Errorf("edit document version disagrees with guard")
		}
	}
	previous = ""
	for _, g := range w.Imports {
		key := g.Source + "\x00" + g.Module
		if key <= previous {
			return fmt.Errorf("unordered or duplicate import")
		}
		previous = key
		if !moduleName(g.Module) {
			return fmt.Errorf("invalid import name: %s", g.Module)
		}
		for _, path := range []string{g.Source, g.SourceResolved, g.DiskResolved} {
			if _, ok := files[path]; !ok {
				return fmt.Errorf("import lacks input guard: %s", path)
			}
		}
	}
	return nil
}
func moduleName(name string) bool {
	for _, part := range strings.Split(name, ".") {
		if len(part) == 0 || part[0] < 'A' || part[0] > 'Z' {
			return false
		}
		for _, c := range part {
			letter := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
			digit := c >= '0' && c <= '9'
			if !letter && !digit && c != '_' {
				return false
			}
		}
	}
	return true
}

// Match the compiler's canonical JSON byte-for-byte, including UTF-8 and literal
// HTML punctuation. encoding/json's optional escaping is not the manifest hash.
func quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, c := range []byte(s) {
		switch c {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		default:
			if c < 0x20 {
				fmt.Fprintf(&b, "\\u%04x", c)
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
func nullable(s *string) string {
	if s == nil {
		return "null"
	}
	return quote(*s)
}
func number(n *int32) string {
	if n == nil {
		return "null"
	}
	return strconv.FormatInt(int64(*n), 10)
}
func list[T any](values []T, f func(T) string) string {
	parts := make([]string, len(values))
	for i, v := range values {
		parts[i] = f(v)
	}
	return "[" + strings.Join(parts, ",") + "]"
}
func encode(w wireManifest) []byte {
	return []byte(`{"version":1,"projectRoot":` + quote(w.ProjectRoot) + `,"documents":` + list(w.Documents, func(d document) string {
		return `{"path":` + quote(d.Path) + `,"version":` + strconv.FormatInt(int64(d.Version), 10) + `}`
	}) +
		`,"imports":` + list(w.Imports, func(g importGuard) string {
		return `{"source":` + quote(g.Source) + `,"module":` + quote(g.Module) + `,"sourceResolved":` + quote(g.SourceResolved) + `,"diskResolved":` + quote(g.DiskResolved) + `}`
	}) +
		`,"inputs":` + list(w.Inputs, func(g input) string {
		return `{"path":` + quote(g.Path) + `,"sourceHash":` + nullable(g.SourceHash) + `,"diskHash":` + nullable(g.DiskHash) + `}`
	}) +
		`,"directories":` + list(w.Directories, func(g directory) string {
		return `{"path":` + quote(g.Path) + `,"sourceHash":` + nullable(g.SourceHash) + `,"diskHash":` + nullable(g.DiskHash) + `}`
	}) +
		`,"edits":` + list(w.Edits, func(e edit) string {
		return `{"path":` + quote(e.Path) + `,"beforeHex":` + nullable(e.BeforeHex) + `,"afterHex":` + quote(e.AfterHex) + `,"documentVersion":` + number(e.DocumentVersion) + `}`
	}) + `}`)
}
