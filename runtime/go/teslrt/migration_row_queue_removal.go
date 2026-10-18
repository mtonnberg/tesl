package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"slices"
)

// Removal is a whole-inventory source decision, never a payload converter.
// Its closed inventories retain the full historical proof/codec contracts.
type pgRowPhysicalQueueRemoval struct {
	queue, fromSchema, fromStorage string
	before, after                  []PgQueueSourceContract
}

func pgParseQueueRemoval(n pgRowCanonical) (*pgRowPhysicalQueueRemoval, error) {
	if !n.list(6) || !n.children[0].isAtom("remove-empty-v1") {
		return nil, fmt.Errorf("invalid whole-queue removal decision")
	}
	r := &pgRowPhysicalQueueRemoval{queue: n.children[1].value, fromSchema: n.children[2].value, fromStorage: n.children[3].value}
	if !n.children[1].atom || !pgQueueIdentity(r.queue) || !n.children[2].atom || !pgMigrationDigest(r.fromSchema) || !n.children[3].atom || !pgMigrationDigest(r.fromStorage) {
		return nil, fmt.Errorf("invalid queue removal source identity")
	}
	parse := func(n pgRowCanonical) ([]PgQueueSourceContract, error) {
		if n.atom {
			return nil, fmt.Errorf("queue removal requires a complete inventory")
		}
		result := []PgQueueSourceContract{}
		last := ""
		jobs := map[string]bool{}
		for _, q := range n.children {
			if !q.list(2) || !q.children[0].atom || !pgQueueIdentity(q.children[0].value) || q.children[0].value <= last || q.children[1].atom || len(q.children[1].children) == 0 {
				return nil, fmt.Errorf("invalid queue removal inventory membership")
			}
			last = q.children[0].value
			contract := PgQueueSourceContract{Queue: last}
			job := ""
			for _, p := range q.children[1].children {
				if !p.list(2) || !p.children[0].atom || !p.children[1].atom || !pgQueueIdentity(p.children[0].value) || p.children[0].value <= job || jobs[p.children[0].value] {
					return nil, fmt.Errorf("invalid queue removal payload membership")
				}
				job = p.children[0].value
				jobs[job] = true
				raw, err := hex.DecodeString(p.children[1].value)
				if err != nil || hex.EncodeToString(raw) != p.children[1].value || pgQueueCanonicalContract(raw) != nil {
					return nil, fmt.Errorf("invalid queue removal payload contract")
				}
				contract.Payloads = append(contract.Payloads, PgQueueSourcePayload{Job: job, Contract: p.children[1].value, ContractHash: fmt.Sprintf("%x", sha256.Sum256(raw))})
			}
			result = append(result, contract)
		}
		return result, nil
	}
	var err error
	if r.before, err = parse(n.children[4]); err != nil {
		return nil, err
	}
	if r.after, err = parse(n.children[5]); err != nil {
		return nil, err
	}
	survivors := slices.DeleteFunc(slices.Clone(r.before), func(q PgQueueSourceContract) bool { return q.Queue == r.queue })
	if len(survivors)+1 != len(r.before) || !pgQueueRemovalInventoryEqual(survivors, r.after) {
		return nil, fmt.Errorf("RemoveEmpty must remove exactly its named queue and preserve every surviving full contract")
	}
	return r, nil
}

func pgQueueRemovalInventoryEqual(a, b []PgQueueSourceContract) bool {
	return slices.EqualFunc(a, b, func(a, b PgQueueSourceContract) bool {
		return a.Queue == b.Queue && slices.Equal(a.Payloads, b.Payloads)
	})
}

func pgQueueRemovalMatches(before, after PgQueueSourceVersion, plan *pgRowPhysicalPlan) bool {
	r := plan.queueRemoval
	return r != nil && before.Version >= 1 && after.Version == before.Version+1 && plan.version == after.Version &&
		len(plan.windows) == 0 && len(plan.retirements) == 0 && len(plan.queueConversions) == 0 && len(plan.stages) == 0 && plan.requiresContractVersion == 0 &&
		before.SchemaSnapshotHash == r.fromSchema && before.StorageSnapshotHash == r.fromStorage &&
		after.SchemaSnapshotHash == plan.schemaSnapshotHash && after.StorageSnapshotHash == plan.storageSnapshotHash &&
		pgQueueRemovalInventoryEqual(before.Contracts, r.before) && pgQueueRemovalInventoryEqual(after.Contracts, r.after)
}

func pgRowQueueEdge(plan *pgRowPhysicalPlan) bool {
	return plan != nil && (len(plan.queueConversions) > 0 || plan.queueRemoval != nil)
}

// Validate the complete real history, not a relabelled historical window. The
// ordinary queue history reader already checked every closed source inventory.
func pgCheckQueueRemovalHistory(plans []*pgRowPhysicalPlan, versions []PgQueueSourceVersion) error {
	removal := 0
	for _, plan := range plans {
		if plan.queueRemoval != nil {
			if removal != 0 {
				return fmt.Errorf("RemoveEmpty currently permits one removal edge per history")
			}
			removal = plan.version
		}
	}
	if removal == 0 {
		return nil
	}
	if len(plans) != len(versions) {
		return fmt.Errorf("RemoveEmpty requires complete physical and source history")
	}
	if removal < 2 || removal > len(plans) {
		return fmt.Errorf("RemoveEmpty target is outside its complete physical history")
	}
	removed := plans[removal-1].queueRemoval
	removedJobs := map[string]bool{}
	for _, queue := range removed.before {
		if queue.Queue == removed.queue {
			for _, payload := range queue.Payloads {
				removedJobs[payload.Job] = true
			}
		}
	}
	for i, plan := range plans {
		if plan.version != i+1 || len(plan.stages) != 0 || (plan.version != removal && !pgRowEpochPreserving(plan)) {
			return fmt.Errorf("RemoveEmpty requires an additive-only prefix and suffix; unsupported physical V%d", plan.version)
		}
		if i > 0 && plan.version != removal && !pgQueueInventoryPreserves(versions[i-1], versions[i]) {
			return fmt.Errorf("RemoveEmpty requires additive membership and unchanged existing full queue contracts outside its removal edge; V%d changes them", plan.version)
		}
		if plan.version > removal {
			for _, queue := range versions[i].Contracts {
				if queue.Queue == removed.queue {
					return fmt.Errorf("RemoveEmpty cannot reintroduce removed queue in V%d", plan.version)
				}
				for _, payload := range queue.Payloads {
					if removedJobs[payload.Job] {
						return fmt.Errorf("RemoveEmpty cannot reintroduce removed job identity in V%d", plan.version)
					}
				}
			}
		}
	}
	return nil
}
