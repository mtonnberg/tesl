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
			physical := compiledRowPhysicalHistories[compiledRowHistories[history.Family]]
			if physical == nil || i >= len(physical.versions) || !pgQueuePhysicalTransitionMatches(inventory.Versions[i-1], version, physical.versions[i]) {
				return nil, fmt.Errorf("row queue transformation lacks its exact compiler-linked queue-only physical history")
			}
		}
		value, err := pgRowQueueSourceBinding(history, version)
		if err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	return result, nil
}

func pgQueuePhysicalTransitionMatches(before, after PgQueueSourceVersion, plan *pgRowPhysicalPlan) bool {
	if plan == nil || before.Version < 1 || after.Version != before.Version+1 || plan.version != after.Version || len(plan.windows) != 0 || len(plan.queueConversions) == 0 || plan.schemaSnapshotHash != after.SchemaSnapshotHash || plan.storageSnapshotHash != after.StorageSnapshotHash {
		return false
	}
	old, fresh := map[string]PgQueueSourcePayload{}, map[string]PgQueueSourcePayload{}
	for _, q := range before.Contracts {
		for _, p := range q.Payloads {
			old[q.Queue+"\x00"+p.Job] = p
		}
	}
	for _, q := range after.Contracts {
		for _, p := range q.Payloads {
			fresh[q.Queue+"\x00"+p.Job] = p
		}
	}
	if len(old) != len(fresh) {
		return false
	}
	changed := map[string]bool{}
	for key, p := range old {
		next, ok := fresh[key]
		if !ok {
			return false
		}
		if next != p {
			changed[key] = true
		}
	}
	if len(changed) != len(plan.queueConversions) {
		return false
	}
	for _, c := range plan.queueConversions {
		key := c.queue + "\x00" + c.job
		if !changed[key] || old[key].Contract != c.oldContract || fresh[key].Contract != c.newContract {
			return false
		}
		delete(changed, key)
	}
	return len(changed) == 0
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
