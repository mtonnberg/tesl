package teslrt

import (
	"slices"
	"testing"
)

func TestRowContractRetainedIndexes(t *testing.T) {
	fixture := func() (*pgRowContract, []pgMigrationIndexJob) {
		m, _, jobs := rowIndexManifest(t)
		jobs[0].State = "valid"
		settled := *m.plan
		settled.entities = slices.Clone(m.plan.entities)
		settled.entities[0].columns = slices.Clone(m.plan.entities[0].columns)
		settled.entities[0].indexes = slices.Clone(m.plan.entities[0].indexes)
		return &pgRowContract{window: m.plan, settled: &settled}, jobs
	}
	c, jobs := fixture()
	// Removing a different column is safe while retaining an earlier index.
	c.settled.entities[0].columns = c.settled.entities[0].columns[:1]
	if err := pgVerifyRowContractRetainedIndexes(c, jobs); err != nil {
		t.Fatal("unrelated contraction refused", err)
	}
	for name, mutate := range map[string]func(*pgRowContract, []pgMigrationIndexJob){
		"drop table": func(c *pgRowContract, _ []pgMigrationIndexJob) { c.settled.entities = nil },
		"drop index": func(c *pgRowContract, _ []pgMigrationIndexJob) { c.settled.entities[0].indexes = nil },
		"change table identity": func(c *pgRowContract, _ []pgMigrationIndexJob) {
			c.settled.entities[0].identity = "OtherEntity"
		},
		"rename index": func(c *pgRowContract, _ []pgMigrationIndexJob) {
			c.settled.entities[0].indexes[0].Name = "other_index"
		},
		"change uniqueness": func(c *pgRowContract, _ []pgMigrationIndexJob) {
			c.settled.entities[0].indexes[0].Unique = !c.settled.entities[0].indexes[0].Unique
		},
		"change index": func(c *pgRowContract, _ []pgMigrationIndexJob) {
			c.settled.entities[0].indexes[0].Columns = []string{"key"}
		},
		"drop key": func(c *pgRowContract, _ []pgMigrationIndexJob) {
			c.settled.entities[0].columns = c.settled.entities[0].columns[1:]
		},
		"retype key": func(c *pgRowContract, _ []pgMigrationIndexJob) {
			c.settled.entities[0].columns[0].catalog.Type = "text"
		},
		"pending":  func(_ *pgRowContract, j []pgMigrationIndexJob) { j[0].State = "pending" },
		"building": func(_ *pgRowContract, j []pgMigrationIndexJob) { j[0].State = "building" },
		"failed":   func(_ *pgRowContract, j []pgMigrationIndexJob) { j[0].State = "failed" },
		"terminal": func(_ *pgRowContract, j []pgMigrationIndexJob) { j[0].State = "terminal" },
	} {
		t.Run(name, func(t *testing.T) {
			c, jobs := fixture()
			mutate(c, jobs)
			if err := pgVerifyRowContractRetainedIndexes(c, jobs); err == nil {
				t.Fatal("Contract accepted unsafe retained-index transition")
			}
		})
	}
}
