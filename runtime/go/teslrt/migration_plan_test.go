package teslrt

import (
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
)

func pgPlanTestColumn(name, typ string, nullable, primary bool) PgMigrationCatalogColumn {
	return PgMigrationCatalogColumn{Name: name, Type: typ, Nullable: nullable, PrimaryKey: primary}
}

func pgPlanTestSteps() []PgMigrationExpansionStep {
	primary := pgPlanTestColumn("id", "text", false, true)
	active := pgPlanTestColumn("active", "bool", false, false)
	index := PgMigrationCatalogIndex{Name: "active_idx", Columns: []string{"active"}}
	steps := []PgMigrationExpansionStep{
		{Version: 1, SnapshotHash: strings.Repeat("1", 64), EpochPreserving: true, Operations: []PgMigrationExpansionOperation{
			{Kind: "create-table", Table: "notes", Columns: []PgMigrationCatalogColumn{primary, active}, Indexes: []PgMigrationCatalogIndex{index}},
		}},
		{Version: 2, SnapshotHash: strings.Repeat("2", 64), EpochPreserving: true, Operations: []PgMigrationExpansionOperation{}},
		{Version: 3, SnapshotHash: strings.Repeat("3", 64), EpochPreserving: false, Operations: []PgMigrationExpansionOperation{}},
	}
	for _, value := range []struct{ name, typ, kind, value string }{
		{"rank", "numeric", "int", "-9007199254740993"}, {"ratio", "float8", "float64", "8000000000000000"},
		{"published", "bool", "bool", "true"}, {"caption", "text", "string", "雪é ' \\ 🙂"}, {"optional", "jsonb", "", ""},
	} {
		column := pgPlanTestColumn(value.name, value.typ, value.kind == "", false)
		if value.kind != "" {
			column.Default = &PgMigrationCatalogConstant{Kind: value.kind, Value: value.value}
		}
		steps[1].Operations = append(steps[1].Operations, PgMigrationExpansionOperation{Kind: "add-column", Table: "notes", Column: &column})
	}
	steps[1].Operations = append(steps[1].Operations,
		PgMigrationExpansionOperation{Kind: "create-table", Table: "audit", Columns: []PgMigrationCatalogColumn{primary}, Indexes: []PgMigrationCatalogIndex{}},
		PgMigrationExpansionOperation{Kind: "build-index-concurrently", Table: "notes", Index: &PgMigrationCatalogIndex{Name: "optional_idx__v2", Columns: []string{"optional"}, Unique: true}})
	risk := "requires epoch closure: old writers can conflict"
	steps[2].Operations = []PgMigrationExpansionOperation{
		{Kind: "retain-table", Table: "audit"},
		{Kind: "retain-index", Table: "notes", Index: &index},
		{Kind: "build-index-concurrently", Table: "notes", Index: &PgMigrationCatalogIndex{Name: "active_unique__v3", Columns: []string{"active"}, Unique: true}, WindowRisk: &risk},
	}
	pgPlanTestSeal(steps)
	return steps
}

func pgPlanTestSeal(steps []PgMigrationExpansionStep) {
	tables := map[string]PgMigrationCatalogTable{}
	for i := range steps {
		for _, op := range steps[i].Operations {
			if err := pgReplayMigrationOperation(tables, op); err != nil {
				panic(err)
			}
		}
		steps[i].Catalog = pgMigrationCatalogCopy(tables)
		steps[i].StepHash = pgMigrationStepHash(steps[i])
	}
}

func pgPlanTestColumnJSON(c PgMigrationCatalogColumn) map[string]any {
	return map[string]any{"name": c.Name, "type": c.Type, "nullable": c.Nullable, "primaryKey": c.PrimaryKey}
}
func pgPlanTestIndexJSON(index PgMigrationCatalogIndex) map[string]any {
	return map[string]any{"name": index.Name, "columns": index.Columns, "unique": index.Unique, "method": "btree", "nullsDistinct": true}
}
func pgPlanTestOperationJSON(op PgMigrationExpansionOperation) map[string]any {
	o := map[string]any{"kind": op.Kind, "table": op.Table}
	switch op.Kind {
	case "create-table":
		columns, indexes := []any{}, []any{}
		for _, c := range op.Columns {
			columns = append(columns, pgPlanTestColumnJSON(c))
		}
		for _, index := range op.Indexes {
			indexes = append(indexes, pgPlanTestIndexJSON(index))
		}
		o["columns"], o["indexes"] = columns, indexes
	case "add-column":
		o["column"] = pgPlanTestColumnJSON(*op.Column)
		value := map[string]any{"kind": "null"}
		if op.Column.Default != nil {
			value = map[string]any{"kind": op.Column.Default.Kind, "value": op.Column.Default.Value}
		}
		o["default"] = value
	case "build-index-concurrently", "retain-index":
		o["index"], o["windowRisk"] = pgPlanTestIndexJSON(*op.Index), op.WindowRisk
		if op.Kind == "retain-index" {
			o["requiresContract"] = true
		} else {
			o["requiresConcurrentBuilder"] = true
		}
	}
	return o
}
func pgPlanTestStepsJSON(steps []PgMigrationExpansionStep) []any {
	values := []any{}
	for _, step := range steps {
		ops := []any{}
		for _, op := range step.Operations {
			ops = append(ops, pgPlanTestOperationJSON(op))
		}
		values = append(values, map[string]any{"version": step.Version, "snapshotHash": step.SnapshotHash, "stepHash": step.StepHash,
			"epochPreserving": step.EpochPreserving, "operations": ops})
	}
	return values
}

func pgPlanTestHistory() PgCompiledMigrationHistory {
	steps := pgPlanTestSteps()
	origins := []any{}
	for origin := range 3 {
		baseline := PgMigrationExpansionStep{Version: origin + 1, SnapshotHash: steps[origin].SnapshotHash, EpochPreserving: true, Operations: []PgMigrationExpansionOperation{}}
		for _, table := range steps[origin].Catalog {
			columns := slices.Clone(table.Columns)
			for i := range columns {
				columns[i].Default = nil // Fresh installs do not inherit omission defaults.
			}
			baseline.Operations = append(baseline.Operations, PgMigrationExpansionOperation{Kind: "create-table", Table: table.Name, Columns: columns, Indexes: table.Indexes})
		}
		chain := append([]PgMigrationExpansionStep{baseline}, steps[origin+1:]...)
		pgPlanTestSeal(chain)
		origins = append(origins, map[string]any{"initialVersion": origin + 1, "steps": pgPlanTestStepsJSON(chain), "errors": []any{}})
	}
	history := PgCompiledMigrationHistory{Database: "App.Main", Family: "NotesSchema", Namespace: "notes", CurrentVersion: 3,
		SourceCompilerABI: "tesl-source-abi-v1:" + strings.Repeat("a", 64)}
	envelope := map[string]any{"version": 2, "kind": "compiled-migration-history", "compilerAbi": history.SourceCompilerABI,
		"databases": []any{map[string]any{"database": history.Database, "family": history.Family, "namespace": history.Namespace,
			"currentVersion": history.CurrentVersion, "origins": origins}}}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		panic(err)
	}
	history.HistoryJSON = string(encoded)
	return history
}

func TestPgMigrationStepIdentityVector(t *testing.T) {
	step := PgMigrationExpansionStep{Version: 2, SnapshotHash: strings.Repeat("0", 64), EpochPreserving: true}
	// Independently calculated framed SHA-256, also pinned by the OCaml suite.
	if got := pgMigrationStepHash(step); got != "684432dfc81373f761f50b1c774739e156cf11205aadaa92d894e654320325c3" {
		t.Fatalf("canonical identity drift: %s", got)
	}
	golden := []string{"98c1b95a7d9cba37b698e711bd35e87986a0aecb4cc578a8e0369d865dd17176",
		"3ab826b6198a44531229be7f371e5c8b642ea83a001a6d410d03d2c3200e0bd3",
		"f856c9a5d896d4b0b008d8a03b564fd36af23e6299f7dd59c3c0bc600faa77f8"}
	for i, step := range pgPlanTestSteps() {
		if step.StepHash != golden[i] {
			t.Fatalf("full-operation canonical identity V%d: %s", step.Version, step.StepHash)
		}
	}
}

func TestPgMigrationObjectIdentityVectors(t *testing.T) {
	step := PgMigrationExpansionStep{StepHash: strings.Repeat("b", 64), Operations: make([]PgMigrationExpansionOperation, 2)}
	for ordinal, want := range []string{"c7c61b7c4be08d91cc48acdf4a9d2aec3b970d284008dd4a0d8ac02b9a2f5d4b", "a92a876e1aa814e06a9aabb8b72dce35d44f4717a996c793e5c338228ac532ab"} {
		got, err := step.ObjectHash(ordinal)
		if err != nil || got != want {
			t.Fatalf("object identity %d: %s, %v", ordinal, got, err)
		}
	}
	for _, ordinal := range []int{-1, 2, 2147483647} {
		if _, err := step.ObjectHash(ordinal); err == nil {
			t.Fatalf("invalid ordinal %d accepted", ordinal)
		}
	}
	step.StepHash = "not a step identity"
	if _, err := step.ObjectHash(0); err == nil {
		t.Fatal("invalid parent identity accepted")
	}
}

func TestPgCompiledExpansionPlanReplay(t *testing.T) {
	history := pgPlanTestHistory()
	for origin := 1; origin <= 3; origin++ {
		plan, err := history.ExpansionPlan(origin)
		if err != nil {
			t.Fatal(err)
		}
		if len(plan.Steps) != 4-origin || plan.InitialVersion != origin || plan.CurrentVersion != 3 || plan.SourceCompilerABI != history.SourceCompilerABI {
			t.Fatalf("wrong plan: %+v", plan)
		}
		last := plan.Steps[len(plan.Steps)-1]
		if len(last.Catalog) != 2 || last.Catalog[0].Name != "audit" || last.Catalog[1].Name != "notes" || len(last.Catalog[1].Columns) != 7 || len(last.Catalog[1].Indexes) != 3 {
			t.Fatalf("retained projection: %+v", last.Catalog)
		}
		for _, c := range last.Catalog[1].Columns {
			if (c.Default != nil) != (origin == 1 && c.Name != "id" && c.Name != "active" && c.Name != "optional") {
				t.Fatalf("wrong omission default from V%d: %+v", origin, c)
			}
		}
		if origin == 1 && (len(plan.Steps[0].Catalog) != 1 || len(plan.Steps[0].Catalog[0].Columns) != 2) {
			t.Fatal("later replay mutated baseline")
		}
	}
}

func TestPgCompiledExpansionPlanImmutable(t *testing.T) {
	history := pgPlanTestHistory()
	want, err := history.ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	var group sync.WaitGroup
	for range 20 {
		group.Go(func() {
			got, err := history.ExpansionPlan(1)
			if err != nil || !reflect.DeepEqual(want, got) {
				t.Errorf("independent read: %v", err)
				return
			}
			got.Steps[1].Operations[0].Column.Default.Value = "changed"
			got.Steps[1].Catalog[1].Columns[1].Name = "changed"
			got.Steps[2].Catalog[1].Indexes[0].Columns[0] = "changed"
			if got.Steps[0].Catalog[0].Indexes[0].Columns[0] != "active" {
				t.Error("catalog indexes alias earlier snapshots")
			}
		})
	}
	group.Wait()
	again, err := history.ExpansionPlan(1)
	if err != nil || !reflect.DeepEqual(want, again) {
		t.Fatalf("caller changed linked history: %v", err)
	}
}

func TestPgCompiledExpansionPlanRefusesMalformedWire(t *testing.T) {
	base := pgPlanTestHistory()
	mutations := map[string]func(string) string{
		"old format": func(s string) string { return strings.Replace(s, `"version":2`, `"version":1`, 1) },
		"duplicate escaped": func(s string) string {
			return strings.Replace(s, `"compilerAbi":`, `"compiler\u0041bi":"wrong","compilerAbi":`, 1)
		},
		"wrong case":         func(s string) string { return strings.ReplaceAll(s, `"epochPreserving":`, `"EpochPreserving":`) },
		"unicode folded key": func(s string) string { return strings.ReplaceAll(s, `"snapshotHash":`, `"ſnapshotHash":`) },
		"trailing":           func(s string) string { return s + `{}` },
		"invalid UTF8":       func(s string) string { return s + string([]byte{0xff}) },
		"false concurrent": func(s string) string {
			return strings.ReplaceAll(s, `"requiresConcurrentBuilder":true`, `"requiresConcurrentBuilder":false`)
		},
		"false contract": func(s string) string {
			return strings.ReplaceAll(s, `"requiresContract":true`, `"requiresContract":false`)
		},
		"wrong index method":      func(s string) string { return strings.ReplaceAll(s, `"btree"`, `"hash"`) },
		"changed null uniqueness": func(s string) string { return strings.ReplaceAll(s, `"nullsDistinct":true`, `"nullsDistinct":false`) },
		"unknown operation":       func(s string) string { return strings.ReplaceAll(s, `"retain-table"`, `"drop-table"`) },
		"missing operation data":  func(s string) string { return strings.ReplaceAll(s, `"operations":[`, `"catalog":[`) },
		"unknown extra":           func(s string) string { return strings.Replace(s, `{`, `{"catalog":[],`, 1) },
		"bad literal":             func(s string) string { return strings.ReplaceAll(s, `-9007199254740993`, `-09007199254740993`) },
		"changed literal":         func(s string) string { return strings.ReplaceAll(s, `-9007199254740993`, `-9007199254740994`) },
		"changed snapshot":        func(s string) string { return strings.Replace(s, strings.Repeat("1", 64), strings.Repeat("f", 64), 1) },
		"wrong epoch": func(s string) string {
			return strings.Replace(s, `"epochPreserving":false`, `"epochPreserving":true`, 1)
		},
		"null flag":          func(s string) string { return strings.ReplaceAll(s, `"nullable":false`, `"nullable":null`) },
		"incomplete origins": func(s string) string { return strings.ReplaceAll(s, `"currentVersion":3`, `"currentVersion":4`) },
		"bad origin":         func(s string) string { return strings.ReplaceAll(s, `"initialVersion":2`, `"initialVersion":1`) },
	}
	for name, change := range mutations {
		t.Run(name, func(t *testing.T) {
			history := base
			history.HistoryJSON = change(base.HistoryJSON)
			if history.HistoryJSON == base.HistoryJSON {
				t.Fatal("mutation missed fixture")
			}
			if got, err := history.ExpansionPlan(3); err == nil || !reflect.DeepEqual(got, PgMigrationExpansionPlan{}) {
				t.Fatalf("malformed history released a plan: %v", err)
			}
		})
	}
}

func TestPgMigrationJSONExactUnicodeAndSyntax(t *testing.T) {
	for _, payload := range []string{`"\ud800"`, `"\udc00"`, `"\ud800\u0041"`, `"\ud800\uZZZZ"`, `"\ud800\u"`, `"\uZZZZ"`, `"\u123`,
		`{"x":1,"\u0078":2}`, `{"x":`, `{123:0}`, `{"x":}`, `[`, `{"x":[]}broken`, strings.Repeat("[", 34) + "0" + strings.Repeat("]", 34)} {
		if err := pgMigrationCheckJSON(payload); err == nil {
			t.Errorf("malformed JSON accepted: %s", payload)
		}
	}
	for _, payload := range []string{`"\ud83d\ude42"`, `"\\ud800"`, `"\ufffd"`, `"雪é"`, `{"\u006b":"\u0061","list":[]}`} {
		if err := pgMigrationCheckJSON(payload); err != nil {
			t.Errorf("valid exact Unicode rejected: %s: %v", payload, err)
		}
	}
	history := pgPlanTestHistory()
	plan, err := history.ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	history.HistoryJSON = strings.ReplaceAll(history.HistoryJSON, "🙂", `\ud83d\ude42`)
	actual, err := history.ExpansionPlan(1)
	if err != nil || !reflect.DeepEqual(plan, actual) {
		t.Fatalf("lossless escaped Unicode changed a plan: %v", err)
	}
}

func TestPgCompiledExpansionPlanRequiresEveryField(t *testing.T) {
	history := pgPlanTestHistory()
	var root any
	if err := json.Unmarshal([]byte(history.HistoryJSON), &root); err != nil {
		t.Fatal(err)
	}
	var visit func(any, string)
	visit = func(value any, path string) {
		switch v := value.(type) {
		case map[string]any:
			for key, original := range v {
				delete(v, key)
				encoded, err := json.Marshal(root)
				if err != nil {
					t.Fatal(err)
				}
				changed := history
				changed.HistoryJSON = string(encoded)
				if _, err := changed.ExpansionPlan(1); err == nil {
					t.Errorf("missing field accepted: %s.%s", path, key)
				}
				v[key] = original
				visit(original, path+"."+key)
			}
		case []any:
			for i, item := range v {
				visit(item, fmt.Sprintf("%s[%d]", path, i))
			}
		}
	}
	visit(root, "history")
}

func pgPlanTestRewrite(t *testing.T, history PgCompiledMigrationHistory, edit func(map[string]any)) PgCompiledMigrationHistory {
	t.Helper()
	var object map[string]any
	if err := json.Unmarshal([]byte(history.HistoryJSON), &object); err != nil {
		t.Fatal(err)
	}
	edit(object)
	encoded, err := json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	history.HistoryJSON = string(encoded)
	return history
}

func TestPgCompiledExpansionPlanOriginRefusalAndBindings(t *testing.T) {
	history := pgPlanTestHistory()
	// The compiler can reject a physical collision for only one installation
	// origin. It must remain a refusal, never a successful empty plan.
	refused := pgPlanTestRewrite(t, history, func(o map[string]any) {
		databases := o["databases"].([]any)
		origins := databases[0].(map[string]any)["origins"].([]any)
		origin := origins[1].(map[string]any)
		origin["steps"] = nil
		origin["errors"] = []any{map[string]any{"code": "MIG016", "message": "retained relation collision"}}
	})
	if _, err := refused.ExpansionPlan(1); err != nil {
		t.Fatal(err)
	}
	if _, err := refused.ExpansionPlan(3); err != nil {
		t.Fatal(err)
	}
	if plan, err := refused.ExpansionPlan(2); err == nil || !strings.Contains(err.Error(), "MIG016") || !reflect.DeepEqual(plan, PgMigrationExpansionPlan{}) {
		t.Fatalf("origin-specific refusal lost: %+v, %v", plan, err)
	}
	for name, change := range map[string]func(*PgCompiledMigrationHistory){
		"unknown connection": func(h *PgCompiledMigrationHistory) { h.Database = "App.Other" },
		"wrong family":       func(h *PgCompiledMigrationHistory) { h.Family = "OtherSchema" },
		"wrong namespace":    func(h *PgCompiledMigrationHistory) { h.Namespace = "other" },
		"wrong version":      func(h *PgCompiledMigrationHistory) { h.CurrentVersion = 2 },
		"wrong ABI": func(h *PgCompiledMigrationHistory) {
			h.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
		},
	} {
		t.Run(name, func(t *testing.T) {
			changed := history
			change(&changed)
			if _, err := changed.ExpansionPlan(1); err == nil {
				t.Fatal("mismatched linked binding accepted")
			}
		})
	}
	for _, origin := range []int{-1, 0, 4, 2147483647} {
		if _, err := history.ExpansionPlan(origin); err == nil {
			t.Fatalf("invalid origin accepted: %d", origin)
		}
	}
	// Equal namespace text can refer to different databases. The artifact keeps
	// credentials out, so it cannot infer deployment identity from this spelling.
	multiple := pgPlanTestRewrite(t, history, func(o map[string]any) {
		databases := o["databases"].([]any)
		copyDB := map[string]any{}
		for key, value := range databases[0].(map[string]any) {
			copyDB[key] = value
		}
		copyDB["database"], copyDB["family"] = "Imported.Other", "OtherSchema"
		o["databases"] = append(databases, copyDB)
	})
	if _, err := multiple.ExpansionPlan(1); err != nil {
		t.Fatal(err)
	}
	multiple.Database, multiple.Family = "Imported.Other", "OtherSchema"
	if _, err := multiple.ExpansionPlan(3); err != nil {
		t.Fatal(err)
	}
	duplicate := strings.Replace(multiple.HistoryJSON, `"Imported.Other"`, `"App.Main"`, 1)
	multiple.HistoryJSON = duplicate
	if _, err := multiple.ExpansionPlan(3); err == nil {
		t.Fatal("duplicate connection accepted")
	}
}

func TestPgCompiledExpansionPlanRejectsInvalidPhysicalHistory(t *testing.T) {
	// These have freshly recomputed hashes. Structural checks must refuse them
	// independently of accidental byte corruption detection.
	for name, change := range map[string]func([]PgMigrationExpansionStep){
		"duplicate column":         func(s []PgMigrationExpansionStep) { s[1].Operations[0].Column.Name = "active" },
		"unsupported carrier":      func(s []PgMigrationExpansionStep) { s[1].Operations[0].Column.Type = "customtype" },
		"invalid constant":         func(s []PgMigrationExpansionStep) { s[1].Operations[0].Column.Default.Value = "001" },
		"index relation collision": func(s []PgMigrationExpansionStep) { s[2].Operations[2].Index.Name = "notes_pkey" },
		"index missing column":     func(s []PgMigrationExpansionStep) { s[2].Operations[2].Index.Columns[0] = "missing" },
		"index duplicate key":      func(s []PgMigrationExpansionStep) { s[2].Operations[2].Index.Columns = []string{"active", "active"} },
		"missing primary key":      func(s []PgMigrationExpansionStep) { s[0].Operations[0].Columns[0].PrimaryKey = false },
		"nullable primary key":     func(s []PgMigrationExpansionStep) { s[0].Operations[0].Columns[0].Nullable = true },
	} {
		t.Run(name, func(t *testing.T) {
			steps := pgPlanTestSteps()
			change(steps)
			pgPlanTestSeal(steps)
			if err := pgReplayMigrationSteps(steps, map[int]string{}); err == nil {
				t.Fatal("invalid physical history accepted despite independent validation")
			}
		})
	}
	for name, op := range map[string]PgMigrationExpansionOperation{
		"absent table":           {Kind: "retain-table", Table: "absent"},
		"recreated table":        {Kind: "create-table", Table: "notes"},
		"missing index":          {Kind: "retain-index", Table: "notes", Index: &PgMigrationCatalogIndex{Name: "missing"}},
		"changed retained index": {Kind: "retain-index", Table: "notes", Index: &PgMigrationCatalogIndex{Name: "active_idx", Columns: []string{"id"}}},
		"missing omission value": {Kind: "add-column", Table: "notes", Column: &PgMigrationCatalogColumn{Name: "required", Type: "text"}},
		"new primary key":        {Kind: "add-column", Table: "notes", Column: &PgMigrationCatalogColumn{Name: "id2", Type: "text", Nullable: true, PrimaryKey: true}},
		"unknown operation":      {Kind: "execute-sql", Table: "notes"},
	} {
		t.Run(name, func(t *testing.T) {
			tables := map[string]PgMigrationCatalogTable{}
			if err := pgReplayMigrationOperation(tables, pgPlanTestSteps()[0].Operations[0]); err != nil {
				t.Fatal(err)
			}
			if err := pgReplayMigrationOperation(tables, op); err == nil {
				t.Fatal("invalid operation accepted")
			}
		})
	}
	steps := pgPlanTestSteps()
	if err := pgReplayMigrationSteps(steps, map[int]string{2: strings.Repeat("f", 64)}); err == nil {
		t.Fatal("different source snapshot for another origin accepted")
	}
}

func FuzzCompiledMigrationHistory(f *testing.F) {
	history := pgPlanTestHistory()
	f.Add(history.HistoryJSON, uint8(1))
	f.Add(history.HistoryJSON, uint8(3))
	f.Add(`{"version":2}`, uint8(1))
	f.Fuzz(func(t *testing.T, payload string, originByte uint8) {
		h := history
		h.HistoryJSON = payload
		origin := int(originByte % 5)
		plan, err := h.ExpansionPlan(origin)
		if err != nil {
			if !reflect.DeepEqual(plan, PgMigrationExpansionPlan{}) {
				t.Fatal("refusal leaked a partial plan")
			}
			return
		}
		if plan.InitialVersion != origin || len(plan.Steps) != 4-origin {
			t.Fatal("accepted incomplete plan")
		}
		for i, step := range plan.Steps {
			if step.Version != origin+i || step.StepHash != pgMigrationStepHash(step) || pgValidateMigrationCatalog(step.Catalog) != nil {
				t.Fatal("accepted inconsistent catalog or identity")
			}
		}
		again, err := h.ExpansionPlan(origin)
		if err != nil || !reflect.DeepEqual(plan, again) {
			t.Fatal("plan depends on previous decoding state")
		}
	})
}
