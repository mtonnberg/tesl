package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func pgQueueRegistrationRelink(t *testing.T, h PgCompiledMigrationHistory, root map[string]any) {
	t.Helper()
	compiledMigrationHistories.Delete(h.Family)
	compiledQueueHistories.Lock()
	delete(compiledQueueHistories.families, h.Family)
	compiledQueueHistories.Unlock()
	registerQueueProjection(t, h, root)
}
func pgQueueRegistrationSource(t *testing.T, current int) (PgCompiledMigrationHistory, map[string]any) {
	t.Helper()
	h, root := pgCandidateTestSource(t, current, false, "")
	versions := queueProjectionDB(root)["versions"].([]any)
	for i, raw := range versions {
		q := raw.(map[string]any)["contracts"].([]any)[0].(map[string]any)
		original := q["payloads"].([]any)[0].(map[string]any)
		ps := []any{original}
		for n := 0; n < i; n++ {
			p := map[string]any{}
			for k, v := range original {
				p[k] = v
			}
			p["job"] = []string{"Rebuild", "Summarize"}[n]
			ps = append(ps, p)
		}
		q["payloads"] = ps
	}
	return h, root
}
func pgQueueRegistrationVersion(t *testing.T, h PgCompiledMigrationHistory, initial, version int) PgQueueSourceVersion {
	t.Helper()
	source, err := h.QueueSourceInventory(initial)
	if err != nil {
		t.Fatal(err)
	}
	return source.Versions[version-initial]
}
func pgQueueRegistrationCall(f *pgControlTestFixture, conn *pgx.Conn, h PgCompiledMigrationHistory, v PgQueueSourceVersion, hash string, contracts any) error {
	encoded, err := json.Marshal(contracts)
	if err != nil {
		return err
	}
	_, err = conn.Exec(f.ctx, "select notes_app.tesl_register_queue_inventory($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb)", h.Family, v.Version, v.StorageSnapshotHash, v.SchemaSnapshotHash, h.SourceCompilerABI, h.StoredValueCompatibility, v.SourceSealInventory, hash, string(encoded))
	return err
}
func pgQueueRegistrationWire(t *testing.T, v PgQueueSourceVersion) []any {
	t.Helper()
	encoded, err := pgQueueRegistrationJSON(v.Contracts)
	if err != nil {
		t.Fatal(err)
	}
	var wire []any
	if err := json.Unmarshal(encoded, &wire); err != nil {
		t.Fatal(err)
	}
	return wire
}
func pgQueueRegistrationBegin(t *testing.T, f *pgControlTestFixture, h PgCompiledMigrationHistory, v int) {
	t.Helper()
	plan, err := h.ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	s := plan.Steps[v-1]
	f.call(t, "select notes_app.tesl_begin_expansion($1,$2,$3,$4,$5,$6,true)", v, s.SnapshotHash, s.StepHash, h.SourceCompilerABI, h.StoredValueCompatibility, len(s.Operations))
}
func pgQueueRegistrationAdvance(t *testing.T, f *pgControlTestFixture, h PgCompiledMigrationHistory, v int) {
	t.Helper()
	pgQueueRegistrationBegin(t, f, h, v)
	if err := pgExpansionTransaction(f.ctx, f.worker, func(tx pgx.Tx) error { return pgRegisterQueueCandidateInventory(f.ctx, tx, h, 1, v) }); err != nil {
		t.Fatal(err)
	}
	plan, err := h.ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	plan.CurrentVersion = v
	plan.Steps = plan.Steps[:v]
	var intents map[int]*pgExpansionIntent
	if err := pgExpansionTransaction(f.ctx, f.worker, func(tx pgx.Tx) error {
		var err error
		intents, err = pgReadExpansionIntents(f.ctx, tx, h.Namespace)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if err := pgApplyExpansion(f.ctx, f.worker, plan, f.roles, v-1, intents); err != nil {
		t.Fatal(err)
	}
}
func pgQueueRegistrationSetup(t *testing.T) (*pgControlTestFixture, *pgx.Conn, PgCompiledMigrationHistory, map[string]any) {
	t.Helper()
	f, request := pgNewWorkerTest(t)
	h, root := pgQueueRegistrationSource(t, 1)
	registerQueueProjection(t, h, root)
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles); err != nil {
		t.Fatal(err)
	}
	pgQueueRegistrationAdvance(t, f, h, 1)
	return f, request, h, root
}
func pgQueueRegistrationRows(t *testing.T, f *pgControlTestFixture) string {
	t.Helper()
	var s string
	if err := f.installer.QueryRow(f.ctx, `select jsonb_build_array(
 (select jsonb_agg(to_jsonb(v) order by version) from notes_app.tesl_queue_versions v),
 (select jsonb_agg(to_jsonb(q) order by version,queue) from notes_app.tesl_queue_contracts q),
 (select jsonb_agg(to_jsonb(p) order by version,queue,job_type) from notes_app.tesl_queue_payloads p),
 (select jsonb_agg(to_jsonb(s) order by version,step) from notes_app.tesl_schema_versions s),
 (select to_jsonb(s) from notes_app.tesl_schema_state s))::text`).Scan(&s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestQueueRegistrationThreeVersionsOldObserverAndOriginalProvenance(t *testing.T) {
	f, request, a, rootA := pgQueueRegistrationSetup(t)
	b, rootB := pgQueueRegistrationSource(t, 3)
	b = pgCompatibilityTestCompiler(b, "b")
	rootB["compilerAbi"] = b.SourceCompilerABI
	queueProjectionVersion(rootB)["sourceSealInventory"] = "complete"
	pgQueueRegistrationRelink(t, b, rootB)
	for v := 2; v <= 3; v++ {
		pgQueueRegistrationAdvance(t, f, b, v)
	}
	before := pgQueueRegistrationRows(t, f)
	// Compatible B replay cannot relabel A's original V1 creator or first-freeze provenance.
	if err := pgExpansionTransaction(f.ctx, f.worker, func(tx pgx.Tx) error { return pgRegisterQueueCandidateInventory(f.ctx, tx, b, 1, 1) }); err != nil {
		t.Fatal(err)
	}
	if after := pgQueueRegistrationRows(t, f); after != before {
		t.Fatal("completed replay mutated metadata")
	}
	if state, err := pgCandidateReadOnly(t, f, request, &b); err != nil || state.Current != 3 {
		t.Fatalf("B read: %+v %v", state, err)
	}
	pgQueueRegistrationRelink(t, a, rootA)
	if state, err := pgCandidateReadOnly(t, f, request, &a); err != nil || state.Current != 3 {
		t.Fatalf("old A refused future additive inventory: %+v %v", state, err)
	}
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, a, f.roles); err != nil {
		t.Fatalf("old A restart: %v", err)
	}
	if before != pgQueueRegistrationRows(t, f) {
		t.Fatal("old observer mutated future inventory")
	}
	var abi, seal string
	if err := f.installer.QueryRow(f.ctx, "select compiler_abi,source_seal_inventory from notes_app.tesl_queue_versions where version=1").Scan(&abi, &seal); err != nil || abi != a.SourceCompilerABI || seal != "unrecorded" {
		t.Fatalf("original provenance lost: %s/%s %v", abi, seal, err)
	}
	// Known-source comparison alone is insufficient: corrupt a future-only digest.
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_queue_versions set inventory_hash=$1 where version=3", strings.Repeat("f", 64)); err != nil {
		t.Fatal(err)
	}
	if _, err := pgCandidateReadOnly(t, f, request, &a); err == nil {
		t.Fatal("old observer ignored future digest tamper")
	}
}

func TestQueueRegistrationPendingIntentAndPublicationGate(t *testing.T) {
	f, request, _, _ := pgQueueRegistrationSetup(t)
	h, root := pgQueueRegistrationSource(t, 3)
	pgQueueRegistrationRelink(t, h, root)
	v := pgQueueRegistrationVersion(t, h, 1, 2)
	hash, err := pgQueueCandidateInventoryHash(h, v)
	if err != nil {
		t.Fatal(err)
	}
	wire := pgQueueRegistrationWire(t, v)
	before := pgQueueRegistrationRows(t, f)
	if err := pgQueueRegistrationCall(f, f.worker, h, v, hash, wire); err == nil {
		t.Fatal("registered without pending intent")
	}
	if before != pgQueueRegistrationRows(t, f) {
		t.Fatal("no-intent refusal mutated rows")
	}
	pgQueueRegistrationBegin(t, f, h, 2)
	if _, err := f.worker.Exec(f.ctx, "select notes_app.tesl_record_expanded(2)"); err == nil || !strings.Contains(err.Error(), "inventory") {
		t.Fatalf("published without inventory: %v", err)
	}
	before = pgQueueRegistrationRows(t, f)
	if err := pgQueueRegistrationCall(f, request, h, v, hash, wire); err == nil {
		t.Fatal("request registered control metadata")
	}
	if before != pgQueueRegistrationRows(t, f) {
		t.Fatal("request refusal mutated rows")
	}
	b := pgCompatibilityTestCompiler(h, "b")
	if err := pgQueueRegistrationCall(f, f.worker, b, v, hash, wire); err == nil {
		t.Fatal("wrong pending compiler registered")
	}
	if err := pgQueueRegistrationCall(f, f.worker, h, v, hash, wire); err != nil {
		t.Fatal(err)
	}
	before = pgQueueRegistrationRows(t, f)
	if err := pgQueueRegistrationCall(f, f.worker, b, v, hash, wire); err == nil {
		t.Fatal("wrong pending compiler replayed")
	}
	if before != pgQueueRegistrationRows(t, f) {
		t.Fatal("pending replay changed provenance")
	}
	// An old binary can still observe V1 while B's pending additive inventory exists.
	a, rootA := pgQueueRegistrationSource(t, 1)
	pgQueueRegistrationRelink(t, a, rootA)
	if _, err := pgCandidateReadOnly(t, f, request, &a); err != nil {
		t.Fatalf("old observer pending additive source: %v", err)
	}
}

func TestQueueRegistrationClosedDataAndImmutablePayloadRefusals(t *testing.T) {
	changes := map[string]func(*PgCompiledMigrationHistory, *PgQueueSourceVersion, *[]any, *string){
		"wrong family": func(h *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, _ *[]any, _ *string) {
			h.Family = "Other.Family"
		},
		"wrong digest": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, _ *[]any, hash *string) {
			*hash = strings.Repeat("f", 64)
		},
		"wrong storage snapshot": func(_ *PgCompiledMigrationHistory, v *PgQueueSourceVersion, _ *[]any, _ *string) {
			v.StorageSnapshotHash = strings.Repeat("f", 64)
		},
		"future version":  func(_ *PgCompiledMigrationHistory, v *PgQueueSourceVersion, _ *[]any, _ *string) { v.Version = 3 },
		"remove all jobs": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) { *w = []any{} },
		"remove original job": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			q := (*w)[0].(map[string]any)
			q["payloads"] = q["payloads"].([]any)[1:]
		},
		"move queue": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			(*w)[0].(map[string]any)["queue"] = "Moved"
		},
		"rename job": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			(*w)[0].(map[string]any)["payloads"].([]any)[0].(map[string]any)["job"] = "NewName"
		},
		"duplicate contract": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			*w = append(*w, (*w)[0])
		},
		"duplicate job": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			q := (*w)[0].(map[string]any)
			ps := q["payloads"].([]any)
			q["payloads"] = append(ps, ps[1])
		},
		"unsorted jobs": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			ps := (*w)[0].(map[string]any)["payloads"].([]any)
			ps[0], ps[1] = ps[1], ps[0]
		},
		"unknown queue field": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			(*w)[0].(map[string]any)["app"] = "Ignored"
		},
		"unknown payload field": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			(*w)[0].(map[string]any)["payloads"].([]any)[0].(map[string]any)["decoder"] = "ignored"
		},
		"malformed canonical": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			p := (*w)[0].(map[string]any)["payloads"].([]any)[0].(map[string]any)
			p["contract"] = "00"
			p["contractHash"] = fmt.Sprintf("%x", sha256.Sum256([]byte{0}))
		},
		"changed proof or codec closure": func(_ *PgCompiledMigrationHistory, _ *PgQueueSourceVersion, w *[]any, _ *string) {
			p := (*w)[0].(map[string]any)["payloads"].([]any)[0].(map[string]any)
			raw := pgMigrationSeq(pgMigrationBytes("tesl-migration-canonical"), pgMigrationBytes("1"), pgMigrationBytes("contract"), pgMigrationSeq(pgMigrationBytes("queue-payload-v1"), pgMigrationBytes("changed proof/codec")))
			p["contract"] = hex.EncodeToString([]byte(raw))
			p["contractHash"] = fmt.Sprintf("%x", sha256.Sum256([]byte(raw)))
		},
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			f, _, _, _ := pgQueueRegistrationSetup(t)
			h, root := pgQueueRegistrationSource(t, 3)
			pgQueueRegistrationRelink(t, h, root)
			pgQueueRegistrationBegin(t, f, h, 2)
			v := pgQueueRegistrationVersion(t, h, 1, 2)
			hash, err := pgQueueCandidateInventoryHash(h, v)
			if err != nil {
				t.Fatal(err)
			}
			wire := pgQueueRegistrationWire(t, v)
			change(&h, &v, &wire, &hash)
			// Recompute a self-consistent semantic hash whenever framing is valid. This
			// distinguishes predecessor/intent/family authorization from mere hash checks.
			if name != "wrong digest" {
				encoded := queueProjectionJSON(t, wire)
				var computed string
				if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_queue_inventory_hash($1,$2,$3,$4,$5,$6::jsonb)", h.Family, v.Version, v.StorageSnapshotHash, v.SchemaSnapshotHash, h.StoredValueCompatibility, encoded).Scan(&computed); err == nil {
					hash = computed
				}
			}
			before := pgQueueRegistrationRows(t, f)
			if err := pgQueueRegistrationCall(f, f.worker, h, v, hash, wire); err == nil {
				t.Fatal("invalid inventory registered")
			}
			if before != pgQueueRegistrationRows(t, f) {
				t.Fatal("refused inventory left partial state")
			}
		})
	}
}

func TestQueueRegistrationUnknownUpgradeCannotAuthorizeEvenEmptySource(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	h, root := pgCandidateTestSource(t, 1, true, "complete")
	registerQueueProjection(t, h, root)
	if _, err := InstallPgCompiledMigrationControl(f.ctx, f.installer, h, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgMigrationExpansion(f.ctx, f.worker, h, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := pgUpgradeQueueCandidate(f.ctx, f.installer, h, f.roles); err != nil {
		t.Fatal(err)
	}
	v := pgQueueRegistrationVersion(t, h, 1, 1)
	hash, err := pgQueueCandidateInventoryHash(h, v)
	if err != nil {
		t.Fatal(err)
	}
	before := pgQueueRegistrationRows(t, f)
	if err := pgQueueRegistrationCall(f, f.worker, h, v, hash, pgQueueRegistrationWire(t, v)); err == nil {
		t.Fatal("resealed empty old source adopted unknown baseline")
	}
	if _, err := f.worker.Exec(f.ctx, "select notes_app.tesl_record_expanded(1)"); err == nil {
		t.Fatal("unknown format4 accepted publication replay")
	}
	if before != pgQueueRegistrationRows(t, f) {
		t.Fatal("unknown refusal changed inventories or history")
	}
}

func TestQueueRegistrationCanonicalSQLMatchesGo(t *testing.T) {
	f, _, h, _ := pgQueueRegistrationSetup(t)
	v := pgQueueRegistrationVersion(t, h, 1, 1)
	raw, err := hex.DecodeString(v.Contracts[0].Payloads[0].Contract)
	if err != nil {
		t.Fatal(err)
	}
	wrap := func(x string) []byte {
		return []byte(pgMigrationSeq(pgMigrationBytes("tesl-migration-canonical"), pgMigrationBytes("1"), pgMigrationBytes("contract"), pgMigrationSeq(pgMigrationBytes("queue-payload-v1"), x)))
	}
	cases := [][]byte{nil, {}, raw, append(append([]byte{}, raw...), 0), raw[:len(raw)-1], wrap("l0:"), wrap("s0:"), wrap("s3:雪"), wrap("s2:雪"), wrap("s03:foo"), wrap("l2:s1:xs1:y"), wrap("l99999999999999999999:"), wrap("l1:" + strings.Repeat("l1:", 509) + "s0:"), wrap("l1:" + strings.Repeat("l1:", 510) + "s0:"), wrap("l1:" + strings.Repeat("l1:", 511) + "s0:")}
	for i, data := range cases {
		var got bool
		if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_queue_contract_valid($1::bytea)", data).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if want := pgQueueCanonicalContract(data) == nil; got != want {
			t.Fatalf("canonical case %d SQL=%v Go=%v", i, got, want)
		}
	}
	for _, empty := range []bool{false, true} {
		if empty {
			v.Contracts = []PgQueueSourceContract{}
		}
		want, err := pgQueueCandidateInventoryHash(h, v)
		if err != nil {
			t.Fatal(err)
		}
		var got string
		if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_queue_inventory_hash($1,$2,$3,$4,$5,$6::jsonb)", h.Family, v.Version, v.StorageSnapshotHash, v.SchemaSnapshotHash, h.StoredValueCompatibility, queueProjectionJSON(t, pgQueueRegistrationWire(t, v))).Scan(&got); err != nil || got != want {
			t.Fatalf("SQL/Go digest %s/%s %v", got, want, err)
		}
	}
}

func TestQueueRegistrationFreshOriginReplayBeforeIntent(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	h, root := pgQueueRegistrationSource(t, 3)
	registerQueueProjection(t, h, root)
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles); err != nil {
		t.Fatal(err)
	}
	before := pgQueueRegistrationRows(t, f)
	if err := pgExpansionTransaction(f.ctx, f.worker, func(tx pgx.Tx) error { return pgRegisterQueueCandidateInventory(f.ctx, tx, h, 3, 3) }); err != nil {
		t.Fatal(err)
	}
	if before != pgQueueRegistrationRows(t, f) {
		t.Fatal("fresh origin replay changed creator metadata")
	}
	v := pgQueueRegistrationVersion(t, h, 3, 3)
	hash, err := pgQueueCandidateInventoryHash(h, v)
	if err != nil {
		t.Fatal(err)
	}
	b := pgCompatibilityTestCompiler(h, "b")
	if err := pgQueueRegistrationCall(f, f.worker, b, v, hash, pgQueueRegistrationWire(t, v)); err == nil {
		t.Fatal("fresh unstarted origin replay accepted another ABI")
	}
	// A source origin is not permission to add an earlier inventory to a V3 installation.
	old := pgQueueRegistrationVersion(t, h, 1, 1)
	oldHash, err := pgQueueCandidateInventoryHash(h, old)
	if err != nil {
		t.Fatal(err)
	}
	if err := pgQueueRegistrationCall(f, f.worker, h, old, oldHash, pgQueueRegistrationWire(t, old)); err == nil {
		t.Fatal("cross-origin registration accepted")
	}
	if before != pgQueueRegistrationRows(t, f) {
		t.Fatal("origin refusal changed metadata")
	}
}

func TestQueueRegistrationCatalogRemainsClosedAndWorkerOnly(t *testing.T) {
	for name, sql := range map[string]string{
		"public helper":        "grant execute on function notes_app.tesl_queue_inventory_json(integer) to public",
		"request registration": "grant execute on function notes_app.tesl_register_queue_inventory(text,integer,text,text,text,text,text,text,jsonb) to @request@",
		"mutable hash":         "alter function notes_app.tesl_queue_inventory_hash(text,integer,text,text,text,jsonb) volatile",
		"search path":          "alter function notes_app.tesl_register_queue_inventory(text,integer,text,text,text,text,text,text,jsonb) set search_path=public",
		"missing helper":       "drop function notes_app.tesl_queue_inventory_preserves(jsonb,jsonb)",
	} {
		t.Run(name, func(t *testing.T) {
			f, request, h, _ := pgQueueRegistrationSetup(t)
			sql = strings.ReplaceAll(sql, "@request@", quoteIdentifier(f.roles.Request))
			if _, err := f.installer.Exec(f.ctx, sql); err != nil {
				t.Fatal(err)
			}
			if _, err := pgCandidateReadOnly(t, f, request, &h); err == nil {
				t.Fatal("modified candidate function catalog accepted")
			}
		})
	}
}

func TestQueueRegistrationRejectsSnapshotIsolationBeforeMutation(t *testing.T) {
	f, _, h, _ := pgQueueRegistrationSetup(t)
	for _, level := range []pgx.TxIsoLevel{pgx.RepeatableRead, pgx.Serializable} {
		before := pgQueueRegistrationRows(t, f)
		tx, err := f.worker.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: level})
		if err != nil {
			t.Fatal(err)
		}
		err = pgRegisterQueueCandidateInventory(f.ctx, tx, h, 1, 1)
		if rollback := tx.Rollback(f.ctx); rollback != nil {
			t.Fatal(rollback)
		}
		if err == nil || !strings.Contains(err.Error(), "read committed") {
			t.Fatalf("isolation %s accepted: %v", level, err)
		}
		if before != pgQueueRegistrationRows(t, f) {
			t.Fatal("isolation refusal mutated source")
		}
	}
}

func TestQueueRegistrationFreshEmptyInventoryAllowsLaterContracts(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	a, rootA := pgCandidateTestSource(t, 1, true, "unrecorded")
	registerQueueProjection(t, a, rootA)
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, a, f.roles); err != nil {
		t.Fatal(err)
	}
	pgQueueRegistrationAdvance(t, f, a, 1)
	b, rootB := pgQueueRegistrationSource(t, 3)
	queueProjectionVersion(rootB)["contracts"] = []any{}
	// A second queue demonstrates whole-inventory ownership across contracts.
	for _, raw := range queueProjectionDB(rootB)["versions"].([]any)[1:] {
		v := raw.(map[string]any)
		first := v["contracts"].([]any)[0].(map[string]any)
		payload := map[string]any{}
		for k, val := range first["payloads"].([]any)[0].(map[string]any) {
			payload[k] = val
		}
		payload["job"] = "Cleanup"
		v["contracts"] = append(v["contracts"].([]any), map[string]any{"queue": "Workers.Maintenance", "payloads": []any{payload}})
	}
	pgQueueRegistrationRelink(t, b, rootB)
	for v := 2; v <= 3; v++ {
		pgQueueRegistrationAdvance(t, f, b, v)
	}
	if state, err := pgCandidateReadOnly(t, f, request, &b); err != nil || state.Current != 3 {
		t.Fatalf("new contracts after empty origin: %+v %v", state, err)
	}
	pgQueueRegistrationRelink(t, a, rootA)
	if _, err := pgCandidateReadOnly(t, f, request, &a); err != nil {
		t.Fatalf("old empty inventory observer: %v", err)
	}
}

func TestQueueRegistrationResignedFutureTamperStillRefused(t *testing.T) {
	for name, sql := range map[string]string{
		"removed payload": "delete from notes_app.tesl_queue_payloads where version=3 and job_type='Notify';update notes_app.tesl_queue_versions set payload_count=payload_count-1 where version=3;update notes_app.tesl_queue_contracts set payload_count=payload_count-1 where version=3",
		"changed closure": "update notes_app.tesl_queue_payloads set contract=convert_to(replace(convert_from(contract,'UTF8'),'fixture','changed'),'UTF8'),contract_hash=encode(sha256(convert_to(replace(convert_from(contract,'UTF8'),'fixture','changed'),'UTF8')),'hex') where version=3 and job_type='Notify'",
		"moved payload":   "update notes_app.tesl_queue_payloads set job_type='ArchivedNotify' where version=3 and job_type='Notify'",
	} {
		t.Run(name, func(t *testing.T) {
			f, request, a, rootA := pgQueueRegistrationSetup(t)
			h, root := pgQueueRegistrationSource(t, 3)
			pgQueueRegistrationRelink(t, h, root)
			for v := 2; v <= 3; v++ {
				pgQueueRegistrationAdvance(t, f, h, v)
			}
			if _, err := f.installer.Exec(f.ctx, sql); err != nil {
				t.Fatal(err)
			}
			// The owner re-signs framing/count-correct metadata. This still cannot erase
			// an immutable predecessor payload merely because an old binary lacks V3 source.
			if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_queue_versions v set inventory_hash=notes_app.tesl_queue_inventory_hash($1,version,storage_snapshot_hash,schema_snapshot_hash,stored_value_compatibility,notes_app.tesl_queue_inventory_json(version)) where version=3", h.Family); err != nil {
				t.Fatal(err)
			}
			if _, err := f.worker.Exec(f.ctx, "select notes_app.tesl_queue_verify_inventory($1)", h.Family); err == nil {
				t.Fatal("SQL observer accepted changed predecessor payload")
			}
			pgQueueRegistrationRelink(t, a, rootA)
			if _, err := pgCandidateReadOnly(t, f, request, &a); err == nil {
				t.Fatal("old Go observer accepted changed predecessor payload")
			}
		})
	}
}
