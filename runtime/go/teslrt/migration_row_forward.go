package teslrt

import (
	"context"
	"encoding/hex"
	"fmt"
	"reflect"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgRowForwardOperation struct {
	entity *pgRowPhysicalEntity
	column *pgRowPhysicalColumn
	window *pgRowPhysicalWindow
	table  *PgMigrationCatalogTable
}

type pgRowForwardManifest struct {
	previous                  *pgRowForwardManifest
	predecessor               *pgRowPhysicalPlan
	contraction               *pgRowPersistedContract
	epoch                     *pgRowEpochRetirement
	completed                 int
	plan                      *pgRowPhysicalPlan
	creatorABI, compatibility string
	processingABI             string
	operations                []pgRowForwardOperation
}

func pgRowForwardOperations(previous, plan *pgRowPhysicalPlan) ([]pgRowForwardOperation, error) {
	if previous == nil || plan == nil || plan.version != previous.version+1 {
		return nil, fmt.Errorf("row execution requires an adjacent checked physical revision")
	}
	if err := pgValidateRowPhysicalLineage(previous, plan); err != nil {
		return nil, err
	}
	operations := []pgRowForwardOperation{}
	for i := range plan.entities {
		entity := &plan.entities[i]
		old := previous.entity(entity.identity)
		if old == nil {
			table := PgMigrationCatalogTable{Name: entity.table, Indexes: slices.Clone(entity.indexes)}
			for _, column := range entity.columns {
				table.Columns = append(table.Columns, column.catalog)
			}
			if err := pgValidateMigrationCatalog([]PgMigrationCatalogTable{table}); err != nil {
				return nil, err
			}
			table.Columns = append(table.Columns, PgMigrationCatalogColumn{Name: "_tesl_v", Type: "int2", Default: &PgMigrationCatalogConstant{Kind: "int", Value: "1"}})
			operations = append(operations, pgRowForwardOperation{entity: entity, table: &table})
			continue
		}
		if !reflect.DeepEqual(old.indexes, entity.indexes) {
			return nil, fmt.Errorf("row expansion requires a concurrent job for existing-table index changes")
		}
		for j := range entity.columns {
			column := &entity.columns[j]
			if old.column(column.catalog.Name) != nil {
				continue
			}
			if column.catalog.PrimaryKey || column.introducedVersion != plan.version || plan.window(entity.identity) != nil && !column.catalog.Nullable {
				return nil, fmt.Errorf("bounded row expansion requires exact checked column introduction")
			}
			operations = append(operations, pgRowForwardOperation{entity: entity, column: column})
		}
	}
	for i := range plan.windows {
		window := &plan.windows[i]
		currentEntity, previousEntity := plan.entity(window.entity), previous.entity(window.entity)
		if currentEntity == nil || previousEntity == nil || window.previousGeneration != previousEntity.generation || window.targetGeneration != window.previousGeneration+1 || window.requiresFinalGeneration != window.previousGeneration {
			return nil, fmt.Errorf("row expansion requires exact adjacent final predecessor generation")
		}
		operations = append(operations, pgRowForwardOperation{entity: currentEntity, window: window})
	}
	return operations, nil
}

// Durable parsing grants catalog observation only. The locally linked target
// plan is separately required by registration and execution below.
func pgReadRowForwardManifest(ctx context.Context, tx pgx.Tx, b *pgRowBaseline) (*pgRowForwardManifest, error) {
	contracts, err := pgReadRowContracts(ctx, tx, b)
	if err != nil {
		return nil, err
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	rows, err := tx.Query(ctx, "select version,predecessor_hash,contract,contract_hash,compiler_abi,stored_value_compatibility,operation_count,epoch_preserving from "+ns+"tesl_row_physical order by version")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result *pgRowForwardManifest
	var previous *pgRowPhysicalPlan
	manifests := map[int]*pgRowForwardManifest{}
	count := 0
	for rows.Next() {
		var version, operations int
		var preserving bool
		var prior, hash, abi, compatibility string
		var contract []byte
		if err := rows.Scan(&version, &prior, &contract, &hash, &abi, &compatibility, &operations, &preserving); err != nil {
			return nil, err
		}
		count++
		if b.physical == nil || version != count || !strings.HasPrefix(abi, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(abi, "tesl-source-abi-v1:")) || compatibility != b.history.StoredValueCompatibility {
			return nil, fmt.Errorf("unbound or unsupported persisted physical manifest")
		}
		plan, err := pgParseRowPhysicalPlan(hex.EncodeToString(contract), hash)
		if err != nil {
			return nil, err
		}
		if preserving != (len(plan.windows) == 0) {
			return nil, fmt.Errorf("physical epoch mode differs from checked window inventory")
		}
		if plan.version != version || plan.family != b.history.Family || plan.namespace != b.history.Namespace {
			return nil, fmt.Errorf("persisted physical owner differs")
		}
		if version == 1 {
			if prior != "" || operations != 0 || plan.hash != b.physical.hash || plan.contract != b.physical.contract {
				return nil, fmt.Errorf("immutable physical V1 anchor differs from compiled source")
			}
			if err := pgValidateRowPhysicalLineage(nil, plan); err != nil {
				return nil, err
			}
		} else {
			predecessor := previous
			if plan.requiresContractVersion > 0 {
				// This first repeated-transform path requires a completely contracted
				// immediate predecessor. Additive-tail composition remains an explicit
				// unsupported extension, never inferred from a numeric floor alone.
				required := manifests[plan.requiresContractVersion]
				if plan.requiresContractVersion != version-1 || required == nil || required.contraction == nil || required.contraction.contract == nil || required.contraction.completed != required.contraction.operationCount {
					return nil, fmt.Errorf("physical predecessor lacks complete checked contraction")
				}
				predecessor = required.contraction.settled
			}
			if predecessor == nil || prior != predecessor.hash {
				return nil, fmt.Errorf("physical manifest predecessor differs")
			}
			ops, err := pgRowForwardOperations(predecessor, plan)
			if err != nil {
				return nil, err
			}
			if len(ops) != operations {
				return nil, fmt.Errorf("physical manifest operation inventory differs")
			}
			if b.target != nil && b.target.version == version && (b.target.hash != plan.hash || b.target.contract != plan.contract) {
				return nil, fmt.Errorf("persisted target physical plan differs from compiled application")
			}
			next := &pgRowForwardManifest{previous: result, predecessor: predecessor, plan: plan, creatorABI: abi, compatibility: compatibility, operations: ops}
			if raw := contracts[version]; raw != nil {
				checked, err := pgParseRowContract(raw.document, raw.hash, plan, raw.settled)
				if err != nil {
					return nil, err
				}
				if raw.windowHash != plan.hash || raw.operationCount != len(checked.operations) || raw.preparationCount != checked.preparationCount {
					return nil, fmt.Errorf("persisted Contract operation count or window differs")
				}
				raw.contract = checked
				next.contraction = raw
			}
			manifests[version] = next
			result = next
		}
		previous = plan
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	if b.physical != nil && count == 0 {
		return nil, fmt.Errorf("missing original physical V1 anchor")
	}
	for version, item := range contracts {
		if manifests[version] == nil || item.contract == nil {
			return nil, fmt.Errorf("orphan persisted Contract")
		}
	}
	processing, err := tx.Query(ctx, "select version,compiler_abi from "+ns+"tesl_row_processing order by version")
	if err != nil {
		return nil, err
	}
	defer processing.Close()
	for processing.Next() {
		var version int
		var abi string
		if err := processing.Scan(&version, &abi); err != nil {
			return nil, err
		}
		manifest := manifests[version]
		if manifest == nil || len(manifest.plan.windows) == 0 || manifest.processingABI != "" || !strings.HasPrefix(abi, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(abi, "tesl-source-abi-v1:")) {
			return nil, fmt.Errorf("invalid processing ABI state")
		}
		manifest.processingABI = abi
	}
	if err := processing.Err(); err != nil {
		return nil, err
	}
	processing.Close()
	plans := map[int]*pgRowPhysicalPlan{1: b.physical}
	for version, manifest := range manifests {
		plans[version] = manifest.plan
	}
	epochs, err := pgReadRowEpochRetirements(ctx, tx, b, plans)
	if err != nil {
		return nil, err
	}
	for target, epoch := range epochs {
		manifest := manifests[target]
		if manifest == nil {
			return nil, fmt.Errorf("epoch retirement references an absent additive target")
		}
		manifest.epoch = epoch
	}
	return result, nil
}

func pgRowRetirementHash(contract *pgRowContract) string {
	_, hash := pgRowBaselineDocument(pgRowList(pgRowAtom("tesl-row-retirement-v1"), pgRowAtom(contract.hash), pgRowAtom(contract.window.hash), pgRowAtom(contract.settled.hash), pgRowAtom(fmt.Sprint(contract.window.version))))
	return hash
}

func pgVerifyRowExpansionHistory(state PgMigrationControlState, b *pgRowBaseline, intents map[int]*pgExpansionIntent, forward *pgRowForwardManifest, executor bool) error {
	baselineState := state
	baselineState.Current = min(state.Current, 1)
	baselineState.Versions = nil
	if state.Current > 0 {
		baselineState.MinVersion = 1
		baselineState.CompatFloor = 1
	}
	baseIntents := map[int]*pgExpansionIntent{}
	if intents[1] != nil {
		baseIntents[1] = intents[1]
	}
	for _, row := range state.Versions {
		if row.Version == 1 {
			baselineState.Versions = append(baselineState.Versions, row)
		}
	}
	if err := pgVerifyExpansionHistoryMode(baselineState, b.expansionPlan(), baseIntents, executor); err != nil {
		return err
	}
	manifests := map[int]*pgRowForwardManifest{}
	for m := forward; m != nil; m = m.previous {
		if manifests[m.plan.version] != nil {
			return fmt.Errorf("duplicate physical manifest")
		}
		manifests[m.plan.version] = m
	}
	for version := range intents {
		if version != 1 && manifests[version] == nil {
			return fmt.Errorf("orphan row expansion intent")
		}
	}
	rows := map[int]map[string]PgMigrationControlVersion{}
	for _, row := range state.Versions {
		if row.Version == 1 {
			continue
		}
		if manifests[row.Version] == nil || row.Sequence != 0 || row.Protocol != 1 || row.FenceDomain != "tesl-1" {
			return fmt.Errorf("unsupported future row lifecycle provenance")
		}
		if rows[row.Version] == nil {
			rows[row.Version] = map[string]PgMigrationControlVersion{}
		}
		if _, exists := rows[row.Version][row.Step]; exists {
			return fmt.Errorf("duplicate row lifecycle step")
		}
		rows[row.Version][row.Step] = row
	}
	expectedMin, expectedFloor := 0, 0
	if state.Current > 0 {
		expectedMin = 1
		expectedFloor = 1
	}
	for version := 2; version <= len(manifests)+1; version++ {
		m := manifests[version]
		if m == nil {
			return fmt.Errorf("physical manifest history has a gap")
		}
		intent := intents[version]
		steps := rows[version]
		if intent == nil {
			if state.Current >= version || len(steps) > 0 || m.processingABI != "" || m.contraction != nil {
				return fmt.Errorf("future row lifecycle has no expansion intent")
			}
			continue
		}
		if intent.Version != version || intent.SnapshotHash != m.plan.hash || intent.ArtifactHash != m.plan.hash || intent.SourceABI != m.creatorABI || intent.StoredValueCompatibility != m.compatibility || intent.EpochPreserving != (len(m.plan.windows) == 0) || intent.OperationCount != len(m.operations) {
			return fmt.Errorf("future row intent differs from exact manifest")
		}
		if executor && state.Current < version && b.history.CurrentVersion == version && intent.SourceABI != b.history.SourceCompilerABI {
			return fmt.Errorf("unfinished row expansion compiler ABI differs")
		}
		m.completed = len(intent.Objects)
		expanded, hasExpanded := steps["expanded"]
		if hasExpanded != (state.Current >= version) || hasExpanded && m.completed != intent.OperationCount {
			return fmt.Errorf("published row expansion is incomplete")
		}
		if hasExpanded && (expanded.ArtifactHash != intent.ArtifactHash || expanded.SnapshotHash != intent.SnapshotHash || expanded.SourceABI != intent.SourceABI || expanded.StoredValueCompatibility != intent.StoredValueCompatibility || expanded.EpochPreserving == nil || *expanded.EpochPreserving != intent.EpochPreserving) {
			return fmt.Errorf("expanded lifecycle differs from exact manifest provenance")
		}
		if m.processingABI != "" && (!hasExpanded || b.history.CurrentVersion == version && b.history.SourceCompilerABI != m.processingABI && steps["retired"].Step == "") {
			return fmt.Errorf("processing ABI differs from current transforming application")
		}
		c := m.contraction
		retired, hasRetired := steps["retired"]
		contracting, hasContracting := steps["contracting"]
		contracted, hasContracted := steps["contracted"]
		if len(steps) != boolInt(hasExpanded)+boolInt(hasRetired)+boolInt(hasContracting)+boolInt(hasContracted) {
			return fmt.Errorf("unknown row lifecycle step")
		}
		if len(m.plan.windows) == 0 {
			if c != nil || m.processingABI != "" {
				return fmt.Errorf("additive revision cannot carry row processing or a destructive Contract")
			}
			if m.epoch == nil {
				if hasRetired || hasContracting || hasContracted {
					return fmt.Errorf("additive retirement lacks exact epoch evidence")
				}
			} else {
				if !hasExpanded || !hasRetired || !hasContracting || !hasContracted {
					return fmt.Errorf("epoch retirement lacks its complete additive slot lifecycle")
				}
				for _, step := range []PgMigrationControlVersion{retired, contracting, contracted} {
					if step.ArtifactHash != m.epoch.hash || step.SnapshotHash != "" || step.SourceABI != m.epoch.executorABI || step.StoredValueCompatibility != m.compatibility || step.EpochPreserving != nil {
						return fmt.Errorf("additive retirement provenance differs from exact epoch receipt")
					}
				}
				expectedMin = max(expectedMin, m.epoch.through)
				expectedFloor = max(expectedFloor, m.epoch.through)
			}
		} else if m.epoch != nil {
			return fmt.Errorf("transforming revision cannot be an additive epoch slot")
		} else if c == nil {
			if hasRetired || hasContracting || hasContracted {
				return fmt.Errorf("row lifecycle lacks checked Contract")
			}
		} else {
			if !hasExpanded {
				return fmt.Errorf("row Contract precedes expanded window")
			}
			if c.completed > c.preparationCount && !hasContracting || c.completed > 0 && !hasRetired || hasContracting && c.completed < c.preparationCount || hasContracted && (!hasContracting || c.completed != c.operationCount) || hasContracting && !hasRetired {
				return fmt.Errorf("row Contract lifecycle/prefix order differs")
			}
			if hasRetired {
				if retired.ArtifactHash != pgRowRetirementHash(c.contract) || retired.SnapshotHash != "" || retired.EpochPreserving != nil || retired.StoredValueCompatibility != m.compatibility {
					return fmt.Errorf("retirement plan or executor provenance differs")
				}
				expectedMin = version
			}
			for _, step := range []PgMigrationControlVersion{contracting, contracted} {
				if step.Step == "" {
					continue
				}
				if step.ArtifactHash != c.hash || step.SnapshotHash != "" || step.SourceABI != retired.SourceABI || step.StoredValueCompatibility != m.compatibility || step.EpochPreserving != nil {
					return fmt.Errorf("row Contract lifecycle executor or authority differs")
				}
			}
			if hasContracting {
				expectedFloor = version
			}
		}
		if m.plan.requiresContractVersion > 0 {
			prior := manifests[m.plan.requiresContractVersion]
			if prior == nil || prior.contraction == nil || prior.plan.version != version-1 {
				return fmt.Errorf("next window lacks immediate checked contracted predecessor")
			}
			if _, ok := rows[prior.plan.version]["contracted"]; !ok {
				return fmt.Errorf("next window precedes required contraction receipt")
			}
		}
	}
	if state.MinVersion != expectedMin || state.CompatFloor != expectedFloor || state.Current > len(manifests)+1 {
		return fmt.Errorf("row admission floors differ from lifecycle receipts")
	}
	return nil
}
func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
