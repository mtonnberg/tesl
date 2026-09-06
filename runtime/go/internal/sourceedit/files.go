package sourceedit

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// tree anchors all source reads in the selected directory. Existing components
// are checked without following links; Root additionally prevents a concurrent
// link replacement from redirecting an operation outside the project.
type tree struct {
	root     *os.Root
	path     string
	identity os.FileInfo
}

func openTree(path string) (*tree, error) {
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		return nil, err
	}
	if canonical != path {
		return nil, fmt.Errorf("project path is no longer canonical: %s", path)
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	info, err := root.Stat(".")
	if err != nil {
		_ = root.Close()
		return nil, err
	}
	t := &tree{root: root, path: path, identity: info}
	if err := t.verifyRoot(); err != nil {
		_ = root.Close()
		return nil, err
	}
	return t, nil
}
func (t *tree) verifyRoot() error {
	current, err := os.Lstat(t.path)
	if err != nil {
		return err
	}
	canonical, err := filepath.EvalSymlinks(t.path)
	if err != nil {
		return err
	}
	if canonical != t.path || !current.IsDir() || !os.SameFile(t.identity, current) {
		return fmt.Errorf("project directory moved or changed after preview")
	}
	return nil
}
func (t *tree) relative(path string) (string, error) {
	rel, err := filepath.Rel(t.path, path)
	if err != nil || !filepath.IsLocal(rel) {
		return "", fmt.Errorf("path outside project: %s", path)
	}
	return rel, nil
}
func (t *tree) kind(path string) (os.FileInfo, error) {
	rel, err := t.relative(path)
	if err != nil {
		return nil, err
	}
	if rel == "." {
		return t.root.Lstat(rel)
	}
	components := strings.Split(rel, string(filepath.Separator))
	prefix := ""
	for i, c := range components {
		prefix = filepath.Join(prefix, c)
		info, err := t.root.Lstat(prefix)
		if err != nil {
			return nil, err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("source path contains a symbolic link: %s", path)
		}
		if i < len(components)-1 && !info.IsDir() {
			return nil, fmt.Errorf("source parent is not a directory: %s", path)
		}
		if i == len(components)-1 {
			return info, nil
		}
	}
	return nil, fmt.Errorf("invalid source path")
}
func (t *tree) bytes(path string) ([]byte, bool, error) {
	info, err := t.kind(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if !info.Mode().IsRegular() {
		return nil, false, fmt.Errorf("source is not a regular file: %s", path)
	}
	rel, _ := t.relative(path)
	file, err := openRegular(t.root, rel)
	if err != nil {
		return nil, false, err
	}
	defer func() { _ = file.Close() }()
	opened, err := file.Stat()
	if err != nil {
		return nil, false, err
	}
	if !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
		return nil, false, fmt.Errorf("source changed while opening: %s", path)
	}
	if opened.Size() > maxManifestBytes {
		return nil, false, fmt.Errorf("source exceeds manifest byte limit: %s", path)
	}
	data, err := io.ReadAll(io.LimitReader(file, maxManifestBytes+1))
	if err != nil {
		return nil, false, err
	}
	if len(data) > maxManifestBytes {
		return nil, false, fmt.Errorf("source exceeds manifest byte limit: %s", path)
	}
	// Stat again through the selected path so an atomic save while reading cannot
	// leave a successful guard against the unlinked old inode.
	current, err := t.kind(path)
	if err != nil {
		return nil, false, err
	}
	if !os.SameFile(opened, current) {
		return nil, false, fmt.Errorf("source changed while reading: %s", path)
	}
	return data, true, nil
}
func (t *tree) names(path string) ([]string, bool, error) {
	info, err := t.kind(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if !info.IsDir() {
		return nil, false, fmt.Errorf("source directory is not a directory: %s", path)
	}
	rel, _ := t.relative(path)
	file, err := openRegular(t.root, rel)
	if err != nil {
		return nil, false, err
	}
	defer func() { _ = file.Close() }()
	opened, err := file.Stat()
	if err != nil {
		return nil, false, err
	}
	if !opened.IsDir() || !os.SameFile(info, opened) {
		return nil, false, fmt.Errorf("directory changed while opening: %s", path)
	}
	names, err := file.Readdirnames(-1)
	if err != nil {
		return nil, false, err
	}
	sort.Strings(names)
	current, err := t.kind(path)
	if err != nil {
		return nil, false, err
	}
	if !os.SameFile(opened, current) {
		return nil, false, fmt.Errorf("directory changed while reading: %s", path)
	}
	return names, true, nil
}
func directoryHash(names []string) string {
	return hash([]byte("tesl-directory-v1\x00" + strings.Join(names, "\x00") + "\x00"))
}
func (t *tree) fileHash(path string) (*string, error) {
	data, exists, err := t.bytes(path)
	if err != nil || !exists {
		return nil, err
	}
	h := hash(data)
	return &h, nil
}
func (t *tree) directoryHash(path string) (*string, error) {
	names, exists, err := t.names(path)
	if err != nil || !exists {
		return nil, err
	}
	h := directoryHash(names)
	return &h, nil
}

// VerifyDisk checks original saved bytes, directory membership and actual import
// resolution. It neither checks open-document versions nor applies an edit.
func (m *Manifest) VerifyDisk() error {
	t, err := openTree(m.wire.ProjectRoot)
	if err != nil {
		return err
	}
	defer func() { _ = t.root.Close() }()
	return m.verifyDisk(t)
}
func (m *Manifest) verifyDisk(t *tree) error {
	if err := t.verifyRoot(); err != nil {
		return err
	}
	for _, g := range m.wire.Imports {
		actual := resolveImport(g.Source, g.Module)
		if actual != g.DiskResolved {
			return fmt.Errorf("import resolution changed after preview: %s from %s", g.Module, g.Source)
		}
	}
	for _, g := range m.wire.Inputs {
		actual, err := t.fileHash(g.Path)
		if err != nil {
			return err
		}
		if !same(actual, g.DiskHash) {
			return fmt.Errorf("saved source changed after preview: %s", g.Path)
		}
	}
	for _, g := range m.wire.Directories {
		actual, err := t.directoryHash(g.Path)
		if err != nil {
			return err
		}
		if !same(actual, g.DiskHash) {
			return fmt.Errorf("saved directory membership changed after preview: %s", g.Path)
		}
	}
	return t.verifyRoot()
}
func kebab(name string) string {
	var b strings.Builder
	for i, c := range name {
		if c >= 'A' && c <= 'Z' {
			if i > 0 {
				b.WriteByte('-')
			}
			c += 'a' - 'A'
		}
		b.WriteRune(c)
	}
	return b.String()
}
func schemaRelative(name string) (string, bool) {
	if !moduleName(name) {
		return "", false
	}
	parts := strings.Split(name, ".")
	if len(parts) < 2 {
		return "", false
	}
	family, revision := parts[0], parts[1]
	if !strings.HasSuffix(family, "Schema") || len(family) <= 6 {
		return "", false
	}
	family = kebab(strings.TrimSuffix(family, "Schema"))
	var components []string
	if revision == "Migrate" {
		components = []string{"migrations", family}
	} else {
		if revision != "VCurrent" {
			if len(revision) < 2 || revision[0] != 'V' || revision[1] < '1' || revision[1] > '9' {
				return "", false
			}
			n, err := strconv.ParseInt(revision[1:], 10, 32)
			if err != nil || n > 2147483646 {
				return "", false
			}
		}
		components = []string{"schema", family, kebab(revision)}
	}
	for _, part := range parts[2:] {
		components = append(components, kebab(part))
	}
	return filepath.Join(components...) + ".tesl", true
}
func resolveImport(source, name string) string {
	dir := filepath.Dir(source)
	exists := func(path string) bool { _, err := os.Stat(path); return err == nil }
	lower := filepath.Join(dir, kebab(name)+".tesl")
	if exists(lower) {
		return lower
	}
	upper := filepath.Join(dir, name+".tesl")
	if exists(upper) {
		return upper
	}
	relative, ok := schemaRelative(name)
	if !ok {
		return upper
	}
	current, err := filepath.EvalSymlinks(dir)
	if err != nil {
		current = dir
	}
	for {
		candidate := filepath.Join(current, relative)
		if exists(candidate) {
			return candidate
		}
		for _, marker := range []string{"tesl.toml", "tesl.json", ".git"} {
			if exists(filepath.Join(current, marker)) {
				return candidate
			}
		}
		parent := filepath.Dir(current)
		if parent == current {
			return filepath.Join(dir, relative)
		}
		current = parent
	}
}
