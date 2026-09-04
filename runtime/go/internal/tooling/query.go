package tooling

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	DefaultMaxOverlayDocuments = 256
	DefaultMaxOverlayFiles     = 4096
	DefaultMaxOverlayBytes     = 64 << 20
	DefaultMaxOverlayPathBytes = 4096
	defaultMaxOverlayDirs      = 16384
)

type SourceOverlay struct {
	Path   string
	Source string
}

// QuerySourceJSON runs a compiler JSON query against one unsaved document in a
// temporary project snapshot.
func (client Client) QuerySourceJSON(ctx context.Context, flag, logicalPath, source string, position ...string) ([]byte, Result, error) {
	return client.QuerySourcesJSON(ctx, flag, logicalPath, []SourceOverlay{{Path: logicalPath, Source: source}}, position...)
}

// QuerySourcesJSON runs a compiler query in a bounded shadow project. Disk
// sources provide the project snapshot and overlays replace matching files, so
// every open buffer participates in import resolution without mutating the real
// workspace. Compiler file paths are mapped back to their real logical paths.
func (client Client) QuerySourcesJSON(ctx context.Context, flag, logicalPath string, overlays []SourceOverlay, position ...string) ([]byte, Result, error) {
	if flag == "" || logicalPath == "" {
		return nil, Result{}, errors.New("compiler: query flag and logical path are required")
	}
	if len(logicalPath) > DefaultMaxOverlayPathBytes {
		return nil, Result{}, errors.New("compiler: logical path exceeds configured byte limit")
	}
	if len(overlays) == 0 || len(overlays) > DefaultMaxOverlayDocuments {
		return nil, Result{}, fmt.Errorf("compiler: source overlays must contain 1..%d documents", DefaultMaxOverlayDocuments)
	}
	entryPath, err := filepath.Abs(logicalPath)
	if err != nil {
		return nil, Result{}, fmt.Errorf("compiler: resolve logical path: %w", err)
	}
	entryPath = filepath.Clean(entryPath)
	if !strings.EqualFold(filepath.Ext(entryPath), ".tesl") {
		return nil, Result{}, errors.New("compiler: logical path must name a .tesl file")
	}
	root := sourceProjectRoot(entryPath)
	shadow, err := os.MkdirTemp("", "tesl-overlay-*")
	if err != nil {
		return nil, Result{}, fmt.Errorf("compiler: create source overlay: %w", err)
	}
	defer func() { _ = os.RemoveAll(shadow) }()

	totalBytes, err := copyDiskSources(root, shadow)
	if err != nil {
		return nil, Result{}, err
	}
	entryStaged := false
	for _, overlay := range overlays {
		if len(overlay.Path) > DefaultMaxOverlayPathBytes {
			return nil, Result{}, errors.New("compiler: overlay path exceeds configured byte limit")
		}
		path, pathErr := filepath.Abs(overlay.Path)
		if pathErr != nil {
			return nil, Result{}, fmt.Errorf("compiler: resolve overlay path: %w", pathErr)
		}
		path = filepath.Clean(path)
		if !strings.EqualFold(filepath.Ext(path), ".tesl") {
			return nil, Result{}, fmt.Errorf("compiler: overlay path is not a .tesl file: %s", path)
		}
		if !pathWithinRoot(root, path) {
			continue
		}
		totalBytes += int64(len(overlay.Source))
		if totalBytes > DefaultMaxOverlayBytes {
			return nil, Result{}, errors.New("compiler: source overlay exceeds configured byte limit")
		}
		if err := writeShadowSource(root, shadow, path, []byte(overlay.Source)); err != nil {
			return nil, Result{}, err
		}
		if path == entryPath {
			entryStaged = true
		}
	}
	if !entryStaged {
		return nil, Result{}, errors.New("compiler: source overlays do not contain the entry document")
	}
	shadowEntry, err := shadowSourcePath(root, shadow, entryPath)
	if err != nil {
		return nil, Result{}, err
	}

	queryClient := client
	queryClient.Environment = withoutEnvironment(client.Environment, "TESL_LOGICAL_PATH")
	arguments := append([]string{flag, shadowEntry}, position...)
	payload, result, err := queryClient.QueryJSON(ctx, arguments...)
	if err != nil {
		return nil, result, err
	}
	mapped, err := mapShadowFilePaths(payload, shadow, root)
	if err != nil {
		return nil, result, err
	}
	result.Stdout = append(result.Stdout[:0], mapped...)
	return mapped, result, nil
}

// QueryFileJSON is the on-disk counterpart used for saved documents.
func (client Client) QueryFileJSON(ctx context.Context, flag, filePath string, position ...string) ([]byte, Result, error) {
	if flag == "" || filePath == "" {
		return nil, Result{}, errors.New("compiler: query flag and file path are required")
	}
	arguments := append([]string{flag, filePath}, position...)
	return client.QueryJSON(ctx, arguments...)
}

// FormatSource runs the compiler's in-place formatter against a system
// temporary file and returns the resulting source. Formatting failures return
// an error without exposing the temporary path to callers.
func (client Client) FormatSource(ctx context.Context, logicalPath, source string) ([]byte, Result, error) {
	if logicalPath == "" {
		return nil, Result{}, errors.New("compiler: logical path is required")
	}
	temporary, err := os.CreateTemp("", "tesl-format-*.tesl")
	if err != nil {
		return nil, Result{}, fmt.Errorf("compiler: create formatting source: %w", err)
	}
	temporaryPath := temporary.Name()
	defer func() { _ = os.Remove(temporaryPath) }()
	if _, err := temporary.WriteString(source); err != nil {
		_ = temporary.Close()
		return nil, Result{}, fmt.Errorf("compiler: write formatting source: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return nil, Result{}, fmt.Errorf("compiler: close formatting source: %w", err)
	}
	formatClient := client
	formatClient.Environment = withEnvironment(client.Environment, "TESL_LOGICAL_PATH", logicalPath)
	result, err := formatClient.Run(ctx, "--fmt", temporaryPath)
	if err != nil {
		return nil, result, err
	}
	formatted, err := os.ReadFile(temporaryPath) // #nosec G304 -- path was created by os.CreateTemp above.
	if err != nil {
		return nil, result, fmt.Errorf("compiler: read formatted source: %w", err)
	}
	return formatted, result, nil
}

func withEnvironment(environment []string, name, value string) []string {
	base := environment
	if base == nil {
		base = os.Environ()
	}
	result := make([]string, 0, len(base)+1)
	found := false
	prefix := name + "="
	for _, entry := range base {
		if strings.HasPrefix(entry, prefix) {
			if !found {
				result = append(result, prefix+value)
				found = true
			}
			continue
		}
		result = append(result, entry)
	}
	if !found {
		result = append(result, prefix+value)
	}
	return result
}

func withoutEnvironment(environment []string, name string) []string {
	base := environment
	if base == nil {
		base = os.Environ()
	}
	prefix := name + "="
	result := make([]string, 0, len(base))
	for _, entry := range base {
		if !strings.HasPrefix(entry, prefix) {
			result = append(result, entry)
		}
	}
	return result
}

func sourceProjectRoot(entryPath string) string {
	for directory := filepath.Dir(entryPath); ; directory = filepath.Dir(directory) {
		if info, err := os.Stat(filepath.Join(directory, "tesl.toml")); err == nil && !info.IsDir() {
			return directory
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			return filepath.Dir(entryPath)
		}
	}
}

func copyDiskSources(root, shadow string) (int64, error) {
	if _, err := os.Stat(root); errors.Is(err, os.ErrNotExist) {
		return 0, nil
	} else if err != nil {
		return 0, fmt.Errorf("compiler: inspect overlay root: %w", err)
	}
	files, directories := 0, 0
	var total int64
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			directories++
			if directories > defaultMaxOverlayDirs {
				return errors.New("source overlay exceeds configured directory limit")
			}
			if path != root {
				switch entry.Name() {
				case ".git", ".tesl-stuff", ".direnv", "_build", "build", "dist", "node_modules":
					return filepath.SkipDir
				}
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 || (!strings.EqualFold(filepath.Ext(path), ".tesl") && entry.Name() != "tesl.toml") {
			return nil
		}
		files++
		if files > DefaultMaxOverlayFiles {
			return errors.New("source overlay exceeds configured file limit")
		}
		remaining := DefaultMaxOverlayBytes - total
		contents, err := readFileBounded(path, remaining)
		if err != nil {
			return err
		}
		total += int64(len(contents))
		return writeShadowSource(root, shadow, path, contents)
	})
	if err != nil {
		return 0, fmt.Errorf("compiler: stage source overlay: %w", err)
	}
	return total, nil
}

func readFileBounded(path string, remaining int64) ([]byte, error) {
	if remaining < 0 {
		return nil, errors.New("source overlay exceeds configured byte limit")
	}
	file, err := os.Open(path) // #nosec G304 -- path is bounded beneath the selected project root.
	if err != nil {
		return nil, err
	}
	defer func() { _ = file.Close() }()
	contents, err := io.ReadAll(io.LimitReader(file, remaining+1))
	if err != nil {
		return nil, err
	}
	if int64(len(contents)) > remaining {
		return nil, errors.New("source overlay exceeds configured byte limit")
	}
	return contents, nil
}

func writeShadowSource(root, shadow, path string, contents []byte) error {
	target, err := shadowSourcePath(root, shadow, path)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return fmt.Errorf("compiler: create overlay directory: %w", err)
	}
	if err := os.WriteFile(target, contents, 0o600); err != nil {
		return fmt.Errorf("compiler: write source overlay: %w", err)
	}
	return nil
}

func shadowSourcePath(root, shadow, path string) (string, error) {
	relative, err := filepath.Rel(root, path)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) || filepath.IsAbs(relative) {
		return "", fmt.Errorf("compiler: source path %s is outside overlay root %s", path, root)
	}
	if len(relative) > DefaultMaxOverlayPathBytes {
		return "", errors.New("compiler: relative source path exceeds configured byte limit")
	}
	return filepath.Join(shadow, relative), nil
}

func pathWithinRoot(root, path string) bool {
	_, err := shadowSourcePath(root, root, path)
	return err == nil
}

func mapShadowFilePaths(payload []byte, shadow, root string) ([]byte, error) {
	var value any
	if err := json.Unmarshal(payload, &value); err != nil {
		return nil, fmt.Errorf("compiler: decode overlay response: %w", err)
	}
	var rewrite func(any)
	rewrite = func(current any) {
		switch current := current.(type) {
		case map[string]any:
			if file, ok := current["file"].(string); ok && pathWithinRoot(shadow, file) {
				relative, _ := filepath.Rel(shadow, file)
				current["file"] = filepath.Join(root, relative)
			}
			for _, child := range current {
				rewrite(child)
			}
		case []any:
			for _, child := range current {
				rewrite(child)
			}
		}
	}
	rewrite(value)
	mapped, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("compiler: encode overlay response: %w", err)
	}
	return mapped, nil
}
