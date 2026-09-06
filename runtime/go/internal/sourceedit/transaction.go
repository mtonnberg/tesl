package sourceedit

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const transactionDirectory = ".tesl-source-edit"

type Report struct {
	Outcome          string   `json:"outcome"`
	ManifestHash     string   `json:"manifestHash"`
	Written          []string `json:"written"`
	Restored         []string `json:"restored"`
	RecoveryRequired bool     `json:"recoveryRequired"`
}

type journal struct {
	Nonce              string          `json:"nonce"`
	Version            int             `json:"version"`
	Phase              string          `json:"phase"`
	Manifest           json.RawMessage `json:"manifest"`
	ManifestHash       string          `json:"manifestHash"`
	CreatedDirectories []string        `json:"createdDirectories"`
	Modes              []uint32        `json:"modes"`
}
type transaction struct {
	checkpoint func(string) error
	owner      *os.File
	manifest   *Manifest
	editor     bool
	files      []edit
	tree       *tree
	state      string
	identity   os.FileInfo
	journal    journal
	applied    map[string]bool
	created    map[string]bool
	report     Report
}

// Apply is a source-filesystem operation. It accepts saved-source manifests only;
// open editor documents require the separately versioned editor apply protocol.
// The private checkpoint parameter below exists for deterministic fault/crash
// regressions; no command, environment option or runtime input can activate it.
func (m *Manifest) Apply(ctx context.Context) (Report, error) { return m.apply(ctx, nil) }
func (m *Manifest) apply(ctx context.Context, checkpoint func(string) error) (Report, error) {
	report := Report{Outcome: "unchanged", ManifestHash: m.Digest(), Written: []string{}, Restored: []string{}}
	if err := ctx.Err(); err != nil {
		return report, err
	}
	if !exchangeSupported() {
		return report, fmt.Errorf("source application requires atomic file exchange on this platform")
	}
	if err := m.requireSaved(); err != nil {
		return report, err
	}
	reserved := filepath.Join(m.ProjectRoot(), transactionDirectory)
	tree, err := openTree(m.ProjectRoot())
	if err != nil {
		return report, err
	}
	defer func() { _ = tree.root.Close() }()
	if _, err := tree.kind(reserved); !errors.Is(err, os.ErrNotExist) {
		report.RecoveryRequired = true
		if err != nil {
			return report, err
		}
		return report, fmt.Errorf("source transaction is already present; use migrate recover-source after its owner exits")
	}
	if err := m.verifyDisk(tree); err != nil {
		return report, err
	}
	if len(m.wire.Edits) == 0 {
		return report, nil
	}
	tx := &transaction{checkpoint: checkpoint, manifest: m, tree: tree, state: reserved, applied: map[string]bool{}, created: map[string]bool{}, report: report}
	step := func(name string) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if checkpoint != nil {
			return checkpoint(name)
		}
		return nil
	}
	if err := step("before-lock"); err != nil {
		return report, err
	}
	if err := tree.root.Mkdir(transactionDirectory, 0700); err != nil {
		return report, fmt.Errorf("source transaction is already present or cannot be created; inspect recovery state: %w", err)
	}
	tx.identity, err = tree.kind(reserved)
	if err != nil {
		return report, err
	}
	tx.owner, err = claimOwner(tree, reserved, tx.identity, true)
	if err != nil {
		tx.report.RecoveryRequired = true
		return tx.report, err
	}
	defer func() { _ = tx.owner.Close() }()
	// Before the journal is durable, no application source or source directory may
	// change. A torn preparation can therefore require cleanup but cannot have
	// partially applied a migration.
	err = step("before-prepare")
	if err == nil {
		err = tx.prepare()
	}
	if err != nil {
		cleanupErr := tx.discardPreparation()
		tx.report.RecoveryRequired = cleanupErr != nil
		return tx.report, errors.Join(err, cleanupErr)
	}
	err = step("journal-durable")
	if err == nil {
		err = tx.perform(step)
	}
	if err != nil {
		original := err
		if restoreErr := tx.rollback(checkpoint); restoreErr != nil {
			tx.report.RecoveryRequired = true
			return tx.report, errors.Join(original, restoreErr)
		}
		return tx.report, original
	}
	return tx.report, nil
}
func (tx *transaction) relative(path string) string { rel, _ := tx.tree.relative(path); return rel }

// The journal always retains the original manifest, including every open-buffer
// and source-view guard. Only the physical operations are partitioned: an editor
// transaction never writes an open buffer's path through the filesystem.
func (tx *transaction) fileManifest() wireManifest {
	w := tx.manifest.wire
	if tx.editor {
		w.Edits = tx.files
	}
	return w
}

func closedEdits(m *Manifest) []edit {
	files := make([]edit, 0, len(m.wire.Edits))
	for _, e := range m.wire.Edits {
		if e.DocumentVersion == nil {
			files = append(files, e)
		}
	}
	return files
}

func (tx *transaction) stateFile(name string) string { return filepath.Join(tx.state, name) }
func (tx *transaction) stage(i int) string           { return tx.stateFile(fmt.Sprintf("source-%06d", i)) }
func (tx *transaction) syncDir(path string) error {
	file, err := openRegular(tx.tree.root, tx.relative(path))
	if err != nil {
		return err
	}
	syncErr := file.Sync()
	return errors.Join(syncErr, file.Close())
}
func (tx *transaction) writeNew(path string, data []byte, mode fs.FileMode) error {
	file, err := tx.tree.root.OpenFile(tx.relative(path), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(data)
	if writeErr == nil {
		writeErr = file.Chmod(mode)
	}
	if writeErr == nil {
		writeErr = file.Sync()
	}
	return errors.Join(writeErr, file.Close())
}
func (tx *transaction) prepare() error {
	w := tx.fileManifest()
	paths := requiredDirectories(w)
	modes := make([]uint32, len(w.Edits))
	for i, e := range w.Edits {
		modes[i] = 0600
		if e.BeforeHex != nil {
			info, err := tx.tree.kind(e.Path)
			if err != nil {
				return err
			}
			if !info.Mode().IsRegular() {
				return fmt.Errorf("source is no longer regular: %s", e.Path)
			}
			modes[i] = uint32(info.Mode().Perm())
		}
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	version := 1
	if tx.editor {
		version = 2
	}
	tx.journal = journal{Nonce: hex.EncodeToString(nonce), Version: version, Phase: "prepared", Manifest: tx.manifest.JSON(), ManifestHash: tx.manifest.Digest(), CreatedDirectories: paths, Modes: modes}
	data, err := json.Marshal(tx.journal)
	if err != nil {
		return err
	}
	if len(data) > maxManifestBytes {
		return fmt.Errorf("source journal exceeds its byte limit")
	}
	if err := tx.writeNew(tx.stateFile("journal.tmp"), data, 0600); err != nil {
		return err
	}
	if err := tx.tree.root.Rename(tx.relative(tx.stateFile("journal.tmp")), tx.relative(tx.stateFile("journal.json"))); err != nil {
		return err
	}
	if err := tx.syncDir(tx.state); err != nil {
		return err
	}
	return tx.syncDir(w.ProjectRoot)
}
func (tx *transaction) verifyState() error {
	if err := tx.tree.verifyRoot(); err != nil {
		return err
	}
	info, err := tx.tree.kind(tx.state)
	if err != nil {
		return err
	}
	if !info.IsDir() || !os.SameFile(info, tx.identity) {
		return fmt.Errorf("source transaction directory changed")
	}
	ownerInfo, err := tx.tree.kind(tx.stateFile("owner"))
	if err != nil {
		return err
	}
	ownedInfo, err := tx.owner.Stat()
	if err != nil {
		return err
	}
	if !os.SameFile(ownerInfo, ownedInfo) {
		return fmt.Errorf("source transaction ownership file changed")
	}
	data, exists, err := tx.tree.bytes(tx.stateFile("journal.json"))
	if err != nil {
		return err
	}
	expected, encodeErr := json.Marshal(tx.journal)
	if encodeErr != nil {
		return encodeErr
	}
	if !exists || !bytes.Equal(data, expected) {
		return fmt.Errorf("source transaction journal changed")
	}
	return nil
}
func (tx *transaction) verifyProgress() error {
	if err := tx.verifyState(); err != nil {
		return err
	}
	w := tx.fileManifest()
	added := map[string]map[string]bool{}
	add := func(path string) {
		parent := filepath.Dir(path)
		if added[parent] == nil {
			added[parent] = map[string]bool{}
		}
		added[parent][filepath.Base(path)] = true
	}
	add(tx.state)
	for path := range tx.created {
		add(path)
		add(filepath.Join(path, ownedDirectoryMarker))
		owned, err := tx.ownsDirectory(path, path)
		if err != nil {
			return err
		}
		if !owned {
			return fmt.Errorf("created source directory ownership changed: %s", path)
		}
	}
	for _, e := range w.Edits {
		if tx.applied[e.Path] && e.BeforeHex == nil {
			add(e.Path)
		}
	}
	for _, g := range w.Imports {
		if resolveImport(g.Source, g.Module) != g.DiskResolved {
			return fmt.Errorf("import resolution changed during source application: %s", g.Module)
		}
	}
	for _, g := range w.Inputs {
		expected := g.DiskHash
		if tx.applied[g.Path] {
			for _, e := range w.Edits {
				if e.Path == g.Path {
					data, _ := hex.DecodeString(e.AfterHex)
					value := hash(data)
					expected = &value
				}
			}
		}
		actual, err := tx.tree.fileHash(g.Path)
		if err != nil {
			return err
		}
		if !same(expected, actual) {
			return fmt.Errorf("saved source changed during source application: %s", g.Path)
		}
	}
	for _, g := range w.Directories {
		names, exists, err := tx.tree.names(g.Path)
		if err != nil {
			return err
		}
		if g.DiskHash == nil {
			if tx.created[g.Path] {
				if !exists {
					return fmt.Errorf("new source directory disappeared: %s", g.Path)
				}
			} else if exists {
				return fmt.Errorf("source directory appeared during application: %s", g.Path)
			}
		} else if !exists {
			return fmt.Errorf("source directory disappeared: %s", g.Path)
		}
		remaining := make([]string, 0, len(names))
		for _, name := range names {
			if !added[g.Path][name] {
				remaining = append(remaining, name)
			}
		}
		if g.DiskHash == nil {
			if len(remaining) != 0 {
				return fmt.Errorf("new source directory changed: %s", g.Path)
			}
		} else if directoryHash(remaining) != *g.DiskHash {
			return fmt.Errorf("source directory membership changed during application: %s", g.Path)
		}
	}
	for i, e := range w.Edits {
		if e.BeforeHex != nil || tx.applied[e.Path] {
			info, err := tx.tree.kind(e.Path)
			if err != nil {
				return err
			}
			if uint32(info.Mode().Perm()) != tx.journal.Modes[i] {
				return fmt.Errorf("source permissions changed during application: %s", e.Path)
			}
		}
	}
	for i, e := range w.Edits {
		if !tx.applied[e.Path] || e.BeforeHex == nil {
			continue
		}
		data, exists, err := tx.tree.bytes(tx.stage(i))
		if err != nil {
			return err
		}
		before, _ := hex.DecodeString(*e.BeforeHex)
		info, statErr := tx.tree.kind(tx.stage(i))
		if statErr != nil {
			return statErr
		}
		if uint32(info.Mode().Perm()) != tx.journal.Modes[i] {
			return fmt.Errorf("displaced source permissions changed during application: %s", e.Path)
		}
		if !exists || !bytes.Equal(before, data) {
			return fmt.Errorf("displaced source changed during application: %s", e.Path)
		}
	}
	return nil
}
func (tx *transaction) perform(step func(string) error) error {
	if err := tx.publish(step); err != nil {
		return err
	}
	return tx.commit(step)
}

// Publication retains the prepared journal and every displaced inode. Keep the
// durable outcome separate so an editor coordinator can acknowledge its buffer
// edits before committing the filesystem half of the same source operation.
func (tx *transaction) publish(step func(string) error) error {
	if err := tx.verifyProgress(); err != nil {
		return err
	}
	for i, path := range tx.journal.CreatedDirectories {
		if err := step("before-directory:" + path); err != nil {
			return err
		}
		if err := tx.verifyProgress(); err != nil {
			return err
		}
		if err := tx.publishDirectory(i, path); err != nil {
			return err
		}
		tx.created[path] = true
		if err := tx.syncDir(filepath.Dir(path)); err != nil {
			return err
		}
		if err := step("after-directory:" + path); err != nil {
			return err
		}
	}
	for i, e := range tx.fileManifest().Edits {
		data, _ := hex.DecodeString(e.AfterHex)
		if err := tx.writeNew(tx.stage(i), data, fs.FileMode(tx.journal.Modes[i])); err != nil {
			return err
		}
		if err := tx.syncDir(tx.state); err != nil {
			return err
		}
		if err := step("staged:" + e.Path); err != nil {
			return err
		}
		if err := tx.verifyProgress(); err != nil {
			return err
		}
		if err := step("before-write:" + e.Path); err != nil {
			return err
		}
		if e.BeforeHex == nil {
			// Hard-link publication is atomic and refuses a concurrently created target.
			if err := tx.tree.root.Link(tx.relative(tx.stage(i)), tx.relative(e.Path)); err != nil {
				return err
			}
		} else if err := tx.tree.exchange(tx.stage(i), e.Path); err != nil {
			return err
		}
		if err := step("published:" + e.Path); err != nil {
			return err
		}
		tx.applied[e.Path] = true
		tx.report.Written = append(tx.report.Written, e.Path)
		if err := tx.syncDir(filepath.Dir(e.Path)); err != nil {
			return err
		}
		if err := tx.syncDir(tx.state); err != nil {
			return err
		}
		if err := step("written:" + e.Path); err != nil {
			return err
		}
		if err := tx.verifyProgress(); err != nil {
			return err
		}
	}
	return nil
}

func (tx *transaction) commit(step func(string) error) error {
	if err := step("before-commit"); err != nil {
		return err
	}
	if err := tx.verifyProgress(); err != nil {
		return err
	}
	if err := tx.recordOutcome("committed"); err != nil {
		return err
	}
	if err := step("committed"); err != nil {
		tx.report.RecoveryRequired = true
		return err
	}
	return tx.cleanup()
}

// rollback and cleanup are defined with recovery so normal failure and a process
// restart share exactly the same guarded inverse operations.

func (tx *transaction) recordOutcome(phase string) error {
	if err := tx.verifyState(); err != nil {
		return err
	}
	if err := tx.discardPendingJournal(); err != nil {
		return err
	}
	next := tx.journal
	next.Phase = phase
	data, err := json.Marshal(next)
	if err != nil {
		return err
	}
	if err := tx.writeNew(tx.stateFile("journal.tmp"), data, 0600); err != nil {
		return err
	}
	if err := tx.tree.root.Rename(tx.relative(tx.stateFile("journal.tmp")), tx.relative(tx.stateFile("journal.json"))); err != nil {
		return err
	}
	tx.journal = next
	tx.report.Outcome = phase
	if err := tx.syncDir(tx.state); err != nil {
		return err
	}
	if tx.checkpoint != nil {
		return tx.checkpoint("outcome-" + phase)
	}
	return nil
}
func (tx *transaction) discardPreparation() error {
	info, err := tx.tree.kind(tx.state)
	if err != nil {
		return err
	}
	if !os.SameFile(info, tx.identity) {
		return fmt.Errorf("transaction directory changed during preparation")
	}
	names, _, err := tx.tree.names(tx.state)
	if err != nil {
		return err
	}
	for _, name := range names {
		if name != "journal.tmp" && name != "journal.json" && name != "owner" {
			return fmt.Errorf("unexpected preparation file retained: %s", name)
		}
		info, err := tx.tree.kind(tx.stateFile(name))
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("preparation file changed: %s", name)
		}
	}
	for _, name := range names {
		if err := tx.tree.root.Remove(tx.relative(tx.stateFile(name))); err != nil {
			return err
		}
	}
	if err := tx.tree.root.Remove(tx.relative(tx.state)); err != nil {
		return err
	}
	return tx.syncDir(tx.manifest.ProjectRoot())
}

func claimOwner(tree *tree, state string, identity os.FileInfo, create bool) (*os.File, error) {
	current, err := tree.kind(state)
	if err != nil {
		return nil, err
	}
	if !os.SameFile(identity, current) {
		return nil, fmt.Errorf("source transaction directory changed before locking")
	}
	path := filepath.Join(state, "owner")
	relative, err := tree.relative(path)
	if err != nil {
		return nil, err
	}
	var file *os.File
	if create {
		file, err = tree.root.OpenFile(relative, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
	} else {
		file, err = openRegular(tree.root, relative)
		if errors.Is(err, os.ErrNotExist) {
			file, err = tree.root.OpenFile(relative, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0600)
		}
	}
	if err != nil {
		return nil, err
	}
	if err := lockOwner(file); err != nil {
		_ = file.Close()
		return nil, err
	}
	current, err = tree.kind(state)
	if err != nil || !os.SameFile(identity, current) {
		_ = file.Close()
		return nil, fmt.Errorf("source transaction directory changed while locking")
	}
	info, err := tree.kind(path)
	if err != nil {
		_ = file.Close()
		return nil, err
	}
	owned, err := file.Stat()
	if err != nil || !owned.Mode().IsRegular() || !os.SameFile(owned, info) {
		_ = file.Close()
		return nil, fmt.Errorf("source transaction owner changed while locking")
	}
	return file, nil
}

func (tx *transaction) discardPendingJournal() error {
	path := tx.stateFile("journal.tmp")
	info, err := tx.tree.kind(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("pending journal is not a regular file")
	}
	if err := tx.tree.root.Remove(tx.relative(path)); err != nil {
		return err
	}
	return tx.syncDir(tx.state)
}

func requiredDirectories(w wireManifest) []string {
	dirs := map[string]bool{}
	for _, e := range w.Edits {
		for p := filepath.Dir(e.Path); p != w.ProjectRoot; p = filepath.Dir(p) {
			for _, g := range w.Directories {
				if g.Path == p && g.DiskHash == nil {
					dirs[p] = true
				}
			}
		}
	}
	paths := make([]string, 0, len(dirs))
	for path := range dirs {
		paths = append(paths, path)
	}
	sort.Slice(paths, func(i, j int) bool {
		if len(paths[i]) != len(paths[j]) {
			return len(paths[i]) < len(paths[j])
		}
		return paths[i] < paths[j]
	})
	return paths
}

func (m *Manifest) requireSaved() error {
	if len(m.wire.Documents) != 0 {
		return fmt.Errorf("source application cannot save or overwrite open editor documents")
	}
	reserved := filepath.Join(m.ProjectRoot(), transactionDirectory)
	for _, g := range m.wire.Directories {
		if !same(g.SourceHash, g.DiskHash) {
			return fmt.Errorf("source directory view differs from saved membership: %s", g.Path)
		}
	}
	for _, g := range m.wire.Imports {
		if g.SourceResolved != g.DiskResolved {
			return fmt.Errorf("source import resolution differs from saved resolution: %s", g.Module)
		}
	}
	for _, g := range m.wire.Inputs {
		if !same(g.SourceHash, g.DiskHash) {
			return fmt.Errorf("source view differs from saved bytes: %s", g.Path)
		}
		if g.Path == reserved || strings.HasPrefix(g.Path, reserved+string(filepath.Separator)) {
			return fmt.Errorf("source input overlaps migration transaction state")
		}
	}
	return nil
}
