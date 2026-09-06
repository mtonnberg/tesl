package teslrt

import (
	"strings"
	"testing"
)

func pgIndexHistoryTestInputs() (PgMigrationExpansionPlan, map[int]*pgExpansionIntent, pgMigrationIndexJob) {
	steps := pgPlanTestSteps()[:2]
	plan := PgMigrationExpansionPlan{InitialVersion: 1, CurrentVersion: 2, SourceCompilerABI: pgTestSourceABI, Steps: steps}
	intents := make(map[int]*pgExpansionIntent)
	for _, step := range steps {
		intent := &pgExpansionIntent{Version: step.Version, ArtifactHash: step.StepHash, SourceABI: plan.SourceCompilerABI, OperationCount: len(step.Operations)}
		for ordinal := range step.Operations {
			intent.Objects = append(intent.Objects, pgMigrationObjectHash(step.StepHash, ordinal))
		}
		intents[step.Version] = intent
	}
	n := len(steps[1].Operations) - 1
	op := steps[1].Operations[n]
	id := intents[2].Objects[n]
	job := pgMigrationIndexJob{Version: 2, Ordinal: n, ID: id, ObjectHash: id, SourceABI: plan.SourceCompilerABI,
		Table: op.Table, Index: *op.Index, State: "pending"}
	return plan, intents, job
}

func TestPgMigrationIndexHistoryBindsExactOperation(t *testing.T) {
	for name, mutate := range map[string]func(*PgMigrationExpansionPlan, map[int]*pgExpansionIntent, *pgMigrationIndexJob){
		"changed-id": func(_ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			j.ID = strings.Repeat("b", 64)
		},
		"changed-hash": func(_ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			j.ObjectHash = strings.Repeat("b", 64)
		},
		"changed-creator": func(_ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			j.SourceABI = "other"
		},
		"changed-table": func(_ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			j.Table = "other"
		},
		"changed-name": func(_ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			j.Index.Name = "other"
		},
		"changed-key": func(_ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			j.Index.Columns = []string{"active"}
		},
		"changed-uniqueness": func(_ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			j.Index.Unique = !j.Index.Unique
		},
		"negative-ordinal": func(_ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			j.Ordinal = -1
		},
		"unknown-state": func(_ *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			j.State = "finished-maybe"
		},
		"missing-intent": func(_ *PgMigrationExpansionPlan, i map[int]*pgExpansionIntent, _ *pgMigrationIndexJob) { delete(i, 2) },
		"before-object-commit": func(_ *PgMigrationExpansionPlan, i map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			i[2].Objects = i[2].Objects[:j.Ordinal]
		},
		"non-additive": func(p *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, _ *pgMigrationIndexJob) {
			p.Steps[1].EpochPreserving = false
		},
		"window-risk": func(p *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			p.Steps[1].Operations[j.Ordinal].WindowRisk = new("unsafe old keys")
		},
		"missing-compiled-index": func(p *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			p.Steps[1].Operations[j.Ordinal].Index = nil
		},
		"wrong-operation-kind": func(p *PgMigrationExpansionPlan, _ map[int]*pgExpansionIntent, j *pgMigrationIndexJob) {
			p.Steps[1].Operations[j.Ordinal].Kind = "retain-index"
		},
	} {
		t.Run(name, func(t *testing.T) {
			plan, intents, job := pgIndexHistoryTestInputs()
			if err := pgVerifyMigrationIndexJobs(plan, intents, []pgMigrationIndexJob{job}, true); err != nil {
				t.Fatalf("valid baseline: %v", err)
			}
			mutate(&plan, intents, &job)
			if err := pgVerifyMigrationIndexJobs(plan, intents, []pgMigrationIndexJob{job}, false); err == nil {
				t.Fatal("mutated protected descriptor accepted")
			}
		})
	}
}

func TestPgMigrationIndexHistoryRequiresEveryCommittedJob(t *testing.T) {
	plan, intents, job := pgIndexHistoryTestInputs()
	if err := pgVerifyMigrationIndexJobs(plan, intents, nil, false); err == nil {
		t.Fatal("recorded index operation without a protected job accepted")
	}
	if err := pgVerifyMigrationIndexJobs(plan, intents, []pgMigrationIndexJob{job, job}, false); err == nil {
		t.Fatal("duplicate job accepted")
	}
	// Uncommitted index work is not yet required to have a job.
	intents[2].Objects = intents[2].Objects[:job.Ordinal]
	if err := pgVerifyMigrationIndexJobs(plan, intents, nil, false); err != nil {
		t.Fatalf("future uncommitted operation unexpectedly needs a job: %v", err)
	}
}

func TestPgMigrationIndexHistoryPinsExecutorAfterExpansionCompletes(t *testing.T) {
	for _, state := range []string{"pending", "building", "failed", "valid"} {
		t.Run(state, func(t *testing.T) {
			plan, intents, job := pgIndexHistoryTestInputs()
			plan.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
			job.State = state
			if err := pgVerifyMigrationIndexJobs(plan, intents, []pgMigrationIndexJob{job}, false); err != nil {
				t.Fatalf("compatible observer took over execution: %v", err)
			}
			err := pgVerifyMigrationIndexJobs(plan, intents, []pgMigrationIndexJob{job}, true)
			if state == "valid" && err != nil || state != "valid" && (err == nil || !strings.Contains(err.Error(), "compiler ABI differs")) {
				t.Fatalf("completed expansion lost unfinished job ABI pin: %v", err)
			}
			// A genuinely older worker does not execute a future version's job.
			plan.CurrentVersion, plan.Steps = 1, plan.Steps[:1]
			if err := pgVerifyMigrationIndexJobs(plan, intents, []pgMigrationIndexJob{job}, true); err != nil {
				t.Fatalf("future job prevented old worker observation: %v", err)
			}
		})
	}
}
