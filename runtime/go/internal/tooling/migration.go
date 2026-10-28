package tooling

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"tesl.dev/runtime/go/internal/sourceedit"
)

type MigrationSelection struct {
	EntryFile, ProjectRoot, Database string
	NewRevision                      bool
}

type MigrationDocument struct {
	Path    string
	Version int32
	Source  string
}

// QueryMigrationPreview asks the compiler for a non-mutating, guarded manifest
// over the real project and exact open-document versions. It deliberately does
// not use the ordinary shadow-project query adapter: remapping a source manifest
// would invalidate its path identities and disk guards. Private overlay contents
// files are removed after the compiler exits, including cancellation and failure.
func (client Client) QueryMigrationPreview(ctx context.Context, selection MigrationSelection, documents []MigrationDocument) (preview *sourceedit.Preview, result Result, resultErr error) {
	if err := ctx.Err(); err != nil {
		return nil, result, err
	}
	canonical := func(path string) bool {
		return path != "" && len(path) <= DefaultMaxOverlayPathBytes && utf8.ValidString(path) && !strings.ContainsRune(path, 0) &&
			filepath.IsAbs(path) && filepath.Clean(path) == path
	}
	if !canonical(selection.ProjectRoot) || !canonical(selection.EntryFile) ||
		!pathWithinRoot(selection.ProjectRoot, selection.EntryFile) || !strings.EqualFold(filepath.Ext(selection.EntryFile), ".tesl") {
		return nil, result, fmt.Errorf("migration preview requires a canonical project root and a Tesl entry inside it")
	}
	if len(selection.Database) > DefaultMaxOverlayPathBytes || !utf8.ValidString(selection.Database) || strings.ContainsRune(selection.Database, 0) {
		return nil, result, fmt.Errorf("invalid migration database selection")
	}
	if len(documents) > DefaultMaxOverlayDocuments {
		return nil, result, fmt.Errorf("migration preview exceeds the open-document limit")
	}
	expected := make(map[string]int32, len(documents))
	total := 0
	for _, document := range documents {
		if !canonical(document.Path) || !pathWithinRoot(selection.ProjectRoot, document.Path) || !strings.EqualFold(filepath.Ext(document.Path), ".tesl") || !utf8.ValidString(document.Source) {
			return nil, result, fmt.Errorf("migration preview requires canonical UTF-8 Tesl buffers inside its project")
		}
		if _, duplicate := expected[document.Path]; duplicate {
			return nil, result, fmt.Errorf("duplicate migration buffer: %s", document.Path)
		}
		total += len(document.Source)
		if total > DefaultMaxOverlayBytes {
			return nil, result, fmt.Errorf("migration preview exceeds the overlay byte limit")
		}
		expected[document.Path] = document.Version
	}
	// Sort a copy so callers retain their own document order and snapshot.
	documents = append([]MigrationDocument(nil), documents...)
	sort.Slice(documents, func(i, j int) bool { return documents[i].Path < documents[j].Path })
	args := []string{"migrate", "generate", selection.EntryFile, "--manifest-json", "--project-root", selection.ProjectRoot}
	if selection.Database != "" {
		args = append(args, "--database", selection.Database)
	}
	if selection.NewRevision {
		args = append(args, "--new-revision")
	}
	if len(documents) != 0 {
		temporary, err := os.MkdirTemp("", "tesl-migration-overlays-*")
		if err != nil {
			return nil, result, err
		}
		defer func() {
			if err := os.RemoveAll(temporary); err != nil {
				preview = nil
				resultErr = errors.Join(resultErr, fmt.Errorf("remove private migration overlays: %w", err))
			}
		}()
		// Some systems expose their temporary directory through a symlink. Only
		// private transport paths are resolved; logical project paths stay exact.
		resolved, err := filepath.EvalSymlinks(temporary)
		if err != nil {
			return nil, result, err
		}
		for i, document := range documents {
			if err := ctx.Err(); err != nil {
				return nil, result, err
			}
			contents := filepath.Join(resolved, fmt.Sprintf("buffer-%06d", i))
			if err := os.WriteFile(contents, []byte(document.Source), 0600); err != nil {
				return nil, result, err
			}
			args = append(args, "--overlay", document.Path, strconv.FormatInt(int64(document.Version), 10), contents)
		}
	}
	if client.MaxOutput <= 0 || client.MaxOutput > 64<<20 {
		client.MaxOutput = 64 << 20
	}
	client.Environment = withoutEnvironment(client.Environment, "TESL_LOGICAL_PATH")
	// Unlike diagnostic queries, a usable JSON body must not mask process
	// failure or a timeout that raced with successful stdout publication.
	result, err := client.Run(ctx, args...)
	if err != nil {
		return nil, result, err
	}
	preview, err = sourceedit.DecodePreview(result.Stdout)
	if err != nil {
		return nil, result, fmt.Errorf("invalid migration compiler preview: %w", err)
	}
	if preview.Manifest().ProjectRoot() != selection.ProjectRoot {
		return nil, result, fmt.Errorf("migration preview changed the selected project root")
	}
	if preview.EntryFile() != selection.EntryFile || (selection.NewRevision && preview.Operation() != "start") {
		return nil, result, fmt.Errorf("migration preview changed the selected entry or operation")
	}
	if selection.Database != "" && preview.Database() != selection.Database &&
		(strings.Contains(selection.Database, ".") || !strings.HasSuffix(preview.Database(), "."+selection.Database)) {
		return nil, result, fmt.Errorf("migration preview changed the selected database")
	}
	actual := preview.Manifest().DocumentVersions()
	if len(actual) != len(expected) {
		return nil, result, fmt.Errorf("migration preview omitted or added open-document guards")
	}
	for _, document := range documents {
		if !preview.Manifest().MatchesDocument(document.Path, document.Version, document.Source) {
			return nil, result, fmt.Errorf("migration preview changed the buffer version or source for %s", document.Path)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, result, err
	}
	return preview, result, nil
}
