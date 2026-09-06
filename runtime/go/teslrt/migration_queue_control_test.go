package teslrt

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func pgCandidateTestSource(t *testing.T, current int, empty bool, provenance string) (PgCompiledMigrationHistory, map[string]any) {
	t.Helper()
	original, root := queueProjectionFixture(t)
	h := pgExpansionTestHistory("notes_app", current)
	var linked map[string]any
	if err := json.Unmarshal([]byte(h.HistoryJSON), &linked); err != nil {
		t.Fatal(err)
	}
	h.Family = original.Family
	linked["databases"].([]any)[0].(map[string]any)["family"] = h.Family
	h.HistoryJSON = queueProjectionJSON(t, linked)
	plan, err := h.ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	db := queueProjectionDB(root)
	db["database"] = h.Database
	db["family"] = h.Family
	db["namespace"] = h.Namespace
	db["currentVersion"] = current
	root["compilerAbi"] = h.SourceCompilerABI
	root["storedValueCompatibility"] = h.StoredValueCompatibility
	versions := db["versions"].([]any)[:current]
	origins := []any{}
	for i, raw := range versions {
		v := raw.(map[string]any)
		v["storageSnapshotHash"] = plan.Steps[i].SnapshotHash
		if provenance != "" {
			v["sourceSealInventory"] = provenance
		}
		if empty {
			v["contracts"] = []any{}
		}
		refs := []int{}
		for n := i + 1; n <= current; n++ {
			refs = append(refs, n)
		}
		origins = append(origins, map[string]any{"initialVersion": i + 1, "versions": refs})
	}
	db["versions"] = versions
	db["origins"] = origins
	return h, root
}
func pgQueueCandidateTestHistory(t *testing.T, empty bool) PgCompiledMigrationHistory {
	h, root := pgCandidateTestSource(t, 3, empty, "")
	registerQueueProjection(t, h, root)
	return h
}
func pgCandidateReadOnly(t *testing.T, f *pgControlTestFixture, conn *pgx.Conn, h *PgCompiledMigrationHistory) (PgMigrationControlState, error) {
	t.Helper()
	var state PgMigrationControlState
	err := pgControlSnapshotMode(f.ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		if err := pgControlRoles(f.ctx, tx, f.roles, false); err != nil {
			return err
		}
		var err error
		state, err = pgInspectQueueCandidate(f.ctx, tx, f.namespace, f.roles)
		if err != nil {
			return err
		}
		if h != nil {
			p := pgQueueCandidatePreparation{history: *h, roles: f.roles}
			return p.verify(f.ctx, tx, state)
		}
		return nil
	})
	return state, err
}
func TestQueueCandidateFreshCompleteBaselineAndReadOnlyCatalog(t *testing.T) {
	for _, empty := range []bool{false, true} {
		t.Run(fmt.Sprint(empty), func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			h := pgQueueCandidateTestHistory(t, empty)
			state, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles)
			if err != nil {
				t.Fatal(err)
			}
			if state.Format != 4 || state.Current != 0 || state.InitialVersion != 3 {
				t.Fatalf("bad candidate state %+v", state)
			}
			read, err := pgCandidateReadOnly(t, f, request, &h)
			if err != nil || !reflect.DeepEqual(read, state) {
				t.Fatalf("read-only candidate %+v: %v", read, err)
			}
			retry, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles)
			if err != nil || !reflect.DeepEqual(state, retry) {
				t.Fatalf("retry %+v: %v", retry, err)
			}
			var authority string
			var versions, count int
			if err := f.installer.QueryRow(f.ctx, "select inventory_authority,(select count(*) from notes_app.tesl_queue_versions),(select count(*) from notes_app.tesl_queue_payloads) from notes_app.tesl_queue_baseline").Scan(&authority, &versions, &count); err != nil || authority != "complete" || versions != 1 || (empty && count != 0) || (!empty && count != 1) {
				t.Fatalf("bad baseline %s/%d/%d: %v", authority, versions, count, err)
			}
			if _, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles); err == nil || !strings.Contains(err.Error(), "unsupported") {
				t.Fatalf("production reader enabled candidate: %v", err)
			}
			if _, err := InstallPgCompiledMigrationControl(f.ctx, f.installer, h, f.roles); err == nil {
				t.Fatal("production install enabled candidate")
			}
			if _, err := UpgradePgCompiledMigrationControl(f.ctx, f.installer, h, f.roles, 4); err == nil {
				t.Fatal("public upgrade enabled candidate")
			}
		})
	}
}
func TestQueueCandidateFreshMissingMetadataHasNoMutation(t *testing.T) {
	f := pgNewControlTest(t)
	h, _ := queueProjectionFixture(t)
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles); err == nil {
		t.Fatal("missing companion installed candidate")
	}
	var exists bool
	if err := f.installer.QueryRow(f.ctx, "select exists(select 1 from pg_catalog.pg_namespace where nspname='notes_app')").Scan(&exists); err != nil || exists {
		t.Fatalf("refusal mutated namespace: %v %v", exists, err)
	}
	state := f.install(t, 1)
	if state.Format != 3 {
		t.Fatal("default format changed")
	}
	h = pgQueueCandidateTestHistory(t, true)
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles); err == nil {
		t.Fatal("fresh installer laundered existing format3")
	}
}
func TestQueueCandidateUpgradeUnknownPreservesEverything(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	f.expand(t, 3)
	f.call(t, "insert into notes_app.notes(id,active) values('retained',true)")
	old := pgControlUpgradePreservedRows(t, f)
	h := pgExpansionTestHistory(f.namespace, 3)
	before, err := InspectPgMigrationControl(f.ctx, f.worker, f.namespace, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	state, err := pgUpgradeQueueCandidate(f.ctx, f.installer, h, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	before.Format = 4
	if !reflect.DeepEqual(before, state) || old != pgControlUpgradePreservedRows(t, f) {
		t.Fatal("upgrade changed prior history/entity/identity")
	}
	for range 2 {
		read, err := pgCandidateReadOnly(t, f, request, nil)
		if err != nil || !reflect.DeepEqual(read, state) {
			t.Fatalf("request observe unknown %+v %v", read, err)
		}
		retry, err := pgUpgradeQueueCandidate(f.ctx, f.installer, h, f.roles)
		if err != nil || !reflect.DeepEqual(retry, state) {
			t.Fatalf("upgrade retry %+v %v", retry, err)
		}
	}
	var authority, hash string
	var versions int
	if err := f.installer.QueryRow(f.ctx, "select inventory_authority,coalesce(inventory_hash,''),(select count(*) from notes_app.tesl_queue_versions) from notes_app.tesl_queue_baseline").Scan(&authority, &hash, &versions); err != nil || authority != "unknown" || hash != "" || versions != 0 {
		t.Fatalf("legacy absence became complete %s/%s/%d %v", authority, hash, versions, err)
	}
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, pgQueueCandidateTestHistory(t, true), f.roles); err == nil {
		t.Fatal("recompiled empty source laundered unknown baseline")
	}
}
func TestQueueCandidateUpgradeRefusalsLeaveFormat3Untouched(t *testing.T) {
	for _, scenario := range []string{"worker", "unfinished", "format2", "collision", "source-mismatch"} {
		t.Run(scenario, func(t *testing.T) {
			f := pgNewControlTest(t)
			f.install(t, 1)
			f.expand(t, 2)
			h := pgExpansionTestHistory(f.namespace, 2)
			conn := f.installer
			switch scenario {
			case "worker":
				conn = f.worker
			case "unfinished":
				h = pgExpansionTestHistory(f.namespace, 3)
				plan, err := h.ExpansionPlan(1)
				if err != nil {
					t.Fatal(err)
				}
				s := plan.Steps[2]
				f.call(t, "select notes_app.tesl_begin_expansion(3,$1,$2,$3,$4,$5,true)", s.SnapshotHash, s.StepHash, h.SourceCompilerABI, h.StoredValueCompatibility, len(s.Operations))
			case "format2":
				pgControlTestFormat2(t, f)
			case "collision":
				f.call(t, "create table notes_app.tesl_jobs(id text)")
			case "source-mismatch":
				h = pgPlanTestHistory()
			}
			before := pgControlUpgradePreservedRows(t, f)
			if _, err := pgUpgradeQueueCandidate(f.ctx, conn, h, f.roles); err == nil {
				t.Fatal("unsafe upgrade accepted")
			}
			if before != pgControlUpgradePreservedRows(t, f) {
				t.Fatal("refused upgrade changed existing rows")
			}
			var n int
			if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='notes_app' and c.relname='tesl_queue_baseline'").Scan(&n); err != nil || n != 0 {
				t.Fatalf("partial baseline published %d %v", n, err)
			}
		})
	}
}
func TestQueueCandidateCatalogAndInventoryTamperRefused(t *testing.T) {
	cases := map[string]string{
		"extra-column":          "alter table notes_app.tesl_jobs add column bogus text",
		"default":               "alter table notes_app.tesl_jobs alter column attempts set default 1",
		"owner":                 "alter table notes_app.tesl_jobs owner to @worker@",
		"grant":                 "grant update on notes_app.tesl_jobs to @worker@",
		"payload-read-grant":    "grant select on notes_app.tesl_jobs to @request@",
		"column-grant":          "grant select(payload) on notes_app.tesl_jobs to @request@",
		"metadata-grant-option": "grant select on notes_app.tesl_queue_versions to @request@ with grant option",
		"missing-reader":        "revoke select on notes_app.tesl_queue_versions from @request@",
		"sequence-grant":        "grant select on sequence notes_app.tesl_jobs_seq_seq to @request@",
		"sequence-increment":    "alter sequence notes_app.tesl_jobs_seq_seq increment by 2",
		"sequence-name":         "alter sequence notes_app.tesl_jobs_seq_seq rename to wrong_sequence",
		"missing-index":         "drop index notes_app.tesl_jobs_claim_idx",
		"index-name":            "alter index notes_app.tesl_jobs_claim_idx rename to renamed_claim",
		"fk-wrong-table":        "create table notes_app.other_payloads(like notes_app.tesl_queue_payloads including all); alter table notes_app.tesl_jobs drop constraint tesl_jobs_schema_version_queue_job_type_fkey; alter table notes_app.tesl_jobs add foreign key(schema_version,queue,job_type) references notes_app.other_payloads(version,queue,job_type)",
		"rls":                   "alter table notes_app.tesl_jobs enable row level security",
		"fk-disabled":           "alter table notes_app.tesl_jobs disable trigger all",
		"fk-deferred":           "alter table notes_app.tesl_jobs alter constraint tesl_jobs_schema_version_queue_job_type_fkey deferrable initially deferred",
		"fk-retarget":           "alter table notes_app.tesl_jobs drop constraint tesl_jobs_schema_version_queue_job_type_fkey; alter table notes_app.tesl_jobs add foreign key(schema_version,queue,job_type) references notes_app.tesl_queue_payloads(version,queue,job_type) on delete cascade",
		"missing-baseline":      "delete from notes_app.tesl_queue_baseline",
		"wrong-initial":         "update notes_app.tesl_queue_baseline set initial_version=2",
		"missing-payload":       "delete from notes_app.tesl_queue_payloads",
		"inventory-count":       "update notes_app.tesl_queue_versions set payload_count=2",
		"source-hash":           "update notes_app.tesl_queue_versions set schema_snapshot_hash=repeat('b',64)",
		"storage-hash":          "update notes_app.tesl_queue_versions set storage_snapshot_hash=repeat('b',64)",
		"abi":                   "update notes_app.tesl_queue_versions set compiler_abi='tesl-source-abi-v1:'||repeat('b',64)",
	}
	for name, sql := range cases {
		t.Run(name, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			h := pgQueueCandidateTestHistory(t, false)
			if _, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles); err != nil {
				t.Fatal(err)
			}
			sql = strings.ReplaceAll(strings.ReplaceAll(sql, "@worker@", quoteIdentifier(f.roles.Worker)), "@request@", quoteIdentifier(f.roles.Request))
			if _, err := f.installer.Exec(f.ctx, sql); err != nil {
				t.Fatal(err)
			}
			if _, err := pgCandidateReadOnly(t, f, request, &h); err == nil {
				t.Fatal("tampered candidate accepted")
			}
		})
	}
}
func TestQueueCandidateCanonicalInventoryBinding(t *testing.T) {
	h := pgQueueCandidateTestHistory(t, false)
	source, err := h.QueueSourceInventory(1)
	if err != nil {
		t.Fatal(err)
	}
	v := source.Versions[0]
	hash, err := pgQueueCandidateInventoryHash(h, v)
	if err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(*PgCompiledMigrationHistory, *PgQueueSourceVersion){func(h *PgCompiledMigrationHistory, v *PgQueueSourceVersion) { h.Family += "Elsewhere" }, func(h *PgCompiledMigrationHistory, v *PgQueueSourceVersion) { v.Version++ }, func(h *PgCompiledMigrationHistory, v *PgQueueSourceVersion) {
		v.SchemaSnapshotHash = strings.Repeat("b", 64)
	}, func(h *PgCompiledMigrationHistory, v *PgQueueSourceVersion) {
		v.StorageSnapshotHash = strings.Repeat("b", 64)
	}} {
		hh, vv := h, v
		change(&hh, &vv)
		got, err := pgQueueCandidateInventoryHash(hh, vv)
		if err != nil || got == hash {
			t.Fatalf("inventory identity was not bound: %s %v", got, err)
		}
	}
	vv := v
	vv.Contracts = append(append([]PgQueueSourceContract{}, v.Contracts...), v.Contracts[0])
	if _, err := pgQueueCandidateInventoryHash(h, vv); err == nil {
		t.Fatal("duplicate inventory normalized")
	}
}

func TestQueueCandidateCreatorABIAndSealProvenanceRemainHistorical(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	a, root := pgCandidateTestSource(t, 1, false, "unrecorded")
	registerQueueProjection(t, a, root)
	installed, err := pgInstallQueueCandidate(f.ctx, f.installer, a, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	source, err := a.QueueSourceInventory(1)
	if err != nil {
		t.Fatal(err)
	}
	originalHash, err := pgQueueCandidateInventoryHash(a, source.Versions[0])
	if err != nil {
		t.Fatal(err)
	}
	b := pgCompatibilityTestCompiler(a, "b")
	var rebound map[string]any
	if err := json.Unmarshal([]byte(b.HistoryJSON), &rebound); err != nil {
		t.Fatal(err)
	}
	b.Database = "RenamedApplication.RenamedDatabase"
	rebound["databases"].([]any)[0].(map[string]any)["database"] = b.Database
	b.HistoryJSON = queueProjectionJSON(t, rebound)
	queueProjectionDB(root)["database"] = b.Database
	v := source.Versions[0]
	v.SourceSealInventory = "complete"
	changedHash, err := pgQueueCandidateInventoryHash(b, v)
	if err != nil || changedHash != originalHash {
		t.Fatalf("compiler/provenance changed semantic inventory %s/%s %v", originalHash, changedHash, err)
	}
	// Relink models a separate newly built binary, not a permissive runtime overwrite.
	compiledMigrationHistories.Delete(a.Family)
	compiledQueueHistories.Lock()
	delete(compiledQueueHistories.families, a.Family)
	compiledQueueHistories.Unlock()
	root["compilerAbi"] = b.SourceCompilerABI
	queueProjectionVersion(root)["sourceSealInventory"] = "complete"
	registerQueueProjection(t, b, root)
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, b, f.roles); err == nil || !strings.Contains(err.Error(), "pinned") {
		t.Fatalf("pending origin accepted other compiler ABI: %v", err)
	}
	// Exercise actual protected lifecycle calls and entity DDL for the recorded A
	// origin. This test-only helper bypasses only the intentionally unpublished
	// production format selector; it does not rewrite history/catalog rows by hand.
	plan, err := a.ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	if err := pgApplyExpansion(f.ctx, f.worker, plan, f.roles, 0, map[int]*pgExpansionIntent{}); err != nil {
		t.Fatal(err)
	}
	before := pgControlUpgradePreservedRows(t, f)
	read, err := pgCandidateReadOnly(t, f, request, &b)
	if err != nil || read.Current != 1 || read.DatabaseUUID != installed.DatabaseUUID {
		t.Fatalf("compatible completed B observer refused %+v %v", read, err)
	}
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, b, f.roles); err != nil {
		t.Fatalf("compatible completed B retry refused: %v", err)
	}
	var abi, provenance, hash string
	if err := f.installer.QueryRow(f.ctx, "select compiler_abi,source_seal_inventory,inventory_hash from notes_app.tesl_queue_versions where version=1").Scan(&abi, &provenance, &hash); err != nil || abi != a.SourceCompilerABI || provenance != "unrecorded" || hash != originalHash {
		t.Fatalf("creator provenance relabeled %s/%s/%s %v", abi, provenance, hash, err)
	}
	if before != pgControlUpgradePreservedRows(t, f) {
		t.Fatal("compatible inspection/retry relabeled completed expansion")
	}
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_queue_versions set compiler_abi=$1", b.SourceCompilerABI); err != nil {
		t.Fatal(err)
	}
	if _, err := pgCandidateReadOnly(t, f, request, &b); err == nil || !strings.Contains(err.Error(), "creator differs") {
		t.Fatalf("stored creator/intent mismatch accepted: %v", err)
	}
}

func TestQueueCandidateInventoryCanonicalVector(t *testing.T) {
	h := PgCompiledMigrationHistory{Database: "A.D", Family: "Schema.Todo", Namespace: "one", SourceCompilerABI: "tesl-source-abi-v1:" + strings.Repeat("d", 64), StoredValueCompatibility: "tesl-stored-value-v1:" + strings.Repeat("c", 64)}
	v := PgQueueSourceVersion{Version: 1, StorageSnapshotHash: strings.Repeat("a", 64), SchemaSnapshotHash: strings.Repeat("b", 64), SourceSealInventory: "unrecorded", Contracts: []PgQueueSourceContract{}}
	// Independently computed length-framed byte vector, including explicit empty l0:.
	want := "40dc98e4130f2cab36e9c1bce071bac50cf2b2abf7d1b3acae4003c6da745b4c"
	got, err := pgQueueCandidateInventoryHash(h, v)
	if err != nil || got != want {
		t.Fatalf("inventory wire drift %s %v", got, err)
	}
	h.Database = "AppRenamed.ConnectionRenamed"
	h.Namespace = "deployed-elsewhere"
	h.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("e", 64)
	v.SourceSealInventory = "complete"
	got, err = pgQueueCandidateInventoryHash(h, v)
	if err != nil || got != want {
		t.Fatalf("deployment/provenance leaked into semantic identity %s %v", got, err)
	}
}
func TestQueueCandidateQuotedNamespaceAndDeniedDirectWrites(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	h, root := pgCandidateTestSource(t, 1, false, "unrecorded")
	f.namespace = "queue '$format$\"\\雪"
	h.Namespace = f.namespace
	var linked map[string]any
	if err := json.Unmarshal([]byte(h.HistoryJSON), &linked); err != nil {
		t.Fatal(err)
	}
	linked["databases"].([]any)[0].(map[string]any)["namespace"] = h.Namespace
	h.HistoryJSON = queueProjectionJSON(t, linked)
	queueProjectionDB(root)["namespace"] = h.Namespace
	registerQueueProjection(t, h, root)
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := pgCandidateReadOnly(t, f, request, &h); err != nil {
		t.Fatal(err)
	}
	ns := pgx.Identifier{f.namespace}.Sanitize() + "."
	for _, conn := range []*pgx.Conn{f.worker, request} {
		for _, sql := range []string{
			"update " + ns + "tesl_queue_baseline set inventory_authority='complete'",
			"update " + ns + "tesl_queue_versions set compiler_abi='forged'",
			"insert into " + ns + "tesl_jobs(id,queue,job_type,payload,schema_version,status) values('j','Notifications','Notify','{}',1,'pending')",
			"select * from " + ns + "tesl_jobs",
			"select nextval('" + strings.ReplaceAll(ns+"tesl_jobs_seq_seq", "'", "''") + "'::regclass)",
		} {
			if _, err := conn.Exec(f.ctx, sql); err == nil {
				t.Fatalf("ordinary login received protected queue authority: %s", sql)
			} else {
				var denied *pgconn.PgError
				if !errors.As(err, &denied) || denied.Code != "42501" {
					t.Fatalf("test did not reach privilege refusal for %s: %v", sql, err)
				}
			}
		}
	}
	if _, err := pgCandidateReadOnly(t, f, request, &h); err != nil {
		t.Fatal(err)
	}
}
