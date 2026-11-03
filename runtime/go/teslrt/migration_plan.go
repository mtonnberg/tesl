package teslrt

import (
	"bytes"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
)

// PgMigrationExpansionPlan is checked compiler input, not database authority.
// An executor must obtain InitialVersion from trusted control state and verify
// installation identity, persisted steps, admission and ownership separately.
type PgMigrationExpansionPlan struct {
	Database, Family, Namespace, SourceCompilerABI string
	StoredValueCompatibility                       string
	InitialVersion, CurrentVersion                 int
	Steps                                          []PgMigrationExpansionStep
}

type PgMigrationExpansionStep struct {
	Version                int
	SnapshotHash, StepHash string
	EpochPreserving        bool
	Operations             []PgMigrationExpansionOperation
	Catalog                []PgMigrationCatalogTable
}

// Kind determines which fields are populated. Created tables carry Columns and
// Indexes; additions carry Column (including its omission default); index work
// carries Index and an optional WindowRisk. Retention never removes storage.
type PgMigrationExpansionOperation struct {
	Kind, Table string
	Columns     []PgMigrationCatalogColumn
	Indexes     []PgMigrationCatalogIndex
	Column      *PgMigrationCatalogColumn
	Index       *PgMigrationCatalogIndex
	WindowRisk  *string
}

// ExpansionPlan validates the entire linked artifact, including other origins
// and connection owners, before selecting an origin. Returned slices and pointers
// are owned by this call; mutating them cannot change linked compiler input or a
// later call. No database connection or source file is read.
func (history PgCompiledMigrationHistory) ExpansionPlan(initialVersion int) (PgMigrationExpansionPlan, error) {
	var empty PgMigrationExpansionPlan
	if initialVersion < 1 || initialVersion > history.CurrentVersion {
		return empty, fmt.Errorf("migration installation origin is outside compiled history")
	}
	if err := pgMigrationCheckJSON(history.HistoryJSON); err != nil {
		return empty, err
	}
	r := &pgMigrationWireReader{}
	o := r.object(json.RawMessage(history.HistoryJSON), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	if pgMigrationRead[int](r, o["version"]) != 3 || pgMigrationRead[string](r, o["kind"]) != "compiled-migration-history" {
		r.fail("unsupported history format; version 3 with stored-value compatibility is required")
	}
	abi := pgMigrationRead[string](r, o["compilerAbi"])
	if !strings.HasPrefix(abi, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(abi, "tesl-source-abi-v1:")) || abi != history.SourceCompilerABI {
		r.fail("compiler ABI does not match linked metadata")
	}
	compatibility := pgMigrationRead[string](r, o["storedValueCompatibility"])
	if !pgStoredValueCompatibility(compatibility) || compatibility != history.StoredValueCompatibility {
		r.fail("stored-value compatibility does not match linked metadata")
	}
	databases := pgMigrationRead[[]json.RawMessage](r, o["databases"])
	identities, families := map[string]bool{}, map[string]bool{}
	var selected PgMigrationExpansionPlan
	var selectedErr error
	found := false
	for _, raw := range databases {
		if r.err != nil {
			break
		}
		d := r.object(raw, "database", "family", "namespace", "currentVersion", "origins")
		identity, family, namespace := pgMigrationRead[string](r, d["database"]), pgMigrationRead[string](r, d["family"]), pgMigrationRead[string](r, d["namespace"])
		current := pgMigrationRead[int](r, d["currentVersion"])
		origins := pgMigrationRead[[]json.RawMessage](r, d["origins"])
		if identity == "" || !pgMigrationFamily(family) || !pgMigrationIdentifier(namespace) ||
			identities[identity] || families[family] || current < 1 || current > 2147483646 || len(origins) != current {
			r.fail("invalid connection identity or incomplete origin history")
			break
		}
		identities[identity], families[family] = true, true
		matches := identity == history.Database
		if matches && (family != history.Family || namespace != history.Namespace || current != history.CurrentVersion) {
			r.fail("connection binding does not match linked metadata")
		}
		found = found || matches
		snapshots := map[int]string{}
		for i, rawOrigin := range origins {
			origin, steps, refusal := r.origin(rawOrigin, i+1, current)
			if r.err != nil {
				break
			}
			if refusal == nil {
				if err := pgReplayMigrationSteps(steps, snapshots); err != nil {
					r.err = fmt.Errorf("migration history %s from V%d: %w", identity, origin, err)
					break
				}
			}
			if matches && origin == initialVersion {
				selectedErr = refusal
				selected = PgMigrationExpansionPlan{Database: identity, Family: family, Namespace: namespace, SourceCompilerABI: abi,
					StoredValueCompatibility: compatibility, InitialVersion: origin, CurrentVersion: current, Steps: steps}
			}
		}
	}
	if r.err != nil {
		return empty, r.err
	}
	if !found {
		return empty, fmt.Errorf("compiled migration history does not contain its connection")
	}
	if selectedErr != nil {
		return empty, selectedErr
	}
	return selected, nil
}

func pgStoredValueCompatibility(value string) bool {
	return strings.HasPrefix(value, "tesl-stored-value-v1:") && pgMigrationDigest(strings.TrimPrefix(value, "tesl-stored-value-v1:"))
}

func (r *pgMigrationWireReader) origin(raw json.RawMessage, expected, current int) (int, []PgMigrationExpansionStep, error) {
	o := r.object(raw, "initialVersion", "steps", "errors")
	origin := pgMigrationRead[int](r, o["initialVersion"])
	if origin != expected {
		r.fail("installation origins must be consecutive from V1")
	}
	errors := pgMigrationRead[[]json.RawMessage](r, o["errors"])
	if len(errors) > 0 {
		messages := make([]string, 0, len(errors))
		for _, rawError := range errors {
			e := r.object(rawError, "code", "message")
			code, message := pgMigrationRead[string](r, e["code"]), pgMigrationRead[string](r, e["message"])
			if code == "" || message == "" {
				r.fail("empty origin refusal")
			}
			messages = append(messages, code+": "+message)
		}
		if !bytes.Equal(bytes.TrimSpace(o["steps"]), []byte("null")) || origin == 1 {
			r.fail("inconsistent origin refusal")
		}
		return origin, nil, fmt.Errorf("compiled migration history refuses installation origin V%d: %s", origin, strings.Join(messages, "; "))
	}
	steps := pgMigrationReadArray(r, o["steps"], r.step)
	if len(steps) != current-origin+1 {
		r.fail("incomplete migration steps")
	}
	for i, step := range steps {
		if step.Version != origin+i || !pgMigrationDigest(step.StepHash) || !pgMigrationDigest(step.SnapshotHash) {
			r.fail("invalid step version or identity")
		}
	}
	return origin, steps, nil
}

func pgMigrationDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func pgReplayMigrationSteps(steps []PgMigrationExpansionStep, snapshots map[int]string) error {
	tables := map[string]PgMigrationCatalogTable{}
	for i := range steps {
		step := &steps[i]
		epoch := true
		for _, op := range step.Operations {
			if i == 0 && op.Kind != "create-table" {
				return fmt.Errorf("initial installation must create its baseline")
			}
			if err := pgReplayMigrationOperation(tables, op); err != nil {
				return err
			}
			epoch = epoch && op.WindowRisk == nil
		}
		if epoch != step.EpochPreserving {
			return fmt.Errorf("epoch classification disagrees with index requirements")
		}
		step.Catalog = pgMigrationCatalogCopy(tables)
		if err := pgValidateMigrationCatalog(step.Catalog); err != nil {
			return err
		}
		if pgMigrationStepHash(*step) != step.StepHash {
			return fmt.Errorf("step V%d identity disagrees with its operations and reconstructed catalog", step.Version)
		}
		if old, ok := snapshots[step.Version]; ok && old != step.SnapshotHash {
			return fmt.Errorf("source snapshot at V%d differs across installation origins", step.Version)
		}
		snapshots[step.Version] = step.SnapshotHash
	}
	return nil
}

func pgReplayMigrationOperation(tables map[string]PgMigrationCatalogTable, op PgMigrationExpansionOperation) error {
	table, exists := tables[op.Table]
	if op.Kind == "create-table" {
		if exists {
			return fmt.Errorf("retained migration table %q cannot be replaced", op.Table)
		}
		tables[op.Table] = PgMigrationCatalogTable{Name: op.Table, Columns: slices.Clone(op.Columns), Indexes: slices.Clone(op.Indexes)}
		return nil
	}
	if !exists {
		return fmt.Errorf("migration operation references absent table %q", op.Table)
	}
	switch op.Kind {
	case "add-column":
		if op.Column == nil || op.Column.PrimaryKey || (!op.Column.Nullable && op.Column.Default == nil) {
			return fmt.Errorf("additive migration column requires a nullable or constant omission value")
		}
		table.Columns = append(table.Columns, *op.Column)
	case "build-index-concurrently":
		if op.Index == nil {
			return fmt.Errorf("missing migration index")
		}
		table.Indexes = append(table.Indexes, *op.Index)
	case "retain-index":
		if op.Index == nil || !slices.ContainsFunc(table.Indexes, func(index PgMigrationCatalogIndex) bool {
			return index.Name == op.Index.Name && index.Unique == op.Index.Unique && slices.Equal(index.Columns, op.Index.Columns)
		}) {
			return fmt.Errorf("retention references an absent or changed index")
		}
	case "retain-table":
	default:
		return fmt.Errorf("unknown migration operation")
	}
	tables[op.Table] = table
	return nil
}

func pgMigrationCatalogCopy(tables map[string]PgMigrationCatalogTable) []PgMigrationCatalogTable {
	catalog := make([]PgMigrationCatalogTable, 0, len(tables))
	for _, original := range tables {
		table := original
		table.Columns = slices.Clone(table.Columns)
		for i := range table.Columns {
			if value := table.Columns[i].Default; value != nil {
				copyValue := *value
				table.Columns[i].Default = &copyValue
			}
		}
		table.Indexes = slices.Clone(table.Indexes)
		for i := range table.Indexes {
			table.Indexes[i].Columns = slices.Clone(table.Indexes[i].Columns)
		}
		slices.SortFunc(table.Columns, func(a, b PgMigrationCatalogColumn) int { return strings.Compare(a.Name, b.Name) })
		slices.SortFunc(table.Indexes, func(a, b PgMigrationCatalogIndex) int { return strings.Compare(a.Name, b.Name) })
		catalog = append(catalog, table)
	}
	slices.SortFunc(catalog, func(a, b PgMigrationCatalogTable) int { return strings.Compare(a.Name, b.Name) })
	return catalog
}
