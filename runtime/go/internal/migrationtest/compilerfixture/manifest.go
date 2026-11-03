package compilerfixture

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// Manifest includes relative names and content hashes, including empty
// directories. Selection mirrors the fixture copier, not git's tracked files.
func Manifest(root string) (string, error) {
	directory, err := os.OpenRoot(root)
	if err != nil {
		return "", err
	}
	defer func() { _ = directory.Close() }()
	entries := map[string]string{}
	add := func(relative string) error {
		if !utf8.ValidString(relative) {
			return fmt.Errorf("non-UTF-8 compiler input path: %q", relative)
		}
		info, err := directory.Lstat(relative)
		if err != nil {
			return err
		}
		if info.IsDir() {
			entries[relative+"/"] = ""
			return nil
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("special compiler input: %s", relative)
		}
		data, err := directory.ReadFile(relative)
		if err != nil {
			return err
		}
		entries[relative] = Digest(data)
		return nil
	}
	for _, directory := range []string{"compiler/lib", "compiler/bin", "compiler/gen", "runtime/go/teslrt"} {
		if err := filepath.WalkDir(filepath.Join(root, directory), func(path string, _ fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			relative, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			return add(relative)
		}); err != nil {
			return "", err
		}
	}
	for _, name := range []string{"compiler/dune-project", "LANGUAGE-SPEC.md", "README.md", "INSTALL.md"} {
		if err := add(name); err != nil {
			return "", err
		}
	}
	for _, directory := range []string{"manual", "dev-docs", "example", "example/learn", "example/intro", "example/kanel", "example/chat", "example/medical-journal_wip"} {
		if err := add(directory); err != nil {
			if os.IsNotExist(err) && directory != "manual" && directory != "example" {
				continue
			}
			return "", err
		}
		children, err := os.ReadDir(filepath.Join(root, directory))
		if err != nil {
			return "", err
		}
		for _, child := range children {
			if !child.IsDir() && (strings.HasSuffix(child.Name(), ".md") || strings.HasSuffix(child.Name(), ".tesl")) {
				if err := add(filepath.Join(directory, child.Name())); err != nil {
					return "", err
				}
			}
		}
	}
	data, err := json.Marshal(entries)
	return string(data), err
}
