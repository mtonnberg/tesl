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

// pgRowQueueSourceSet is the row-owned queue source binding of every version.
// Window versions are bound from the validated window; any other version first
// validates the complete queue and physical history. Shared and immutable.
type pgRowQueueSourceSet struct {
	history  PgCompiledMigrationHistory
	lazy     *pgQueueHistoryLazy
	physical *pgCompiledRowPhysicalHistory
	window   map[int]pgRowQueueSource
	full     pgMemo[[]pgRowQueueSource]
}

// Protected by pgMigrationRegistrations.
var compiledRowQueueSources = map[string]*pgRowQueueSourceSet{}

func (q *pgRowQueueSourceSet) len() int { return q.history.CurrentVersion }

func (q *pgRowQueueSourceSet) at(k int) (pgRowQueueSource, error) {
	if source, ok := q.window[k]; ok {
		return source, nil
	}
	if k < 1 || k > q.history.CurrentVersion {
		return pgRowQueueSource{}, fmt.Errorf("row queue source version is outside linked history")
	}
	all, err := q.complete()
	if err != nil {
		return pgRowQueueSource{}, err
	}
	return all[k-1], nil
}

func (q *pgRowQueueSourceSet) must(k int) pgRowQueueSource {
	source, err := q.at(k)
	if err != nil {
		panic(err)
	}
	return source
}

// identityHash is version k's canonical inventory hash from its linked bytes,
// for comparison with a recorded version (see pgQueueHistoryLazy.identityHash).
func (q *pgRowQueueSourceSet) identityHash(k int) (string, error) {
	if source, ok := q.window[k]; ok {
		return source.inventoryHash, nil
	}
	if all, err, done := q.full.peek(); done && err == nil && k >= 1 && k <= len(all) {
		return all[k-1].inventoryHash, nil
	}
	return q.lazy.identityHash(k)
}

func (q *pgRowQueueSourceSet) complete() ([]pgRowQueueSource, error) {
	return q.full.get(func() ([]pgRowQueueSource, error) {
		pgHistoryCounters.complete.Add(1)
		history := q.history
		if _, err := pgReadRowBase(history); err != nil {
			return nil, err
		}
		inventory, err := q.lazy.complete()
		if err != nil {
			return nil, err
		}
		versions := inventory.Versions
		// The complete reader replays the complete row source, including queue
		// roots and payload closure containment. Never manufacture an empty
		// companion here.
		if inventory.Database != history.Database || inventory.Family != history.Family || inventory.Namespace != history.Namespace || inventory.InitialVersion != 1 || inventory.CurrentVersion != history.CurrentVersion || len(versions) != history.CurrentVersion {
			return nil, fmt.Errorf("row queue inventory owner or complete version range differs")
		}
		var plans []*pgRowPhysicalPlan
		if q.physical != nil {
			if plans, err = q.physical.all(); err != nil {
				return nil, err
			}
			if err := pgCheckQueueRemovalHistory(plans, versions); err != nil {
				return nil, err
			}
		}
		result := make([]pgRowQueueSource, 0, len(versions))
		for i, version := range versions {
			if version.Version != i+1 {
				return nil, fmt.Errorf("row queue source version order differs")
			}
			if i > 0 && !pgQueueInventoryPreserves(versions[i-1], version) {
				if plans == nil || i >= len(plans) || !pgQueuePhysicalTransitionMatches(versions[i-1], version, plans[i]) {
					return nil, fmt.Errorf("row queue transformation lacks its exact compiler-linked queue-only physical history")
				}
			}
			if source, ok := q.window[i+1]; ok {
				result = append(result, source)
				continue
			}
			value, err := pgRowQueueSourceBinding(history, version)
			if err != nil {
				return nil, err
			}
			result = append(result, value)
		}
		return result, nil
	})
}

// pgRowQueueSources binds the complete compiler-owned source inventory. It
// does not grant queue dispatch, establish a legacy origin, or identify row
// expansion receipts as source storage hashes. Callers hold
// pgMigrationRegistrations.
func pgRowQueueSources(history PgCompiledMigrationHistory) (*pgRowQueueSourceSet, error) {
	registration, err := pgQueueRegistrationOf(history)
	if err != nil {
		return nil, err
	}
	var physical *pgCompiledRowPhysicalHistory
	if compiled := compiledRowHistories[history.Family]; compiled != nil {
		physical = compiledRowPhysicalHistories[compiled]
	}
	if existing := compiledRowQueueSources[history.Family]; existing != nil && existing.history == history && existing.lazy == registration.lazy && existing.physical == physical {
		return existing, nil
	}
	set := &pgRowQueueSourceSet{history: history, lazy: registration.lazy, physical: physical, window: map[int]pgRowQueueSource{}}
	if registration.lazy.window == nil || pgHistoryInWindow(history.CurrentVersion) || physical == nil && history.CurrentVersion > 1 {
		all, err := set.complete()
		if err != nil {
			return nil, err
		}
		for i, source := range all {
			set.window[i+1] = source
		}
	} else {
		current := history.CurrentVersion
		for k := 1; k <= current; k++ {
			if !pgServingWindow(current, k) {
				continue
			}
			version, err := registration.lazy.version(k)
			if err != nil {
				return nil, err
			}
			if version.Version != k {
				return nil, fmt.Errorf("row queue source version order differs")
			}
			value, err := pgRowQueueSourceBinding(history, version)
			if err != nil {
				return nil, err
			}
			set.window[k] = value
		}
		// The current transition is checked here; earlier ones by complete
		// validation, together with the RemoveEmpty history.
		before, after := set.window[current-1].version, set.window[current].version
		if !pgQueueInventoryPreserves(before, after) {
			plan, err := physical.plan(current)
			if err != nil {
				return nil, err
			}
			if !pgQueuePhysicalTransitionMatches(before, after, plan) {
				return nil, fmt.Errorf("row queue transformation lacks its exact compiler-linked queue-only physical history")
			}
		}
	}
	compiledRowQueueSources[history.Family] = set
	return set, nil
}

func pgQueuePhysicalTransitionMatches(before, after PgQueueSourceVersion, plan *pgRowPhysicalPlan) bool {
	if plan != nil && plan.queueRemoval != nil {
		return pgQueueRemovalMatches(before, after, plan)
	}
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
