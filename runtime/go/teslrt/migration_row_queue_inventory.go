package teslrt

import (
	"fmt"
)

// This binds a complete compiler-owned source inventory. It does not grant
// queue dispatch, establish a legacy origin, or identify row expansion receipts
// as source storage hashes. The fresh installer persists the binding separately.
type pgRowQueueSource struct {
	version              PgQueueSourceVersion
	inventoryHash        string
	binding, bindingHash string
	queues, facilities   pgRowCanonical
}

func pgRowQueueSources(history PgCompiledMigrationHistory) ([]pgRowQueueSource, error) {
	if _, err := pgReadRowBase(history); err != nil {
		return nil, err
	}
	inventory, err := history.QueueSourceInventory(1)
	if err != nil {
		return nil, err
	}
	// QueueSourceInventory replays the complete row source, including queue roots
	// and payload closure containment. Never manufacture an empty companion here.
	if inventory.Database != history.Database || inventory.Family != history.Family || inventory.Namespace != history.Namespace || inventory.InitialVersion != 1 || inventory.CurrentVersion != history.CurrentVersion || len(inventory.Versions) != history.CurrentVersion {
		return nil, fmt.Errorf("row queue inventory owner or complete version range differs")
	}
	result := make([]pgRowQueueSource, 0, len(inventory.Versions))
	for i, version := range inventory.Versions {
		if version.Version != i+1 {
			return nil, fmt.Errorf("row queue source version order differs")
		}
		if i > 0 && !pgQueueInventoryPreserves(inventory.Versions[i-1], version) {
			return nil, fmt.Errorf("row queue payload removal, move or transformation is unsupported")
		}
		value, err := pgRowQueueSourceBinding(history, version)
		if err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	return result, nil
}

func pgRowQueueSourceBinding(history PgCompiledMigrationHistory, version PgQueueSourceVersion) (pgRowQueueSource, error) {
	hash, err := pgQueueCandidateInventoryHash(history, version)
	if err != nil {
		return pgRowQueueSource{}, err
	}
	queues, facilities := []pgRowCanonical{}, []pgRowCanonical{}
	for _, contract := range version.Contracts {
		payloads := []pgRowCanonical{}
		for _, payload := range contract.Payloads {
			raw, err := pgRowBaselineHex(payload.Contract)
			if err != nil {
				return pgRowQueueSource{}, err
			}
			payloads = append(payloads, pgRowList(pgRowAtom(payload.Job), pgRowAtom(string(raw)), pgRowAtom(payload.ContractHash)))
		}
		queues = append(queues, pgRowList(pgRowAtom(contract.Queue), pgRowList(payloads...)))
		facilities = append(facilities, pgRowList(pgRowAtom("queue"), pgRowAtom(contract.Queue)))
	}
	binding, bindingHash := pgRowBaselineDocument(pgRowList(pgRowAtom("tesl-row-queue-source-v1"), pgRowAtom(history.Family), pgRowAtom(fmt.Sprint(version.Version)), pgRowAtom(version.SchemaSnapshotHash), pgRowAtom(version.StorageSnapshotHash), pgRowAtom(history.StoredValueCompatibility), pgRowAtom(hash)))
	return pgRowQueueSource{version: version, inventoryHash: hash, binding: binding, bindingHash: bindingHash,
		queues: pgRowList(pgRowAtom("complete-queues"), pgRowList(queues...)), facilities: pgRowList(pgRowAtom("complete-facilities"), pgRowList(facilities...))}, nil
}
