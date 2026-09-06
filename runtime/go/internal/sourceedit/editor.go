package sourceedit

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
)

// EditorDocument is a current, complete buffer snapshot supplied by the editor
// coordinator. The coordinator additionally owns document-lifetime checks and
// must process preceding document notifications before passing these snapshots.
type EditorDocument struct {
	Path    string
	Version int32
	Source  string
}

// EditorTransaction retains a durable journal and exclusive filesystem ownership
// while the editor performs its versioned buffer edits. It is single-owner and
// must be closed. Close never guesses that an outstanding client edit failed.
type EditorTransaction struct {
	tx             *transaction
	closed         bool
	publishStarted bool
	published      bool
}

func (m *Manifest) requireEditor() error {
	reserved := filepath.Join(m.ProjectRoot(), transactionDirectory)
	open := m.DocumentVersions()
	for _, input := range m.wire.Inputs {
		if input.Path == reserved || strings.HasPrefix(input.Path, reserved+string(filepath.Separator)) {
			return fmt.Errorf("source input overlaps migration transaction state")
		}
		if _, exists := open[input.Path]; !exists && !same(input.SourceHash, input.DiskHash) {
			return fmt.Errorf("closed source view differs from saved bytes: %s", input.Path)
		}
	}
	for _, edit := range m.wire.Edits {
		if edit.DocumentVersion != nil && *edit.DocumentVersion == math.MaxInt32 {
			return fmt.Errorf("editor document version cannot advance: %s", edit.Path)
		}
	}
	return nil
}

func (m *Manifest) verifyEditorDocuments(documents []EditorDocument, stage string) error {
	versions := m.DocumentVersions()
	if stage != "restored" && len(documents) != len(versions) {
		return fmt.Errorf("editor document set changed")
	}
	expected := make(map[string]string, len(versions))
	for _, input := range m.wire.Inputs {
		if _, open := versions[input.Path]; open && input.SourceHash != nil {
			expected[input.Path] = *input.SourceHash
		}
	}
	edited := make(map[string]bool)
	for _, edit := range m.wire.Edits {
		if edit.DocumentVersion != nil {
			edited[edit.Path] = true
			if stage == "applied" {
				after, _ := hex.DecodeString(edit.AfterHex)
				expected[edit.Path] = hash(after)
			}
		}
	}
	seen := make(map[string]bool)
	for _, doc := range documents {
		if stage == "restored" && !edited[doc.Path] {
			continue // An inverse must preserve unrelated user buffer changes.
		}
		version, exists := versions[doc.Path]
		if !exists || seen[doc.Path] || expected[doc.Path] != hash([]byte(doc.Source)) {
			return fmt.Errorf("editor source does not match %s state: %s", stage, doc.Path)
		}
		seen[doc.Path] = true
		if stage == "prepared" || !edited[doc.Path] {
			if doc.Version != version {
				return fmt.Errorf("editor source version changed: %s", doc.Path)
			}
		} else if doc.Version < version || (stage == "applied" && doc.Version == version) {
			return fmt.Errorf("editor did not acknowledge a new document version: %s", doc.Path)
		}
	}
	if stage == "restored" && len(seen) != len(edited) {
		return fmt.Errorf("edited buffers are missing from the restoration acknowledgement")
	}
	return nil
}

func (m *Manifest) PrepareEditor(ctx context.Context, documents []EditorDocument) (*EditorTransaction, Report, error) {
	return m.prepareEditor(ctx, documents, nil)
}

func (m *Manifest) prepareEditor(ctx context.Context, documents []EditorDocument, checkpoint func(string) error) (*EditorTransaction, Report, error) {
	report := Report{Outcome: "unchanged", ManifestHash: m.Digest(), Written: []string{}, Restored: []string{}}
	if err := ctx.Err(); err != nil {
		return nil, report, err
	}
	if !exchangeSupported() {
		return nil, report, fmt.Errorf("editor source application requires atomic file exchange on this platform")
	}
	if err := m.requireEditor(); err != nil {
		return nil, report, err
	}
	if err := m.verifyEditorDocuments(documents, "prepared"); err != nil {
		return nil, report, err
	}
	tree, err := openTree(m.ProjectRoot())
	if err != nil {
		return nil, report, err
	}
	tx := &transaction{checkpoint: checkpoint, manifest: m, editor: true, files: closedEdits(m), tree: tree,
		state: filepath.Join(m.ProjectRoot(), transactionDirectory), applied: map[string]bool{}, created: map[string]bool{}, report: report}
	retained := false
	defer func() {
		if !retained {
			if tx.owner != nil {
				_ = tx.owner.Close()
			}
			_ = tree.root.Close()
		}
	}()
	if _, err := tree.kind(tx.state); !errors.Is(err, os.ErrNotExist) {
		report.RecoveryRequired = true
		return nil, report, fmt.Errorf("source transaction is already present or unavailable; inspect recovery state")
	}
	if err := m.verifyDisk(tree); err != nil {
		return nil, report, err
	}
	editor := &EditorTransaction{tx: tx}
	if err := editor.step(ctx)("before-lock"); err != nil {
		return nil, report, err
	}
	if err := tree.root.Mkdir(transactionDirectory, 0700); err != nil {
		report.RecoveryRequired = true
		return nil, report, err
	}
	tx.identity, err = tree.kind(tx.state)
	if err != nil {
		report.RecoveryRequired = true
		return nil, report, err
	}
	tx.owner, err = claimOwner(tree, tx.state, tx.identity, true)
	if err != nil {
		report.RecoveryRequired = true
		return nil, report, err
	}
	err = editor.step(ctx)("before-prepare")
	if err == nil {
		err = tx.prepare()
	}
	if err != nil {
		cleanup := tx.discardPreparation()
		tx.report.RecoveryRequired = cleanup != nil
		return nil, editor.Report(), errors.Join(err, cleanup)
	}
	tx.report.Outcome = "prepared"
	if err := editor.step(ctx)("journal-durable"); err != nil {
		cleanup := tx.rollback(checkpoint)
		tx.report.RecoveryRequired = cleanup != nil
		return nil, editor.Report(), errors.Join(err, cleanup)
	}
	retained = true
	return editor, editor.Report(), nil
}

func (editor *EditorTransaction) step(ctx context.Context) func(string) error {
	return func(name string) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if editor.tx.checkpoint != nil {
			return editor.tx.checkpoint(name)
		}
		return nil
	}
}

func (editor *EditorTransaction) requirePhase(phase string) error {
	if editor.closed || editor.tx.journal.Phase != phase {
		return fmt.Errorf("editor source transaction is not in %s phase", phase)
	}
	return nil
}

// Publish writes closed files only, retaining the prepared journal and backups.
// A failure needs Abort or retained recovery state; it is never retried in place.
func (editor *EditorTransaction) Publish(ctx context.Context) (Report, error) {
	if err := editor.requirePhase("prepared"); err != nil {
		return editor.Report(), err
	}
	if editor.publishStarted {
		return editor.Report(), fmt.Errorf("editor source publication already started")
	}
	editor.publishStarted = true
	err := editor.tx.publish(editor.step(ctx))
	editor.published = err == nil
	editor.tx.report.RecoveryRequired = err != nil
	return editor.Report(), err
}

// BeginClientEdits MUST succeed before any workspace/applyEdit request is sent.
// Once this marker is durable, automatic disk-only recovery refuses to infer the
// state of editor buffers. Even a request with no reply might have applied edits.
func (editor *EditorTransaction) BeginClientEdits(ctx context.Context) (Report, error) {
	if err := editor.requirePhase("prepared"); err != nil {
		return editor.Report(), err
	}
	if !editor.published {
		return editor.Report(), fmt.Errorf("closed source publication is incomplete")
	}
	if len(editor.tx.files) == len(editor.tx.manifest.wire.Edits) {
		return editor.Report(), fmt.Errorf("no buffer edits are needed; commit without a client request")
	}
	err := editor.step(ctx)("before-client")
	if err == nil {
		err = editor.tx.verifyProgress()
	}
	if err == nil {
		err = editor.tx.recordOutcome("editor-pending")
	}
	if err == nil {
		err = editor.step(ctx)("client-pending")
	}
	editor.tx.report.RecoveryRequired = err != nil
	return editor.Report(), err
}

// CommitWithoutClient completes a proposal containing only closed-file edits.
// Unedited open inputs still need their original content and version guards.
func (editor *EditorTransaction) CommitWithoutClient(ctx context.Context, documents []EditorDocument) (Report, error) {
	if err := editor.requirePhase("prepared"); err != nil {
		return editor.Report(), err
	}
	if !editor.published || len(editor.tx.files) != len(editor.tx.manifest.wire.Edits) {
		return editor.Report(), fmt.Errorf("publication is incomplete or buffer edits require acknowledgement")
	}
	if err := editor.tx.manifest.verifyEditorDocuments(documents, "prepared"); err != nil {
		return editor.Report(), err
	}
	return editor.finish(editor.tx.commit(editor.step(ctx)))
}

// Commit requires acknowledged, completed client requests and the resulting
// current buffer snapshots. A timeout is not an acknowledgement: leave the
// journal for editor recovery instead of calling Commit or Restore.
func (editor *EditorTransaction) Commit(ctx context.Context, documents []EditorDocument) (Report, error) {
	if err := editor.requirePhase("editor-pending"); err != nil {
		return editor.Report(), err
	}
	if err := editor.tx.manifest.verifyEditorDocuments(documents, "applied"); err != nil {
		return editor.Report(), err
	}
	return editor.finish(editor.tx.commit(editor.step(ctx)))
}

// Abort is allowed before the client marker only: no editor requests may have
// been sent. Restore instead requires all client requests (including inverse
// edits) to have completed and the original buffers to have been observed again.
func (editor *EditorTransaction) Abort(ctx context.Context) (Report, error) {
	if err := editor.requirePhase("prepared"); err != nil {
		return editor.Report(), err
	}
	return editor.finish(editor.tx.rollback(editor.step(ctx)))
}

func (editor *EditorTransaction) Restore(ctx context.Context, documents []EditorDocument) (Report, error) {
	if err := editor.requirePhase("editor-pending"); err != nil {
		return editor.Report(), err
	}
	if err := editor.tx.manifest.verifyEditorDocuments(documents, "restored"); err != nil {
		return editor.Report(), err
	}
	return editor.finish(editor.tx.rollback(editor.step(ctx)))
}

func (editor *EditorTransaction) finish(err error) (Report, error) {
	editor.tx.report.RecoveryRequired = err != nil
	if editor.tx.journal.Phase == "committed" || editor.tx.journal.Phase == "restored" {
		err = errors.Join(err, editor.Close())
	}
	return editor.Report(), err
}

func (editor *EditorTransaction) Report() Report {
	report := editor.tx.report
	report.Written = append([]string{}, report.Written...)
	report.Restored = append([]string{}, report.Restored...)
	return report
}

// Close releases ownership without altering source. An unresolved editor-pending
// journal requires reconciliation with the editor; a disk-only inverse is unsafe.
func (editor *EditorTransaction) Close() error {
	if editor.closed {
		return nil
	}
	editor.closed = true
	if editor.tx.journal.Phase != "committed" && editor.tx.journal.Phase != "restored" {
		editor.tx.report.RecoveryRequired = true
	}
	err := errors.Join(editor.tx.owner.Close(), editor.tx.tree.root.Close())
	if err != nil {
		editor.tx.report.RecoveryRequired = true
	}
	return err
}
