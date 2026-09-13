package sourceedit

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
)

// Recover either finishes cleanup of a committed source transaction or applies
// its guarded inverse. Unexpected user bytes are preserved and reported, never
// replaced by a journal preimage merely because a transaction was interrupted.
func Recover(ctx context.Context, root string) (Report, error) {
	return recoverWithCheckpoint(ctx, root, nil)
}
func recoverWithCheckpoint(ctx context.Context, root string, checkpoint func(string) error) (Report, error) {
	report := Report{Outcome: "unchanged", Written: []string{}, Restored: []string{}}
	if err := ctx.Err(); err != nil {
		return report, err
	}
	if !exchangeSupported() {
		return report, fmt.Errorf("source recovery requires atomic file exchange on this platform")
	}
	tree, err := openTree(root)
	if err != nil {
		return report, err
	}
	defer func() { _ = tree.root.Close() }()
	state := filepath.Join(root, transactionDirectory)
	info, err := tree.kind(state)
	if errors.Is(err, os.ErrNotExist) {
		return report, nil
	}
	if err != nil {
		return report, err
	}
	report.RecoveryRequired = true
	if !info.IsDir() {
		return report, fmt.Errorf("source transaction state is not a directory")
	}
	owner, err := claimOwner(tree, state, info, false)
	if err != nil {
		return report, err
	}
	defer func() { _ = owner.Close() }()
	report.RecoveryRequired = true
	data, exists, err := tree.bytes(filepath.Join(state, "journal.json"))
	if err != nil {
		return report, err
	}
	if !exists {
		// This is either interrupted preparation or the final empty directory
		// after terminal cleanup. No backup/source slots may be discarded here.
		names, _, err := tree.names(state)
		if err != nil {
			return report, err
		}
		for _, name := range names {
			if name != "journal.tmp" && name != "owner" {
				report.RecoveryRequired = true
				return report, fmt.Errorf("source transaction journal is unavailable; retained operation data needs inspection")
			}
			entry, err := tree.kind(filepath.Join(state, name))
			if err != nil {
				return report, err
			}
			if !entry.Mode().IsRegular() {
				return report, fmt.Errorf("invalid source preparation file")
			}
		}
		for _, name := range names {
			if err := tree.root.Remove(filepath.Join(transactionDirectory, name)); err != nil {
				return report, err
			}
		}
		if err := tree.root.Remove(transactionDirectory); err != nil {
			return report, err
		}
		tx := &transaction{tree: tree}
		if err := tx.syncDir(root); err != nil {
			return report, err
		}
		report.RecoveryRequired = false
		return report, nil
	}
	if err := strictJSON(data); err != nil {
		return report, err
	}
	if _, err := object(data, "version", "phase", "nonce", "manifest", "manifestHash", "createdDirectories", "modes"); err != nil {
		return report, err
	}
	var j journal
	if err := json.Unmarshal(data, &j); err != nil {
		return report, err
	}
	m, err := Decode(j.Manifest)
	if err != nil {
		return report, err
	}
	if len(j.Nonce) != 64 || !validHex(j.Nonce) {
		return report, fmt.Errorf("invalid source transaction identity")
	}
	phaseOK := j.Phase == "prepared" || j.Phase == "committed" || j.Phase == "restored" || (j.Version == 2 && j.Phase == "editor-pending")
	if !phaseOK || (j.Version != 1 && j.Version != 2) || j.ManifestHash != m.Digest() || m.ProjectRoot() != root {
		return report, fmt.Errorf("source recovery journal identity is invalid")
	}
	physical := m.wire
	if j.Version == 2 {
		if err := m.requireEditor(); err != nil {
			return report, err
		}
		physical.Edits = closedEdits(m)
	} else {
		if err := m.requireSaved(); err != nil {
			return report, err
		}
	}
	if len(j.Modes) != len(physical.Edits) {
		return report, fmt.Errorf("source recovery operation modes disagree with the manifest")
	}
	if !slices.Equal(j.CreatedDirectories, requiredDirectories(physical)) {
		return report, fmt.Errorf("recovery directories disagree with the reviewed source operations")
	}
	for _, mode := range j.Modes {
		if mode > 0777 {
			return report, fmt.Errorf("invalid recovered source permissions")
		}
	}
	report.ManifestHash = m.Digest()
	report.Outcome = j.Phase
	tx := &transaction{checkpoint: checkpoint, owner: owner, manifest: m, editor: j.Version == 2, files: physical.Edits,
		tree: tree, state: state, identity: info, journal: j, applied: map[string]bool{}, created: map[string]bool{}, report: report}
	step := func(name string) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if checkpoint != nil {
			return checkpoint(name)
		}
		return nil
	}
	if err := tx.verifyState(); err != nil {
		return report, err
	}
	if j.Phase == "editor-pending" {
		return report, fmt.Errorf("editor source request outcome is unknown; reconcile editor buffers before recovery")
	}
	if err := tx.rollback(step); err != nil {
		tx.report.RecoveryRequired = true
		return tx.report, err
	}
	tx.report.RecoveryRequired = false
	return tx.report, nil
}
func (tx *transaction) rollback(step func(string) error) error {
	if err := tx.verifyState(); err != nil {
		return err
	}
	if tx.journal.Phase == "committed" || tx.journal.Phase == "restored" {
		return tx.cleanup()
	}
	if err := tx.restorePublished(step); err != nil {
		return err
	}
	if err := tx.recordOutcome("restored"); err != nil {
		return err
	}
	return tx.cleanup()
}

// Restoring files alone does not establish a terminal outcome for a future
// mixed editor operation. Its buffer inverse must also be acknowledged first.
func (tx *transaction) restorePublished(step func(string) error) error {
	var failures []error
	files := tx.fileManifest().Edits
	for i := len(files) - 1; i >= 0; i-- {
		e := files[i]
		if step != nil {
			if err := step("before-restore:" + e.Path); err != nil {
				return errors.Join(append(failures, err)...)
			}
		}
		if err := tx.restore(i, step); err != nil {
			failures = append(failures, err)
		}
	}
	if len(failures) != 0 {
		return errors.Join(failures...)
	}
	return tx.restoreDirectories()
}
func (tx *transaction) restore(i int, step func(string) error) error {
	e := tx.fileManifest().Edits[i]
	after, _ := hex.DecodeString(e.AfterHex)
	var before []byte
	if e.BeforeHex != nil {
		before, _ = hex.DecodeString(*e.BeforeHex)
	}
	current, exists, err := tx.tree.bytes(e.Path)
	if err != nil {
		return err
	}
	staged, stageExists, err := tx.tree.bytes(tx.stage(i))
	if err != nil {
		return err
	}
	capture := tx.stateFile(fmt.Sprintf("capture-%06d", i))
	displaced, captureExists, err := tx.tree.bytes(capture)
	if err != nil {
		return err
	}
	if exists && stageExists && captureExists && bytes.Equal(displaced, after) && e.BeforeHex != nil {
		a, err := tx.tree.kind(e.Path)
		if err != nil {
			return err
		}
		b, err := tx.tree.kind(tx.stage(i))
		if err != nil {
			return err
		}
		if os.SameFile(a, b) {
			return nil
		} // interrupted inverse already restored the captured inode
	}
	matchesBefore := exists == (e.BeforeHex != nil) && (!exists || bytes.Equal(current, before))
	if matchesBefore {
		if captureExists && !bytes.Equal(displaced, after) {
			return fmt.Errorf("unexpected captured user source retained in %s", capture)
		}
		return nil
	}
	if captureExists {
		// A prior inverse may have stopped after moving our output into capture.
		if !bytes.Equal(displaced, after) {
			if !exists {
				if err := tx.tree.root.Link(tx.relative(capture), tx.relative(e.Path)); err != nil {
					return err
				}
				if err := tx.syncDir(filepath.Dir(e.Path)); err != nil {
					return err
				}
			}
			return fmt.Errorf("source changed during inverse; captured user bytes retained in %s", capture)
		}
		if exists {
			return fmt.Errorf("source changed while recovery was interrupted: %s", e.Path)
		}
	} else {
		if !exists || !bytes.Equal(current, after) || !stageExists {
			return fmt.Errorf("source changed after publication; refusing to overwrite it: %s", e.Path)
		}
		if e.BeforeHex == nil {
			a, err := tx.tree.kind(e.Path)
			if err != nil {
				return err
			}
			b, err := tx.tree.kind(tx.stage(i))
			if err != nil {
				return err
			}
			if !os.SameFile(a, b) {
				return fmt.Errorf("a concurrently created source is not owned by this transaction: %s", e.Path)
			}
		} else if bytes.Equal(staged, after) {
			return fmt.Errorf("target changed before this transaction could capture its preimage: %s", e.Path)
		}
		// Move instead of unlinking: even a last-moment save between the comparison
		// and this operation remains recoverable as an intact captured inode.
		if step != nil {
			if err := step("before-capture:" + e.Path); err != nil {
				return err
			}
		}
		if err := tx.tree.moveNoReplace(e.Path, capture); err != nil {
			return err
		}
		if err := tx.syncDir(filepath.Dir(e.Path)); err != nil {
			return err
		}
		if err := tx.syncDir(tx.state); err != nil {
			return err
		}
		if step != nil {
			if err := step("captured:" + e.Path); err != nil {
				return err
			}
		}
		displaced, captureExists, err = tx.tree.bytes(capture)
		if err != nil {
			return err
		}
		if !captureExists || !bytes.Equal(displaced, after) {
			if captureExists {
				if err := tx.tree.root.Link(tx.relative(capture), tx.relative(e.Path)); err != nil {
					return err
				}
				if err := tx.syncDir(filepath.Dir(e.Path)); err != nil {
					return err
				}
			}
			return fmt.Errorf("concurrent source save was preserved during inverse: %s", e.Path)
		}
	}
	if e.BeforeHex != nil {
		if !stageExists {
			return fmt.Errorf("captured original source is missing: %s", e.Path)
		}
		// Exchange kept the actual prior inode, including a concurrent edit rejected
		// by the post-exchange preimage check. Restore it with no-replace publication.
		if err := tx.tree.root.Link(tx.relative(tx.stage(i)), tx.relative(e.Path)); err != nil {
			return err
		}
		if err := tx.syncDir(filepath.Dir(e.Path)); err != nil {
			return err
		}
	}
	tx.report.Restored = append(tx.report.Restored, e.Path)
	if step != nil {
		if err := step("restored:" + e.Path); err != nil {
			return err
		}
	}
	return nil
}
func (tx *transaction) cleanup() error {
	if err := tx.verifyState(); err != nil {
		return err
	}
	if err := tx.cleanDirectoryMarkers(); err != nil {
		return err
	}
	allowed := map[string]bool{"journal.json": true, "journal.tmp": true, "owner": true}
	for i := range tx.fileManifest().Edits {
		allowed[fmt.Sprintf("source-%06d", i)] = true
		allowed[fmt.Sprintf("capture-%06d", i)] = true
	}
	names, exists, err := tx.tree.names(tx.state)
	if err != nil {
		return err
	}
	if !exists {
		return fmt.Errorf("source transaction disappeared")
	}
	for _, name := range names {
		if !allowed[name] {
			return fmt.Errorf("unrecognized transaction file retained: %s", filepath.Join(tx.state, name))
		}
		info, err := tx.tree.kind(tx.stateFile(name))
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("transaction metadata changed kind: %s", name)
		}
	}
	// Refuse to discard bytes different from either reviewed image. In particular,
	// a write through an old open descriptor must not disappear with its backup.
	for i, e := range tx.fileManifest().Edits {
		after, _ := hex.DecodeString(e.AfterHex)
		var before []byte
		if e.BeforeHex != nil {
			before, _ = hex.DecodeString(*e.BeforeHex)
		}
		for _, name := range []string{fmt.Sprintf("source-%06d", i), fmt.Sprintf("capture-%06d", i)} {
			path := tx.stateFile(name)
			data, exists, err := tx.tree.bytes(path)
			if err != nil {
				return err
			}
			if !exists {
				continue
			}
			if !bytes.Equal(data, after) && (e.BeforeHex == nil || !bytes.Equal(data, before)) {
				// Unknown captured bytes can be removed only as an extra link to the same
				// restored source inode; their current live location then retains them.
				original, err := tx.tree.kind(e.Path)
				if err != nil {
					return fmt.Errorf("unrecognized captured source retained: %s", path)
				}
				saved, err := tx.tree.kind(path)
				if err != nil {
					return err
				}
				if !os.SameFile(original, saved) {
					return fmt.Errorf("unrecognized captured source retained: %s", path)
				}
			}
		}
	}
	for _, name := range names {
		if name == "journal.json" || name == "owner" {
			continue
		}
		if err := tx.tree.root.Remove(tx.relative(tx.stateFile(name))); err != nil {
			return err
		}
		if tx.checkpoint != nil {
			if err := tx.checkpoint("cleaned:" + name); err != nil {
				return err
			}
		}
	}
	if err := tx.syncDir(tx.state); err != nil {
		return err
	}
	// The durable outcome remains in the journal until every backup is gone.
	// A restart can only repeat cleanup after either terminal outcome.
	for _, name := range []string{"journal.json", "owner"} {
		if err := tx.tree.root.Remove(tx.relative(tx.stateFile(name))); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if tx.checkpoint != nil {
			if err := tx.checkpoint("cleaned:" + name); err != nil {
				return err
			}
		}
	}
	if err := tx.tree.root.Remove(tx.relative(tx.state)); err != nil {
		return err
	}
	return tx.syncDir(tx.manifest.ProjectRoot())
}
