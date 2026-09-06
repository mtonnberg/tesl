package teslrt

import (
	"fmt"
	"slices"
)

// pgVerifyMigrationIndexJobs connects the protected, structured job rows to the
// checked source operations this binary knows. Unknown future jobs are still
// checked against their immutable intent and later against the actual catalog.
// Completed expansion does not remove an unfinished job's exact executor ABI pin.
func pgVerifyMigrationIndexJobs(plan PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent,
	jobs []pgMigrationIndexJob, executor bool) error {
	byObject := make(map[string]pgMigrationIndexJob)
	names := make(map[string]bool)
	for _, job := range jobs {
		if err := pgIndexJobCatalogShape(job); err != nil {
			return err
		}
		intent := intents[job.Version]
		if intent == nil || job.Ordinal >= len(intent.Objects) || job.ID != job.ObjectHash ||
			job.ObjectHash != pgMigrationObjectHash(intent.ArtifactHash, job.Ordinal) || job.SourceABI != intent.SourceABI {
			return fmt.Errorf("index job lacks matching committed expansion provenance")
		}
		if _, duplicate := byObject[job.ObjectHash]; duplicate || names[job.Index.Name] {
			return fmt.Errorf("duplicate protected index job identity")
		}
		byObject[job.ObjectHash], names[job.Index.Name] = job, true
		if job.State == "terminal" {
			return fmt.Errorf("terminal index job requires the contract executor")
		}
		if job.Version > plan.CurrentVersion {
			continue
		}
		if job.Version < plan.InitialVersion || job.Version-plan.InitialVersion >= len(plan.Steps) {
			return fmt.Errorf("index job predates the recorded installation origin")
		}
		step := plan.Steps[job.Version-plan.InitialVersion]
		if job.Ordinal >= len(step.Operations) {
			return fmt.Errorf("index job is outside its checked migration operations")
		}
		op := step.Operations[job.Ordinal]
		if !step.EpochPreserving || op.WindowRisk != nil || op.Kind != "build-index-concurrently" ||
			op.Table != job.Table || op.Index == nil || op.Index.Name != job.Index.Name ||
			op.Index.Unique != job.Index.Unique || !slices.Equal(op.Index.Columns, job.Index.Columns) {
			return fmt.Errorf("index job differs from its checked additive migration operation")
		}
		if executor && job.State != "valid" && job.SourceABI != plan.SourceCompilerABI {
			return fmt.Errorf("unfinished index job compiler ABI differs at V%d", job.Version)
		}
	}
	for _, step := range plan.Steps {
		intent := intents[step.Version]
		if intent == nil {
			continue
		}
		if len(intent.Objects) > len(step.Operations) {
			return fmt.Errorf("index job progress exceeds checked migration operations")
		}
		for ordinal, op := range step.Operations[:len(intent.Objects)] {
			if op.Kind != "build-index-concurrently" {
				continue
			}
			if _, found := byObject[intent.Objects[ordinal]]; !found {
				return fmt.Errorf("committed index operation V%d object %d has no protected job", step.Version, ordinal)
			}
		}
	}
	return nil
}
