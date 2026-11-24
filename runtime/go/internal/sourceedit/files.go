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

// checkpointVersion parses a generated revision checkpoint name, v<N>.checkpoint.
func checkpointVersion(path string) (int, bool) {
	name := filepath.Base(path)
	if len(name) <= 12 || name[0] != 'v' || !strings.HasSuffix(name, ".checkpoint") {
		return 0, false
	}
	digits := name[1 : len(name)-11]
	if digits[0] == '0' || len(digits) > 9 {
		return 0, false
	}
	for _, c := range digits {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	n, err := strconv.Atoi(digits)
	return n, err == nil
}

// historyHash is the compiler's frozen history digest (Migration_manifest):
// SHA-256 over "tesl-frozen-history-v1", then per tree "tree", its
// project-relative path, every non-excluded entry sorted by project-relative
// path with '/' separators ("d" for a directory; "f", the path and the SHA-256
// of a regular file's bytes; "c" for an older checkpoint) or "absent", and
// "end"; each item ends with NUL. Only the newest non-excluded v<N>.checkpoint
// contributes its bytes. Symbolic links and special files refuse. skip omits
// entries the running transaction itself created.
func (t *tree) historyHash(h historyGuard, skip func(string) bool) (string, error) {
	excluded := make(map[string]bool, len(h.Excluded))
	for _, path := range h.Excluded {
		excluded[path] = true
	}
	type entry struct {
		path string
		dir  bool
	}
	relative := func(path string) string {
		rel, _ := filepath.Rel(t.path, path)
		return filepath.ToSlash(rel)
	}
	collected := make([][]entry, len(h.Trees))
	present := make([]bool, len(h.Trees))
	newest, found := 0, false
	for i, root := range h.Trees {
		if skip != nil && skip(root) {
			continue // created by this transaction: absent when previewed
		}
		info, err := t.kind(root)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		if !info.IsDir() {
			return "", fmt.Errorf("history tree is not a directory: %s", root)
		}
		present[i] = true
		var visit func(string) error
		visit = func(directory string) error {
			names, exists, err := t.names(directory)
			if err != nil {
				return err
			}
			if !exists {
				return fmt.Errorf("history directory disappeared: %s", directory)
			}
			for _, name := range names {
				path := filepath.Join(directory, name)
				if skip != nil && skip(path) {
					continue
				}
				info, err := t.kind(path)
				if err != nil {
					return err
				}
				switch {
				case info.IsDir():
					collected[i] = append(collected[i], entry{path, true})
					if err := visit(path); err != nil {
						return err
					}
				case info.Mode().IsRegular():
					collected[i] = append(collected[i], entry{path, false})
					if n, ok := checkpointVersion(path); ok && !excluded[path] && (!found || n > newest) {
						newest, found = n, true
					}
				default:
					return fmt.Errorf("history entry is not a regular file or directory: %s", path)
				}
			}
			return nil
		}
		if err := visit(root); err != nil {
			return "", err
		}
	}
	var b strings.Builder
	b.WriteString("tesl-frozen-history-v1\x00")
	for i, root := range h.Trees {
		b.WriteString("tree\x00" + relative(root) + "\x00")
		if !present[i] {
			b.WriteString("absent\x00end\x00")
			continue
		}
		type line struct{ rel, text string }
		var lines []line
		for _, e := range collected[i] {
			if excluded[e.path] {
				continue
			}
			rel := relative(e.path)
			if e.dir {
				lines = append(lines, line{rel, "d\x00" + rel})
				continue
			}
			if n, ok := checkpointVersion(e.path); ok && n != newest {
				lines = append(lines, line{rel, "c\x00" + rel})
				continue
			}
			data, exists, err := t.bytes(e.path)
			if err != nil {
				return "", err
			}
			if !exists {
				return "", fmt.Errorf("history entry disappeared: %s", e.path)
			}
			lines = append(lines, line{rel, "f\x00" + rel + "\x00" + hash(data)})
		}
		sort.Slice(lines, func(a, b int) bool { return lines[a].rel < lines[b].rel })
		for _, l := range lines {
			b.WriteString(l.text + "\x00")
		}
		b.WriteString("end\x00")
	}
	return hash([]byte(b.String())), nil
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
	for _, h := range m.wire.History {
		actual, err := t.historyHash(h, nil)
		if err != nil {
			return err
		}
		if actual != h.DiskHash {
			return fmt.Errorf("saved frozen history changed after preview: %s", strings.Join(h.Trees, ", "))
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
	var family, revision string
	var children []string
	if parts[0] == "Schema" && len(parts) >= 3 {
		family, revision, children = parts[1], parts[2], parts[3:]
	} else if strings.HasSuffix(parts[0], "Schema") && len(parts[0]) > 6 {
		family, revision, children = strings.TrimSuffix(parts[0], "Schema"), parts[1], parts[2:]
	} else {
		return "", false
	}
	family = kebab(family)
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
	for _, part := range children {
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
