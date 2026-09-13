package teslrt

import (
	"slices"
	"strings"
	"testing"
)

func rowIndexManifest(t *testing.T) (*pgRowForwardManifest, map[int]*pgExpansionIntent, []pgMigrationIndexJob) {
	t.Helper()
	previous, plan := rowIndexPlanPair()
	plan.hash = strings.Repeat("1", 64)
	plan.entities[0].indexes = []PgMigrationCatalogIndex{{Name: "note_id_lookup", Columns: []string{"id"}}}
	operations, err := pgRowForwardOperations(previous, plan)
	if err != nil || len(operations) != 1 || operations[0].index == nil {
		t.Fatal(operations, err)
	}
	abi := "tesl-source-abi-v1:" + strings.Repeat("2", 64)
	id := pgMigrationObjectHash(plan.hash, 0)
	manifest := &pgRowForwardManifest{plan: plan, predecessor: previous, creatorABI: abi, operations: operations}
	intents := map[int]*pgExpansionIntent{2: {ArtifactHash: plan.hash, SourceABI: abi, Objects: []string{id}}}
	jobs := []pgMigrationIndexJob{{Version: 2, Ordinal: 0, ID: id, ObjectHash: id, SourceABI: abi, Table: "notes", Index: operations[0].index.index, State: "pending"}}
	return manifest, intents, jobs
}

func TestRowIndexCompleteJobProvenance(t *testing.T) {
	manifest, intents, jobs := rowIndexManifest(t)
	for _, state := range []string{"pending", "building", "failed", "valid"} {
		jobs[0].State = state
		if err := pgVerifyRowIndexJobs(manifest, intents, jobs, 2, manifest.creatorABI); err != nil {
			t.Fatal(state, err)
		}
	}
	jobs[0].State = "pending"
	otherABI := "tesl-source-abi-v1:" + strings.Repeat("3", 64)
	if err := pgVerifyRowIndexJobs(manifest, intents, jobs, 1, otherABI); err != nil {
		t.Fatal("old observer acquired future executor ABI obligation", err)
	}
	if err := pgVerifyRowIndexJobs(manifest, intents, jobs, 2, otherABI); err == nil {
		t.Fatal("foreign ABI can execute unfinished index")
	}
	jobs[0].State = "valid"
	if err := pgVerifyRowIndexJobs(manifest, intents, jobs, 2, otherABI); err != nil {
		t.Fatal("completed provenance became permanent executor pin", err)
	}
	for name, mutate := range map[string]func(*pgRowForwardManifest, map[int]*pgExpansionIntent, *[]pgMigrationIndexJob){
		"whole missing inventory": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) { *j = nil },
		"duplicate": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) {
			*j = append(*j, (*j)[0])
		},
		"wrong table": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) {
			(*j)[0].Table = "foreign"
		},
		"wrong name": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) {
			(*j)[0].Index.Name = "foreign"
		},
		"wrong keys": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) {
			(*j)[0].Index.Columns = []string{"key"}
		},
		"wrong object": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) {
			(*j)[0].ObjectHash = strings.Repeat("4", 64)
		},
		"wrong creator": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) {
			(*j)[0].SourceABI = otherABI
		},
		"wrong ordinal": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) {
			(*j)[0].Ordinal = 1
		},
		"wrong version": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) {
			(*j)[0].Version = 3
		},
		"uncommitted operation": func(_ *pgRowForwardManifest, i map[int]*pgExpansionIntent, _ *[]pgMigrationIndexJob) {
			i[2].Objects = nil
		},
		"changed receipt": func(_ *pgRowForwardManifest, i map[int]*pgExpansionIntent, _ *[]pgMigrationIndexJob) {
			i[2].Objects[0] = strings.Repeat("5", 64)
		},
		"wrong intent ABI": func(_ *pgRowForwardManifest, i map[int]*pgExpansionIntent, _ *[]pgMigrationIndexJob) {
			i[2].SourceABI = otherABI
		},
		"wrong intent hash": func(_ *pgRowForwardManifest, i map[int]*pgExpansionIntent, _ *[]pgMigrationIndexJob) {
			i[2].ArtifactHash = strings.Repeat("5", 64)
		},
		"terminal": func(_ *pgRowForwardManifest, _ map[int]*pgExpansionIntent, j *[]pgMigrationIndexJob) {
			v := 3
			(*j)[0].State = "terminal"
			(*j)[0].TerminalVersion = &v
		},
	} {
		t.Run(name, func(t *testing.T) {
			m, i, j := rowIndexManifest(t)
			mutate(m, i, &j)
			if err := pgVerifyRowIndexJobs(m, i, j, 0, ""); err == nil {
				t.Fatal("unbound job inventory accepted")
			}
		})
	}
	intents[2].Objects = nil
	if err := pgVerifyRowIndexJobs(manifest, intents, nil, 0, ""); err != nil {
		t.Fatal("uncommitted index acquired job obligation", err)
	}
}

func TestRowIndexCatalogOriginalReaderAndExactState(t *testing.T) {
	metadata, actual, expected, job := pgIndexCatalogTestTables(t)
	local := &pgRowPhysicalPlan{version: 1, entities: []pgRowPhysicalEntity{{table: "todos", columns: []pgRowPhysicalColumn{{catalog: PgMigrationCatalogColumn{Name: "id"}}, {catalog: PgMigrationCatalogColumn{Name: "done"}}}}}}
	var report PgMigrationCatalogReport
	live, want, ready, err := pgPrepareRowIndexCatalog(metadata, actual, expected, local, []pgMigrationIndexJob{job}, &report)
	if err != nil || !ready || len(report.Missing)+len(report.Drift) != 0 || len(live.Indexes) != 0 || len(want.Indexes) != 0 {
		t.Fatal("bounded future index refused", err, report)
	}
	job.State = "pending"
	actual.Indexes = nil
	report = PgMigrationCatalogReport{}
	if _, _, ready, err := pgPrepareRowIndexCatalog(metadata, actual, expected, local, []pgMigrationIndexJob{job}, &report); err != nil || !ready {
		t.Fatal("pending nonunique index blocks readiness", err)
	}
	job.State = "valid"
	report = PgMigrationCatalogReport{}
	if _, _, _, err := pgPrepareRowIndexCatalog(metadata, actual, expected, local, []pgMigrationIndexJob{job}, &report); err != nil || len(report.Missing) != 1 {
		t.Fatal("valid job covered absent index", err, report)
	}
	metadata, actual, expected, job = pgIndexCatalogTestTables(t)
	// A future description cannot relabel an old unbounded key as safe. Even
	// though the full expected catalog includes the index, local writes govern.
	job.Index.Columns = []string{"id"}
	if _, _, _, err := pgPrepareRowIndexCatalog(metadata, actual, expected, local, []pgMigrationIndexJob{job}, &report); err == nil || !strings.Contains(err.Error(), "admitted writes") {
		t.Fatal("old text index accepted", err)
	}
	metadata, actual, expected, job = pgIndexCatalogTestTables(t)
	actual.Indexes = append(slices.Clone(actual.Indexes), pgCatalogIndex{Name: "unrecorded"})
	live, _, _, err = pgPrepareRowIndexCatalog(metadata, actual, expected, local, []pgMigrationIndexJob{job}, &report)
	if err != nil || len(live.Indexes) != 1 || live.Indexes[0].Name != "unrecorded" {
		t.Fatal("extra index masked", err)
	}
}

func TestRowIndexFutureNullDomainUsesLocalColumns(t *testing.T) {
	metadata, actual, expected, job := pgIndexCatalogTestTables(t)
	local := &pgRowPhysicalPlan{version: 1, entities: []pgRowPhysicalEntity{{table: "todos", columns: []pgRowPhysicalColumn{{catalog: PgMigrationCatalogColumn{Name: "id"}}}}}}
	actual.Columns[1].Type, expected.Columns[1].Type = "text", "text"
	actual.Columns[1].Required, expected.Columns[1].Required = false, false
	actual.Indexes[0].Opclasses, expected.Indexes[0].Opclasses = []int64{3126}, []int64{3126}
	var report PgMigrationCatalogReport
	if _, _, _, err := pgPrepareRowIndexCatalog(metadata, actual, expected, local, []pgMigrationIndexJob{job}, &report); err != nil {
		t.Fatal("new null future key rejected despite complete future catalog", err)
	}

	// The full expected catalog already contains V2's unbounded key. Old V1
	// stays ready; V2 and its additive successors must await durable validity.
	for _, state := range []string{"pending", "valid"} {
		job.State = state
		for _, version := range []int{1, 2, 3} {
			local.version = version
			var stateReport PgMigrationCatalogReport
			_, _, ready, err := pgPrepareRowIndexCatalog(metadata, actual, expected, local, []pgMigrationIndexJob{job}, &stateReport)
			if err != nil || ready != (version == 1 || state == "valid") {
				t.Fatal("wrong exact admission readiness", state, version, ready, err)
			}
		}
	}
	local.version = 1
	for name, mutate := range map[string]func(*pgCatalogColumn){
		"required":     func(c *pgCatalogColumn) { c.Required = true },
		"default":      func(c *pgCatalogColumn) { value := "'x'::text"; c.Default = &value },
		"typmod":       func(c *pgCatalogColumn) { c.Typmod = 20 },
		"foreign type": func(c *pgCatalogColumn) { c.TypeNamespace = "extension" },
		"collation":    func(c *pgCatalogColumn) { c.Collation = 99 },
	} {
		t.Run(name, func(t *testing.T) {
			copy := *actual
			copy.Columns = slices.Clone(actual.Columns)
			mutate(&copy.Columns[1])
			if _, _, _, err := pgPrepareRowIndexCatalog(metadata, &copy, expected, local, []pgMigrationIndexJob{job}, &report); err == nil || !strings.Contains(err.Error(), "admitted writes") {
				t.Fatal("future actual domain no longer guarantees omitted null key", err)
			}
		})
	}
	local.entities[0].columns = append(local.entities[0].columns, pgRowPhysicalColumn{catalog: PgMigrationCatalogColumn{Name: "done"}})
	if _, _, _, err := pgPrepareRowIndexCatalog(metadata, actual, expected, local, []pgMigrationIndexJob{job}, &report); err == nil {
		t.Fatal("local writer of unbounded key was mistaken for absent source")
	}
}
