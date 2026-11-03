package sourceedit

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const ownedDirectoryMarker = ".tesl-source-directory"

func (tx *transaction) directorySlot(i int, removed bool) string {
	prefix := "directory"
	if removed {
		prefix = "removed-directory"
	}
	return tx.stateFile(fmt.Sprintf("%s-%06d", prefix, i))
}
func (tx *transaction) directoryToken(target string) []byte {
	return []byte("tesl-source-directory-v1\n" + tx.journal.Nonce + "\n" + target + "\n")
}
func (tx *transaction) ownsDirectory(location, target string) (bool, error) {
	info, err := tx.tree.kind(location)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.IsDir() {
		return false, fmt.Errorf("source directory changed kind: %s", location)
	}
	data, exists, err := tx.tree.bytes(filepath.Join(location, ownedDirectoryMarker))
	if err != nil {
		return false, err
	}
	return exists && bytes.Equal(data, tx.directoryToken(target)), nil
}
func (tx *transaction) publishDirectory(i int, target string) error {
	staged := tx.directorySlot(i, false)
	if err := tx.tree.root.Mkdir(tx.relative(staged), 0700); err != nil {
		return err
	}
	if err := tx.writeNew(filepath.Join(staged, ownedDirectoryMarker), tx.directoryToken(target), 0600); err != nil {
		return err
	}
	if err := tx.syncDir(staged); err != nil {
		return err
	}
	if err := tx.syncDir(tx.state); err != nil {
		return err
	}
	if tx.checkpoint != nil {
		if err := tx.checkpoint("staged-directory:" + target); err != nil {
			return err
		}
	}
	// A user-created empty directory must never be overwritten by rename. The
	// marker is already durable when this directory becomes visible in the source.
	if err := tx.tree.moveNoReplace(staged, target); err != nil {
		return err
	}
	if err := tx.syncDir(filepath.Dir(target)); err != nil {
		return err
	}
	return tx.syncDir(tx.state)
}
func (tx *transaction) restoreDirectories() error {
	for i := len(tx.journal.CreatedDirectories) - 1; i >= 0; i-- {
		target := tx.journal.CreatedDirectories[i]
		owned, err := tx.ownsDirectory(target, target)
		if err != nil {
			return err
		}
		removed := tx.directorySlot(i, true)
		if owned {
			names, _, err := tx.tree.names(target)
			if err != nil {
				return err
			}
			if len(names) != 1 || names[0] != ownedDirectoryMarker {
				return fmt.Errorf("new source directory contains unrelated files: %s", target)
			}
			if err := tx.tree.moveNoReplace(target, removed); err != nil {
				return err
			}
			if err := tx.syncDir(filepath.Dir(target)); err != nil {
				return err
			}
			if err := tx.syncDir(tx.state); err != nil {
				return err
			}
			if tx.checkpoint != nil {
				if err := tx.checkpoint("captured-directory:" + target); err != nil {
					return err
				}
			}
		}
		if err := tx.cleanDirectorySlot(removed, target, true); err != nil {
			return err
		}
		if err := tx.cleanDirectorySlot(tx.directorySlot(i, false), target, false); err != nil {
			return err
		}
	}
	return nil
}
func (tx *transaction) cleanDirectorySlot(slot, target string, wasPublished bool) error {
	names, exists, err := tx.tree.names(slot)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	owned, err := tx.ownsDirectory(slot, target)
	if err != nil {
		return err
	}
	valid := len(names) == 0
	if len(names) == 1 && names[0] == ownedDirectoryMarker {
		data, _, err := tx.tree.bytes(filepath.Join(slot, ownedDirectoryMarker))
		if err != nil {
			return err
		}
		// An unpublished stage may contain a torn marker. It cannot have changed
		// application sources; complete markers are required before publication.
		valid = owned || (!wasPublished && bytes.HasPrefix(tx.directoryToken(target), data))
	}
	if !valid {
		if wasPublished {
			// Preserve a save racing directory capture, including files written via a
			// previously opened directory handle. Publication refuses a new destination.
			if err := tx.tree.moveNoReplace(slot, target); err != nil {
				return errors.Join(fmt.Errorf("captured directory contains user data: %s", slot), err)
			}
			if err := tx.syncDir(filepath.Dir(target)); err != nil {
				return err
			}
		}
		return fmt.Errorf("source directory has changed; user data was preserved: %s", target)
	}
	if len(names) == 1 {
		if err := tx.tree.root.Remove(tx.relative(filepath.Join(slot, ownedDirectoryMarker))); err != nil {
			return err
		}
	}
	if err := tx.tree.root.Remove(tx.relative(slot)); err != nil {
		if wasPublished {
			if restoreErr := tx.tree.moveNoReplace(slot, target); restoreErr != nil {
				return errors.Join(err, restoreErr)
			}
		}
		return err
	}
	return tx.syncDir(tx.state)
}
func (tx *transaction) cleanDirectoryMarkers() error {
	for i, target := range tx.journal.CreatedDirectories {
		if tx.journal.Phase == "committed" {
			marker := filepath.Join(target, ownedDirectoryMarker)
			data, exists, err := tx.tree.bytes(marker)
			if err != nil {
				return err
			}
			if exists {
				if !bytes.Equal(data, tx.directoryToken(target)) {
					return fmt.Errorf("source directory marker changed: %s", target)
				}
				if err := tx.tree.root.Remove(tx.relative(marker)); err != nil {
					return err
				}
				if err := tx.syncDir(target); err != nil {
					return err
				}
				if tx.checkpoint != nil {
					if err := tx.checkpoint("cleaned-directory:" + target); err != nil {
						return err
					}
				}
			}
		}
		if err := tx.cleanDirectorySlot(tx.directorySlot(i, false), target, false); err != nil {
			return err
		}
		if err := tx.cleanDirectorySlot(tx.directorySlot(i, true), target, true); err != nil {
			return err
		}
	}
	return nil
}
