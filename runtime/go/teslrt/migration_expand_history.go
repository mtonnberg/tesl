package teslrt

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgExpansionIntent struct {
	Version                               int
	SnapshotHash, ArtifactHash, SourceABI string
	OperationCount                        int
	EpochPreserving                       bool
	Objects                               []string
}

func pgReadExpansionIntents(ctx context.Context, tx pgx.Tx, namespace string) (map[int]*pgExpansionIntent, error) {
	ns := quoteIdentifier(namespace) + "."
	rows, err := tx.Query(ctx, "select version,snapshot_hash,artefact_hash,source_abi,operation_count,epoch_preserving from "+ns+"tesl_schema_expansions order by version")
	if err != nil {
		return nil, err
	}
	intents := map[int]*pgExpansionIntent{}
	for rows.Next() {
		r := &pgExpansionIntent{}
		if err := rows.Scan(&r.Version, &r.SnapshotHash, &r.ArtifactHash, &r.SourceABI, &r.OperationCount, &r.EpochPreserving); err != nil {
			rows.Close()
			return nil, err
		}
		intents[r.Version] = r
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows, err = tx.Query(ctx, "select version,ordinal,operation_hash from "+ns+"tesl_schema_expansion_objects order by version,ordinal")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var v, ordinal int
		var hash string
		if err := rows.Scan(&v, &ordinal, &hash); err != nil {
			return nil, err
		}
		r := intents[v]
		if r == nil || ordinal != len(r.Objects) || ordinal >= r.OperationCount {
			return nil, fmt.Errorf("migration object progress is not a prefix of its intent at V%d", v)
		}
		// Check identities even beyond this binary's known source history.
		if hash != pgMigrationObjectHash(r.ArtifactHash, ordinal) {
			return nil, fmt.Errorf("migration object identity differs from its intent at V%d object %d", v, ordinal)
		}
		r.Objects = append(r.Objects, hash)
	}
	return intents, rows.Err()
}

// This verifier does not trust the current pointer alone. Every installed step
// needs an immutable intent, complete object progress and exactly its lifecycle
// rows. The source portion known to this binary must agree byte for byte.
func pgVerifyExpansionHistory(state PgMigrationControlState, plan PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent) error {
	last := state.Current
	if last == 0 {
		last = state.InitialVersion - 1
	}
	if !state.Present || state.InitialVersion != plan.InitialVersion || plan.CurrentVersion < state.InitialVersion {
		return fmt.Errorf("migration plan does not match the recorded installation origin")
	}
	for v, r := range intents {
		if v < state.InitialVersion || v > last+1 || r.Version != v || r.OperationCount < 0 || !r.EpochPreserving ||
			!pgMigrationDigest(r.SnapshotHash) || !pgMigrationDigest(r.ArtifactHash) ||
			!strings.HasPrefix(r.SourceABI, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(r.SourceABI, "tesl-source-abi-v1:")) {
			return fmt.Errorf("invalid or out-of-order expansion intent at V%d", v)
		}
		if v <= plan.CurrentVersion {
			step := plan.Steps[v-plan.InitialVersion]
			if r.SnapshotHash != step.SnapshotHash || r.ArtifactHash != step.StepHash || r.SourceABI != plan.SourceCompilerABI ||
				r.OperationCount != len(step.Operations) || r.EpochPreserving != step.EpochPreserving {
				return fmt.Errorf("persisted migration source, ABI or plan differs at V%d", v)
			}
		}
		if v <= last && len(r.Objects) != r.OperationCount {
			return fmt.Errorf("installed V%d has incomplete object progress", v)
		}
	}
	seen := map[int]map[string]bool{}
	for _, row := range state.Versions {
		r := intents[row.Version]
		if r == nil || row.Version > last || row.Sequence != 0 || row.Protocol != 1 || row.FenceDomain != "tesl-1" ||
			row.ArtifactHash != r.ArtifactHash || row.SourceABI != r.SourceABI {
			return fmt.Errorf("migration lifecycle row lacks matching expansion provenance at V%d", row.Version)
		}
		if seen[row.Version] == nil {
			seen[row.Version] = map[string]bool{}
		}
		if seen[row.Version][row.Step] {
			return fmt.Errorf("duplicate migration lifecycle row")
		}
		seen[row.Version][row.Step] = true
		if row.Step == "expanded" {
			if row.SnapshotHash != r.SnapshotHash || row.EpochPreserving == nil || !*row.EpochPreserving {
				return fmt.Errorf("migration expansion classification differs at V%d", row.Version)
			}
		} else if row.Version != state.InitialVersion || (row.Step != "contracting" && row.Step != "contracted") || row.SnapshotHash != "" || row.EpochPreserving != nil {
			return fmt.Errorf("unsupported migration lifecycle transition at V%d", row.Version)
		}
	}
	for v := state.InitialVersion; v <= last; v++ {
		if intents[v] == nil || !seen[v]["expanded"] || (v == state.InitialVersion && (!seen[v]["contracting"] || !seen[v]["contracted"])) {
			return fmt.Errorf("migration history is incomplete at V%d", v)
		}
	}
	return nil
}

func pgExpansionRecordedCatalog(plan PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent) ([]PgMigrationCatalogTable, error) {
	tables := map[string]PgMigrationCatalogTable{}
	for _, step := range plan.Steps {
		r := intents[step.Version]
		if r == nil {
			break
		}
		for _, op := range step.Operations[:len(r.Objects)] {
			if err := pgReplayMigrationOperation(tables, op); err != nil {
				return nil, err
			}
		}
		if len(r.Objects) != len(step.Operations) {
			break
		}
	}
	return pgMigrationCatalogCopy(tables), nil
}
