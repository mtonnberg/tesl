package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
)

func queueProjectionFixture(t *testing.T) (PgCompiledMigrationHistory, map[string]any) {
	t.Helper()
	history := pgPlanTestHistory()
	family := fmt.Sprintf("Projection%xSchema", sha256.Sum256([]byte(t.Name())))
	history.Family = family
	var linked map[string]any
	if err := json.Unmarshal([]byte(history.HistoryJSON), &linked); err != nil {
		t.Fatal(err)
	}
	linked["databases"].([]any)[0].(map[string]any)["family"] = family
	history.HistoryJSON = queueProjectionJSON(t, linked)
	plan, err := history.ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	canonical := pgMigrationSeq(pgMigrationBytes("tesl-migration-canonical"), pgMigrationBytes("1"), pgMigrationBytes("contract"), pgMigrationSeq(pgMigrationBytes("queue-payload-v1"), pgMigrationSeq(pgMigrationBytes("fixture"))))
	payload := map[string]any{"job": "Notify", "contractFormat": "tesl-queue-payload-v1", "contract": hex.EncodeToString([]byte(canonical)), "contractHash": fmt.Sprintf("%x", sha256.Sum256([]byte(canonical)))}
	versions, origins := []any{}, []any{}
	for i, step := range plan.Steps {
		versions = append(versions, map[string]any{"version": i + 1, "storageSnapshotHash": step.SnapshotHash, "schemaSnapshotHash": strings.Repeat("a", 64), "checkedInventory": "complete", "sourceSealInventory": []string{"unrecorded", "unknown", "complete"}[i], "contracts": []any{map[string]any{"queue": "Notifications", "payloads": []any{payload}}}})
		refs := []int{}
		for v := i + 1; v <= 3; v++ {
			refs = append(refs, v)
		}
		origins = append(origins, map[string]any{"initialVersion": i + 1, "versions": refs})
	}
	root := map[string]any{"version": 1, "kind": "compiled-queue-history", "compilerAbi": history.SourceCompilerABI, "storedValueCompatibility": history.StoredValueCompatibility, "databases": []any{map[string]any{"database": history.Database, "family": history.Family, "namespace": history.Namespace, "currentVersion": 3, "versions": versions, "origins": origins}}}
	t.Cleanup(func() {
		compiledMigrationHistories.Delete(family)
		compiledQueueHistories.Lock()
		delete(compiledQueueHistories.families, family)
		compiledQueueHistories.Unlock()
		databaseIdentities.Delete(history.Database)
	})
	return history, root
}
func queueProjectionJSON(t *testing.T, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
func queueProjectionDB(root map[string]any) map[string]any {
	return root["databases"].([]any)[0].(map[string]any)
}
func queueProjectionVersion(root map[string]any) map[string]any {
	return queueProjectionDB(root)["versions"].([]any)[0].(map[string]any)
}
func queueProjectionPayload(root map[string]any) map[string]any {
	return queueProjectionVersion(root)["contracts"].([]any)[0].(map[string]any)["payloads"].([]any)[0].(map[string]any)
}
func registerQueueProjection(t *testing.T, h PgCompiledMigrationHistory, root map[string]any) {
	t.Helper()
	registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
	registerCompiledQueueHistory(queueProjectionJSON(t, root))
}
func TestQueueProjectionSourceIsNotBaselineAuthority(t *testing.T) {
	h, root := queueProjectionFixture(t)
	if _, err := h.QueueSourceInventory(1); err == nil || !strings.Contains(err.Error(), "missing") {
		t.Fatal("missing metadata became empty", err)
	}
	registerQueueProjection(t, h, root)
	for initial := 1; initial <= 3; initial++ {
		got, err := h.QueueSourceInventory(initial)
		if err != nil {
			t.Fatal(err)
		}
		if len(got.Versions) != 4-initial || got.Versions[0].Version != initial {
			t.Fatal("origin lost source inventory", got)
		}
	}
	got, err := h.QueueSourceInventory(1)
	if err != nil {
		t.Fatal(err)
	}
	if got.Versions[0].SourceSealInventory != "unrecorded" || got.Versions[1].SourceSealInventory != "unknown" || got.Versions[2].SourceSealInventory != "complete" {
		t.Fatal("source provenance upgraded", got)
	}
	got.Versions[0].Contracts[0].Payloads[0].Contract = "mutated"
	again, err := h.QueueSourceInventory(1)
	if err != nil || again.Versions[0].Contracts[0].Payloads[0].Contract == "mutated" {
		t.Fatal("mutable linked inventory", err)
	}
	if _, err := h.QueueSourceInventory(0); err == nil {
		t.Fatal("invalid origin accepted")
	}
	// Reading metadata cannot open a database or set any persisted installation capability.
	db := NewDatabase("Main", PostgresConfig{Schema: h.Namespace}, nil)
	RegisterDatabaseMigrationHistory(db, h.Family)
	if db.open != nil {
		t.Fatal("source inspection opened database")
	}
}
func TestQueueProjectionRejectsTamperedOrIncompleteEnvelope(t *testing.T) {
	changes := map[string]func(map[string]any){
		"missing inventories":          func(r map[string]any) { delete(queueProjectionDB(r), "versions") },
		"missing checked capability":   func(r map[string]any) { delete(queueProjectionVersion(r), "checkedInventory") },
		"unknown checked capability":   func(r map[string]any) { queueProjectionVersion(r)["checkedInventory"] = "unknown" },
		"missing provenance":           func(r map[string]any) { delete(queueProjectionVersion(r), "sourceSealInventory") },
		"invented persisted authority": func(r map[string]any) { queueProjectionVersion(r)["persistedBaselineComplete"] = true },
		"bad provenance":               func(r map[string]any) { queueProjectionVersion(r)["sourceSealInventory"] = "adopted" },
		"wrong ABI":                    func(r map[string]any) { r["compilerAbi"] = "another" },
		"wrong database":               func(r map[string]any) { queueProjectionDB(r)["database"] = "Another.Main" },
		"extra database":               func(r map[string]any) { r["databases"] = append(r["databases"].([]any), queueProjectionDB(r)) },
		"missing database":             func(r map[string]any) { r["databases"] = []any{} },
		"missing version":              func(r map[string]any) { d := queueProjectionDB(r); d["versions"] = d["versions"].([]any)[1:] },
		"version order":                func(r map[string]any) { vs := queueProjectionDB(r)["versions"].([]any); vs[0], vs[1] = vs[1], vs[0] },
		"duplicate queue": func(r map[string]any) {
			v := queueProjectionVersion(r)
			qs := v["contracts"].([]any)
			v["contracts"] = append(qs, qs[0])
		},
		"duplicate job": func(r map[string]any) {
			q := queueProjectionVersion(r)["contracts"].([]any)[0].(map[string]any)
			ps := q["payloads"].([]any)
			q["payloads"] = append(ps, ps[0])
		},
		"empty contract": func(r map[string]any) {
			queueProjectionVersion(r)["contracts"].([]any)[0].(map[string]any)["payloads"] = []any{}
		},
		"nonrelative job":  func(r map[string]any) { queueProjectionPayload(r)["job"] = "bad-id" },
		"contract tamper":  func(r map[string]any) { queueProjectionPayload(r)["contract"] = "00" },
		"bad hash":         func(r map[string]any) { queueProjectionPayload(r)["contractHash"] = strings.Repeat("0", 64) },
		"storage snapshot": func(r map[string]any) { queueProjectionVersion(r)["storageSnapshotHash"] = strings.Repeat("0", 64) },
		"missing origin":   func(r map[string]any) { d := queueProjectionDB(r); d["origins"] = d["origins"].([]any)[1:] },
		"cross origin reference": func(r map[string]any) {
			queueProjectionDB(r)["origins"].([]any)[1].(map[string]any)["versions"] = []int{1, 3}
		},
		"null inventory": func(r map[string]any) { queueProjectionVersion(r)["contracts"] = nil },
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			h, r := queueProjectionFixture(t)
			change(r)
			if _, err := pgReadQueueHistory(h, queueProjectionJSON(t, r), 3); err == nil {
				t.Fatal("malformed unselected history accepted")
			}
		})
	}
	t.Run("duplicate JSON key", func(t *testing.T) {
		h, r := queueProjectionFixture(t)
		payload := strings.Replace(queueProjectionJSON(t, r), `"checkedInventory":"complete"`, `"checkedInventory":"complete","checkedInventory":"complete"`, 1)
		if _, err := pgReadQueueHistory(h, payload, 1); err == nil {
			t.Fatal("duplicate key accepted")
		}
	})
	t.Run("rehashed malformed canonical", func(t *testing.T) {
		h, r := queueProjectionFixture(t)
		p := queueProjectionPayload(r)
		p["contract"] = "73313a78"
		p["contractHash"] = fmt.Sprintf("%x", sha256.Sum256([]byte("s1:x")))
		if _, err := pgReadQueueHistory(h, queueProjectionJSON(t, r), 1); err == nil {
			t.Fatal("non-contract node accepted")
		}
	})
}
func TestQueueProjectionPublicationIsAtomic(t *testing.T) {
	h, r := queueProjectionFixture(t)
	registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
	bad := queueProjectionJSON(t, r)
	bad = strings.Replace(bad, `"sourceSealInventory":"unknown"`, `"sourceSealInventory":"adopted"`, 1)
	migrationRegistrationPanics(t, func() { registerCompiledQueueHistory(bad) })
	if _, err := h.QueueSourceInventory(1); err == nil {
		t.Fatal("failed link partially published")
	}
	registerCompiledQueueHistory(queueProjectionJSON(t, r))
	var group sync.WaitGroup
	for range 20 {
		group.Go(func() {
			registerCompiledQueueHistory(queueProjectionJSON(t, r))
			if _, err := h.QueueSourceInventory(1); err != nil {
				t.Error(err)
			}
		})
	}
	group.Wait()
	before, err := h.QueueSourceInventory(1)
	if err != nil {
		t.Fatal(err)
	}
	queueProjectionVersion(r)["sourceSealInventory"] = "complete"
	migrationRegistrationPanics(t, func() { registerCompiledQueueHistory(queueProjectionJSON(t, r)) })
	after, err := h.QueueSourceInventory(1)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatal("conflicting registration changed source inventory", err)
	}
}
func TestQueueProjectionBindsActualCodecsWithoutChangingLegacyWire(t *testing.T) {
	h, r := queueProjectionFixture(t)
	registerQueueProjection(t, h, r)
	db := RegisterDatabaseIdentity(h.Database, NewDatabase("Main", PostgresConfig{Schema: h.Namespace}, nil))
	RegisterDatabaseMigrationHistory(db, h.Family)
	q := NewQueueOn(db, "AppBindingName", 3, "", 0)
	t.Cleanup(pubsubRuntimeOf(t, db).Close)
	t.Cleanup(func() { queueSchemaOwners.Lock(); delete(queueSchemaOwners.queues, db); queueSchemaOwners.Unlock() })
	if _, err := QueueSourceCodecs(q); err == nil {
		t.Fatal("unbound codec became complete")
	}
	RegisterQueueSchema(q, db, h.Family, "Notifications", 3)
	if _, err := QueueSourceCodecs(q); err == nil {
		t.Fatal("missing codec became complete")
	}
	other := NewDatabase("Other", PostgresConfig{Schema: h.Namespace}, nil)
	migrationRegistrationPanics(t, func() { RegisterQueueSchema(q, other, h.Family, "Notifications", 3) })
	migrationRegistrationPanics(t, func() { RegisterQueueSchema(NewQueueOn(other, "Other", 1, "", 0), other, h.Family, "Notifications", 3) })
	t.Cleanup(pubsubRuntimeOf(t, other).Close)
	migrationRegistrationPanics(t, func() { RegisterQueueSchema(NewQueueOn(db, "Duplicate", 1, "", 0), db, h.Family, "Notifications", 3) })
	encode := func(v any) any { return v }
	decode := func(v any) (any, error) { return v, nil }
	hash := queueProjectionPayload(r)["contractHash"].(string)
	for _, entry := range [][4]string{{"OtherSchema", "Notifications", "Notify", hash}, {h.Family, "OtherQueue", "Notify", hash}, {h.Family, "Notifications", "OtherJob", hash}, {h.Family, "Notifications", "Notify", strings.Repeat("0", 64)}} {
		migrationRegistrationPanics(t, func() {
			RegisterQueueSchemaJobCodec(q, entry[0], entry[1], entry[2], 3, entry[3], "Schema.Todo.VCurrent.Notify", encode, decode)
		})
	}
	RegisterQueueSchemaJobCodec(q, h.Family, "Notifications", "Notify", 3, hash, "Schema.Todo.VCurrent.Notify", encode, decode)
	migrationRegistrationPanics(t, func() {
		RegisterQueueSchemaJobCodec(q, h.Family, "Notifications", "Notify", 3, hash, "Schema.Todo.VCurrent.Notify", encode, decode)
	})
	migrationRegistrationPanics(t, func() { RegisterJobCodec(q, "Schema.Todo.VCurrent.Notify", encode, decode) })
	got, err := QueueSourceCodecs(q)
	if err != nil || len(got) != 1 || got[0].Job != "Notify" {
		t.Fatal(got, err)
	}
	backend := q.backend.(*pgQueueBackend)
	if backend.name != "AppBindingName" || backend.codecs[0].typeName != "Schema.Todo.VCurrent.Notify" {
		t.Fatal("legacy wire identity changed")
	}
	got[0].Job = "mutated"
	again, _ := QueueSourceCodecs(q)
	if again[0].Job != "Notify" {
		t.Fatal("metadata alias")
	}
	plainDB := NewDatabase("Plain", PostgresConfig{}, nil)
	plain := NewQueueOn(plainDB, "Legacy", 1, "", 0)
	t.Cleanup(pubsubRuntimeOf(t, plainDB).Close)
	RegisterJobCodec(plain, "PlainRecord", encode, decode)
	RegisterJobCodec(plain, "PlainRecord", encode, decode)
	RegisterJobCodec(NewQueue("Memory", 1), "Record", encode, decode)
	if plain.backend.(*pgQueueBackend).codecs[0].typeName != "PlainRecord" {
		t.Fatal("unversioned codec changed")
	}
}

func TestQueueProjectionChecksEveryLinkedDatabaseBeforePublication(t *testing.T) {
	h, root := queueProjectionFixture(t)
	second := h
	second.Database = "Other.Main"
	second.Family = "Other" + h.Family
	second.Namespace = "other"
	var expanded map[string]any
	if err := json.Unmarshal([]byte(h.HistoryJSON), &expanded); err != nil {
		t.Fatal(err)
	}
	original := expanded["databases"].([]any)[0]
	var extra map[string]any
	if err := json.Unmarshal([]byte(queueProjectionJSON(t, original)), &extra); err != nil {
		t.Fatal(err)
	}
	extra["database"], extra["family"], extra["namespace"] = second.Database, second.Family, second.Namespace
	expanded["databases"] = append(expanded["databases"].([]any), extra)
	h.HistoryJSON = queueProjectionJSON(t, expanded)
	second.HistoryJSON = h.HistoryJSON
	var queueExtra map[string]any
	if err := json.Unmarshal([]byte(queueProjectionJSON(t, queueProjectionDB(root))), &queueExtra); err != nil {
		t.Fatal(err)
	}
	queueExtra["database"], queueExtra["family"], queueExtra["namespace"] = second.Database, second.Family, second.Namespace
	root["databases"] = append(root["databases"].([]any), queueExtra)
	for _, history := range []PgCompiledMigrationHistory{h, second} {
		registerCompiledMigrationHistory(history.Database, history.Family, history.Namespace, history.CurrentVersion, history.SourceCompilerABI, history.StoredValueCompatibility, history.HistoryJSON)
	}
	t.Cleanup(func() {
		compiledMigrationHistories.Delete(second.Family)
		compiledQueueHistories.Lock()
		delete(compiledQueueHistories.families, second.Family)
		compiledQueueHistories.Unlock()
	})
	queueExtra["versions"].([]any)[0].(map[string]any)["checkedInventory"] = "unknown"
	migrationRegistrationPanics(t, func() { registerCompiledQueueHistory(queueProjectionJSON(t, root)) })
	for _, history := range []PgCompiledMigrationHistory{h, second} {
		if _, err := history.QueueSourceInventory(1); err == nil {
			t.Fatal("invalid second database partially published first")
		}
	}
	queueExtra["versions"].([]any)[0].(map[string]any)["checkedInventory"] = "complete"
	registerCompiledQueueHistory(queueProjectionJSON(t, root))
	for _, history := range []PgCompiledMigrationHistory{h, second} {
		got, err := history.QueueSourceInventory(2)
		if err != nil || got.Database != history.Database {
			t.Fatal(got, err)
		}
	}
	entries := root["databases"].([]any)
	entries[0], entries[1] = entries[1], entries[0]
	if _, err := pgReadQueueHistory(h, queueProjectionJSON(t, root), 1); err == nil {
		t.Fatal("database order changed")
	}
}
func TestQueueProjectionRefusesRehashedHistoricalPayloadChange(t *testing.T) {
	h, root := queueProjectionFixture(t)
	// Detach the fixture's shared payload map so only an old version changes.
	var independent map[string]any
	if err := json.Unmarshal([]byte(queueProjectionJSON(t, root)), &independent); err != nil {
		t.Fatal(err)
	}
	payload := queueProjectionPayload(independent)
	data, err := hex.DecodeString(payload["contract"].(string))
	if err != nil {
		t.Fatal(err)
	}
	changed := strings.Replace(string(data), "fixture", "mutated", 1)
	payload["contract"] = hex.EncodeToString([]byte(changed))
	payload["contractHash"] = fmt.Sprintf("%x", sha256.Sum256([]byte(changed)))
	if _, err := pgReadQueueHistory(h, queueProjectionJSON(t, independent), 3); err == nil {
		t.Fatal("rehashed incompatible old payload disappeared behind current origin")
	}
}
