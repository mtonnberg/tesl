package teslrt

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// The complete forward observation was parsed against the immutable V1 anchor
// and checked receipts. Index jobs add no independent source or SQL authority.
func pgVerifyRowIndexJobs(forward *pgRowForwardManifest, intents map[int]*pgExpansionIntent, jobs []pgMigrationIndexJob, executorVersion int, compilerABI string) error {
	type expected struct {
		version, ordinal int
		abi              string
		index            *pgRowConcurrentIndex
	}
	inventory := map[string]expected{}
	for manifest := forward; manifest != nil; manifest = manifest.previous {
		if manifest.plan == nil {
			return fmt.Errorf("index inventory has no physical manifest")
		}
		intent := intents[manifest.plan.version]
		if intent == nil {
			continue
		}
		if intent.ArtifactHash != manifest.plan.hash || intent.SourceABI != manifest.creatorABI || len(intent.Objects) > len(manifest.operations) {
			return fmt.Errorf("row index intent differs from complete physical operation inventory")
		}
		for ordinal, receipt := range intent.Objects {
			if ordinal >= len(manifest.operations) {
				return fmt.Errorf("row index receipt exceeds physical operation inventory")
			}
			operation := manifest.operations[ordinal]
			if operation.index == nil {
				continue
			}
			object := pgMigrationObjectHash(manifest.plan.hash, ordinal)
			if receipt != object {
				return fmt.Errorf("row index lacks its exact committed object receipt")
			}
			if _, duplicate := inventory[object]; duplicate {
				return fmt.Errorf("duplicate row index operation")
			}
			inventory[object] = expected{manifest.plan.version, ordinal, manifest.creatorABI, operation.index}
		}
	}
	names := map[string]bool{}
	for _, job := range jobs {
		if err := pgIndexJobCatalogShape(job); err != nil {
			return err
		}
		want, exists := inventory[job.ID]
		if !exists || job.ObjectHash != job.ID || job.Version != want.version || job.Ordinal != want.ordinal || job.SourceABI != want.abi ||
			want.index == nil || job.Table != want.index.table || job.Index.Name != want.index.index.Name || !pgPhysicalIndexEqual(job.Index, want.index.index) || names[job.Index.Name] {
			return fmt.Errorf("row index job differs from its exact committed source operation")
		}
		if job.State == "terminal" {
			return fmt.Errorf("row index removal requires its checked Contract lifecycle")
		}
		if job.Index.Unique {
			return fmt.Errorf("unique row index enforcement is not admitted")
		}
		if executorVersion >= job.Version && job.State != "valid" && job.SourceABI != compilerABI {
			return fmt.Errorf("unfinished row index compiler ABI differs at V%d", job.Version)
		}
		names[job.Index.Name] = true
		delete(inventory, job.ID)
	}
	if len(inventory) != 0 {
		return fmt.Errorf("committed row index operation has no protected job")
	}
	return nil
}

func pgReadRowIndexJobs(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, forward *pgRowForwardManifest, intents map[int]*pgExpansionIntent, executor bool) ([]pgMigrationIndexJob, error) {
	jobs, err := pgReadMigrationIndexJobRows(ctx, tx, b.history.Namespace, intents)
	if err != nil {
		return nil, err
	}
	version := 0
	if executor {
		version = b.history.CurrentVersion
	}
	if err := pgVerifyRowIndexJobs(forward, intents, jobs, version, b.history.SourceCompilerABI); err != nil {
		return nil, err
	}
	if err := pgVerifyStageRecords(ctx, tx, b, forward, jobs); err != nil {
		return nil, err
	}
	for i := range jobs {
		for manifest := forward; manifest != nil; manifest = manifest.previous {
			for _, stage := range manifest.plan.stages {
				if stage.scalar == "text" && stage.table == jobs[i].Table && stage.index == jobs[i].Index.Name {
					jobs[i].verifiedTextPreparation = true
				}
			}
		}
	}
	// pgVerifyRowWorkState accounts for every index lease plus every strictly
	// verified row shard. Neither prefix is an exemption for orphan lease rows.
	return jobs, nil
}

// Row catalog reconstruction contains the complete committed future prefix.
// Separately check future indexes against this binary's own retained write
// columns before masking their exact build state from that full comparison.
func pgPrepareRowIndexCatalog(metadata *pgCatalogExpectations, actual, expected *pgCatalogTable, local *pgRowPhysicalPlan, jobs []pgMigrationIndexJob, report *PgMigrationCatalogReport) (*pgCatalogTable, *pgCatalogTable, bool, error) {
	if local == nil || actual == nil || expected == nil {
		return nil, nil, false, fmt.Errorf("row index catalog lacks its local physical owner")
	}
	own := &pgCatalogTable{}
	for _, entity := range local.entities {
		if entity.table == actual.Name {
			for _, column := range entity.columns {
				own.Columns = append(own.Columns, pgCatalogColumn{Name: column.catalog.Name})
			}
		}
	}
	latest := local.version
	for _, job := range jobs {
		latest = max(latest, job.Version)
		if job.Index.Unique {
			return nil, nil, false, fmt.Errorf("unique row index enforcement is not admitted")
		}
		if job.Table == actual.Name && job.Version > local.version && !job.verifiedTextPreparation && !pgFutureIndexSafeForWrites(actual, own, job.Index) {
			return nil, nil, false, fmt.Errorf("future row index changes this binary's admitted writes")
		}
	}
	// Future index safety was checked against own above. For finite shape and
	// state, every verified job is declared in the reconstructed full prefix.
	return pgPrepareIndexJobCatalogForAdmission(metadata, actual, expected, jobs, latest, local.version, report)
}
