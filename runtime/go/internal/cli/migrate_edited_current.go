package cli

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The compiler describes an edited current schema whose bytes no longer match
// the seal recorded by the latest revision. It never authorizes a write: the
// recorded bytes found here are verified against that digest, and the compiler
// verifies every seal again when the next revision is started.
type migrationStaleSource struct {
	Module, File, RecordedSha256 string
}

type migrationStaleCurrent struct {
	Family   string
	Revision int
	Sources  []migrationStaleSource
}

type migrationEditedCurrentError struct {
	stale         migrationStaleCurrent
	migrationFile string
}

func (err *migrationEditedCurrentError) Error() string {
	return fmt.Sprintf("the current schema was edited after revision V%d was generated", err.stale.Revision)
}

// Only a refusal consisting entirely of edited-current reports is handled; any
// other error (a changed frozen file, a missing source) is shown unchanged.
func migrationEditedCurrent(errors []migrationWizardDiagnostic) *migrationEditedCurrentError {
	if len(errors) == 0 {
		return nil
	}
	var result *migrationEditedCurrentError
	for _, diagnostic := range errors {
		stale := diagnostic.StaleCurrent
		if diagnostic.Action != "start-from-edited-current" || stale == nil || stale.Revision < 1 || len(stale.Sources) == 0 {
			return nil
		}
		if result != nil && (result.stale.Revision != stale.Revision || result.stale.Family != stale.Family) {
			return nil
		}
		if result == nil {
			result = &migrationEditedCurrentError{stale: *stale, migrationFile: diagnostic.File}
		}
	}
	return result
}

type migrationEditedFile struct {
	path, relative   string
	edited, recorded []byte
	missing          bool
	mode             fs.FileMode
	recordedFrom     string
}

func migrationSHA256(contents []byte) string {
	sum := sha256.Sum256(contents)
	return hex.EncodeToString(sum[:])
}

// Recorded bytes come from version control only when their SHA-256 equals the
// digest in the revision's seal. Nothing else is trusted as the recorded source.
func (app *App) migrationRecordedBytes(ctx context.Context, path, digest string) ([]byte, string, error) {
	git := func(args ...string) ([]byte, error) {
		command := exec.CommandContext(ctx, "git", args...) // #nosec G204 -- literal argv, no shell.
		command.Dir, command.Env = filepath.Dir(path), app.Environment
		var out bytes.Buffer
		command.Stdout, command.Stderr = &out, io.Discard
		err := command.Run()
		return out.Bytes(), err
	}
	top, err := git("rev-parse", "--show-toplevel")
	if err != nil {
		return nil, "", fmt.Errorf("%s is not tracked by git, so the source recorded by the previous revision cannot be recovered automatically", path)
	}
	root, err := filepath.EvalSymlinks(strings.TrimSpace(string(top)))
	if err != nil {
		return nil, "", err
	}
	resolved, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err != nil {
		return nil, "", err
	}
	relative, err := filepath.Rel(root, filepath.Join(resolved, filepath.Base(path)))
	if err != nil || strings.HasPrefix(relative, "..") {
		return nil, "", fmt.Errorf("%s is outside its git work tree", path)
	}
	relative = filepath.ToSlash(relative)
	revisions := []string{"", "HEAD"}
	if history, err := git("log", "--format=%H", "-n", "200", "--", relative); err == nil {
		revisions = append(revisions, strings.Fields(string(history))...)
	}
	for _, revision := range revisions {
		spec := revision + ":" + relative
		for _, args := range [][]string{{"cat-file", "--filters", spec}, {"cat-file", "blob", spec}} {
			contents, err := git(args...)
			if err == nil && migrationSHA256(contents) == digest {
				label := "the git index"
				if revision != "" {
					label = "git " + revision
					if len(revision) > 12 {
						label = "git commit " + revision[:12]
					}
				}
				return contents, label, nil
			}
		}
	}
	return nil, "", fmt.Errorf("no git version of %s matches the bytes recorded by the previous revision", path)
}

func migrationReadOptional(path string) ([]byte, bool, error) {
	contents, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, true, nil
	}
	return contents, false, err
}

// Each write replaces a file only while it still holds the bytes this flow last
// observed, so a save made in an editor during the operation is never overwritten.
func migrationReplaceIfUnchanged(path string, expected []byte, expectedMissing bool, contents []byte, remove bool, mode fs.FileMode) error {
	current, missing, err := migrationReadOptional(path)
	if err != nil {
		return err
	}
	if missing != expectedMissing || (!missing && !bytes.Equal(current, expected)) {
		return fmt.Errorf("%s changed while the migration was being prepared", path)
	}
	if remove {
		if missing {
			return nil
		}
		return os.Remove(path)
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".tesl-migrate-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if _, err := temporary.Write(contents); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

func migrationWriteBackup(path string, contents []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.Write(contents); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

// migrationStartFromEditedCurrent keeps the user's saved edits, puts back the
// exact bytes the latest revision recorded, starts the next revision through the
// ordinary guarded generator, and then reapplies the edits. The edits are backed
// up before any file changes and restored if starting the revision fails.
func (app *App) migrationStartFromEditedCurrent(ctx context.Context, stale *migrationEditedCurrentError, progress io.Writer, start func() error) ([]string, error) {
	projectRoot := filepath.Dir(filepath.Dir(filepath.Dir(stale.migrationFile)))
	files := make([]migrationEditedFile, 0, len(stale.stale.Sources))
	for _, source := range stale.stale.Sources {
		edited, missing, err := migrationReadOptional(source.File)
		if err != nil {
			return nil, err
		}
		mode := fs.FileMode(0o644)
		if info, err := os.Stat(source.File); err == nil {
			mode = info.Mode().Perm()
		}
		recorded, from, err := app.migrationRecordedBytes(ctx, source.File, source.RecordedSha256)
		if err != nil {
			return nil, fmt.Errorf("%w.\nNo files were changed. Copy your edited schema somewhere safe, restore %s to the source of revision V%d, run tesl migrate again to start V%d, then reapply your edits",
				err, source.File, stale.stale.Revision, stale.stale.Revision+1)
		}
		relative, err := filepath.Rel(projectRoot, source.File)
		if err != nil || strings.HasPrefix(relative, "..") {
			relative = filepath.Base(source.File)
		}
		files = append(files, migrationEditedFile{path: source.File, relative: relative, edited: edited, missing: missing, recorded: recorded, mode: mode, recordedFrom: from})
	}
	backup := filepath.Join(projectRoot, ".tesl-stuff", "migrate-edits",
		fmt.Sprintf("V%d-%s", stale.stale.Revision+1, time.Now().UTC().Format("20060102T150405.000000000Z")))
	for _, file := range files {
		if file.missing {
			continue
		}
		if err := migrationWriteBackup(filepath.Join(backup, file.relative), file.edited); err != nil {
			return nil, fmt.Errorf("could not back up your edits; no files were changed: %w", err)
		}
	}
	if _, err := fmt.Fprintf(progress, "Your saved schema edits are newer than revision V%d. Keeping them as revision V%d:\n", stale.stale.Revision, stale.stale.Revision+1); err != nil {
		return nil, err
	}
	for _, file := range files {
		if _, err := fmt.Fprintf(progress, "  %s: restored V%d source from %s (SHA-256 verified)\n", strconv.Quote(file.relative), stale.stale.Revision, file.recordedFrom); err != nil {
			return nil, err
		}
	}
	if _, err := fmt.Fprintf(progress, "  edits backed up in %s until they are reapplied\n", strconv.Quote(backup)); err != nil {
		return nil, err
	}
	putBack := func(upTo int) error {
		var failures []string
		for _, file := range files[:upTo] {
			if err := migrationReplaceIfUnchanged(file.path, file.recorded, false, file.edited, file.missing, file.mode); err != nil {
				failures = append(failures, err.Error())
			}
		}
		if len(failures) > 0 {
			return fmt.Errorf("could not put every edit back (%s); your edited files are saved in %s", strings.Join(failures, "; "), backup)
		}
		if err := os.RemoveAll(backup); err != nil {
			return err
		}
		_ = os.Remove(filepath.Dir(backup)) // Only succeeds once no other backup remains.
		return nil
	}
	for index, file := range files {
		if err := migrationReplaceIfUnchanged(file.path, file.edited, file.missing, file.recorded, false, file.mode); err != nil {
			if restoreErr := putBack(index); restoreErr != nil {
				return nil, fmt.Errorf("%w; %v", err, restoreErr)
			}
			return nil, fmt.Errorf("%w; your edits were left in place", err)
		}
	}
	if err := start(); err != nil {
		if restoreErr := putBack(len(files)); restoreErr != nil {
			return nil, fmt.Errorf("%w; %v", err, restoreErr)
		}
		return nil, fmt.Errorf("%w\nNo new revision was started; your schema edits were put back", err)
	}
	if err := putBack(len(files)); err != nil {
		return nil, fmt.Errorf("revision V%d was started, but %w", stale.stale.Revision+1, err)
	}
	reapplied := make([]string, 0, len(files))
	for _, file := range files {
		reapplied = append(reapplied, file.path)
	}
	return reapplied, nil
}
