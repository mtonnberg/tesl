package teslrt

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// lazyHistoryFixture builds a valid linked source history of n versions that
// all keep one unchanged entity, plus an empty row transform companion. Each
// version carries its own complete schema and storage documents, so the linked
// bytes grow with n like a real application's history.
func lazyHistoryFixture(t testing.TB, n int) (PgCompiledMigrationHistory, map[string]any, map[string]any) {
	t.Helper()
	name := fmt.Sprintf("%s/%d", t.Name(), n)
	h := PgCompiledMigrationHistory{Database: "App.Lazy" + fmt.Sprintf("%x", sha256.Sum256([]byte(name)))[:16], Family: "Lazy" + fmt.Sprintf("%x", sha256.Sum256([]byte(name)))[:16] + "Schema", Namespace: "lazy_space", CurrentVersion: n, SourceCompilerABI: pgTestSourceABI, StoredValueCompatibility: pgTestStoredValueCompatibility}
	atom, list := pgRowAtom, pgRowList
	ref := pgRowTypeReference(h.Family, "Note")
	body := list(atom("entity"), ref, atom("notes"), atom("id"), list(list(atom("field"), atom("id"), atom("fixture-int"), list(atom("none")), list(atom("none"))), list(atom("field"), atom("title"), atom("fixture-string"), list(atom("none")), list(atom("none")))), list())
	schema := list(atom("stored-value-semantics"), atom(h.StoredValueCompatibility), list(atom("closure"), list(ref), list(list(ref, body))))
	schemaHex, schemaHash := rowTestDoc("snapshot", schema)
	typeHex, typeHash := rowTestDoc("contract", schema)
	boolean := func(v bool) pgRowCanonical { return list(atom("bool"), atom(fmt.Sprint(v))) }
	storage := list(atom("postgres-storage-v1"), schema, list(list(atom("notes"), list(list(atom("id"), atom("numeric"), boolean(false), boolean(true)), list(atom("title"), atom("text"), boolean(false), boolean(false))), list())))
	storageHex, storageHash := rowTestDoc("migration", storage)
	versions, origins := []any{}, []any{}
	for v := 1; v <= n; v++ {
		columns := []any{map[string]any{"field": "id", "name": "id", "type": "numeric", "nullable": false, "primaryKey": true}, map[string]any{"field": "title", "name": "title", "type": "text", "nullable": false, "primaryKey": false}}
		versions = append(versions, map[string]any{"version": v, "schemaContract": schemaHex, "schemaSnapshotHash": schemaHash, "storageContract": storageHex, "storageSnapshotHash": storageHash, "entities": []any{map[string]any{"entity": "Note", "table": "notes", "generation": 1, "typeContract": typeHex, "typeContractHash": typeHash, "goTypePackage": "tesl.generated/lazy_schema", "goTypeName": "Note", "columns": columns}}})
		origins = append(origins, map[string]any{"initialVersion": v, "steps": nil, "errors": []any{map[string]any{"code": "MIG016", "message": "row execution unavailable"}}})
	}
	base := map[string]any{"version": 4, "kind": "compiled-migration-source-history", "compilerAbi": h.SourceCompilerABI, "storedValueCompatibility": h.StoredValueCompatibility, "databases": []any{map[string]any{"database": h.Database, "family": h.Family, "namespace": h.Namespace, "currentVersion": n, "versions": versions, "origins": origins}}}
	companion := map[string]any{"version": 1, "kind": "compiled-row-transform-history", "compilerAbi": h.SourceCompilerABI, "storedValueCompatibility": h.StoredValueCompatibility, "databases": []any{map[string]any{"database": h.Database, "family": h.Family, "namespace": h.Namespace, "currentVersion": n, "transforms": []any{}}}}
	h.HistoryJSON = lazyHistoryJSON(t, base)
	t.Cleanup(func() { lazyHistoryForget(h) })
	return h, base, companion
}

func lazyHistoryJSON(t testing.TB, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return pgTestCompactHistoryJSON(t, string(b))
}

func lazyHistoryForget(h PgCompiledMigrationHistory) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	delete(compiledRowRegistrations, compiledRowHistories[h.Family])
	delete(compiledRowHistories, h.Family)
	delete(pgMigrationClosedFamilies, h.Family)
	compiledMigrationHistories.Delete(h.Family)
	databaseIdentities.Delete(h.Database)
	pgLinkedSources.Lock()
	delete(pgLinkedSources.families, h.Family)
	pgLinkedSources.Unlock()
}

func lazyHistoryRegister(t testing.TB, h PgCompiledMigrationHistory, companion map[string]any) *Database {
	t.Helper()
	registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
	registerCompiledRowHistory(lazyHistoryJSON(t, companion))
	return RegisterDatabaseMigrationHistory(RegisterDatabaseIdentity(h.Database, NewDatabase("Lazy", PostgresConfig{Schema: h.Namespace}, nil)), h.Family)
}

type lazyHistoryCost struct{ complete, elements int64 }

func lazyHistoryCounters() lazyHistoryCost {
	return lazyHistoryCost{pgHistoryCounters.complete.Load(), pgHistoryCounters.elements.Load()}
}

// Registration plus every read a serving process makes must not depend on how
// many releases the linked history contains. Operation counts, not wall time,
// carry the assertion; the benchmark below reports the time.
func TestLazyHistoryServingStartIsBoundedByTheWindow(t *testing.T) {
	serve := func(n int) lazyHistoryCost {
		h, _, companion := lazyHistoryFixture(t, n)
		before := lazyHistoryCounters()
		lazyHistoryRegister(t, h, companion)
		pgMigrationRegistrations.Lock()
		compiled := compiledRowHistories[h.Family]
		pgMigrationRegistrations.Unlock()
		for _, k := range []int{1, n - 1, n} {
			if v, err := compiled.version(k); err != nil || v.Version != k {
				t.Fatalf("window version V%d: %v", k, err)
			}
		}
		after := lazyHistoryCounters()
		return lazyHistoryCost{after.complete - before.complete, after.elements - before.elements}
	}
	small, large := serve(10), serve(200)
	if small.complete != 0 || large.complete != 0 {
		t.Fatalf("serving start validated a complete history: %+v %+v", small, large)
	}
	if small.elements != large.elements || large.elements > 3 {
		t.Fatalf("serving start work grows with releases: V10 %+v, V200 %+v", small, large)
	}
}

// A history inside the window is validated completely at registration, so
// small histories keep their full registration-time refusal.
func TestLazyHistorySmallHistoryIsValidatedCompletelyAtRegistration(t *testing.T) {
	h, base, companion := lazyHistoryFixture(t, 3)
	rowTestDB(base)["origins"].([]any)[1].(map[string]any)["steps"] = []any{}
	h.HistoryJSON = lazyHistoryJSON(t, base)
	registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
	failed := false
	func() {
		defer func() { failed = recover() != nil }()
		registerCompiledRowHistory(lazyHistoryJSON(t, companion))
	}()
	pgMigrationRegistrations.Lock()
	published := compiledRowHistories[h.Family] != nil
	pgMigrationRegistrations.Unlock()
	if !failed || published {
		t.Fatal("small history with an invalid origin was registered")
	}
}

// An error in a version the serving process reads fails at registration,
// before anything is published.
func TestLazyHistoryWindowErrorFailsAtRegistration(t *testing.T) {
	for _, k := range []func(int) int{func(int) int { return 1 }, func(n int) int { return n - 1 }, func(n int) int { return n }} {
		const n = 12
		version := k(n)
		t.Run(fmt.Sprintf("V%d", version), func(t *testing.T) {
			h, base, companion := lazyHistoryFixture(t, n)
			rowTestVersion(base, version)["schemaSnapshotHash"] = strings.Repeat("a", 64)
			h.HistoryJSON = lazyHistoryJSON(t, base)
			registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
			failed := false
			func() {
				defer func() { failed = recover() != nil }()
				registerCompiledRowHistory(lazyHistoryJSON(t, companion))
			}()
			pgMigrationRegistrations.Lock()
			published := compiledRowHistories[h.Family] != nil
			pgMigrationRegistrations.Unlock()
			if !failed || published {
				t.Fatalf("invalid serving version V%d was registered", version)
			}
		})
	}
}

// Integrity and identity cover the whole document at registration even though
// the historical versions are not decoded.
func TestLazyHistoryIntegrityAndIdentityFailAtRegistration(t *testing.T) {
	tests := map[string]func(t *testing.T, h *PgCompiledMigrationHistory, base, companion map[string]any){
		"truncated document": func(t *testing.T, h *PgCompiledMigrationHistory, base, companion map[string]any) {
			h.HistoryJSON = h.HistoryJSON[:len(h.HistoryJSON)-1]
		},
		"invalid UTF-8 in a historical version": func(t *testing.T, h *PgCompiledMigrationHistory, base, companion map[string]any) {
			h.HistoryJSON = strings.Replace(h.HistoryJSON, `"goTypeName":"Note"`, "\"goTypeName\":\"N\xffte\"", 1)
		},
		"missing version": func(t *testing.T, h *PgCompiledMigrationHistory, base, companion map[string]any) {
			db := rowTestDB(base)
			db["versions"] = db["versions"].([]any)[:11]
			h.HistoryJSON = lazyHistoryJSON(t, base)
		},
		"companion database identity": func(t *testing.T, h *PgCompiledMigrationHistory, base, companion map[string]any) {
			rowTestDB(companion)["namespace"] = "other"
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			h, base, companion := lazyHistoryFixture(t, 12)
			mutate(t, &h, base, companion)
			registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
			failed := false
			func() {
				defer func() { failed = recover() != nil }()
				registerCompiledRowHistory(lazyHistoryJSON(t, companion))
			}()
			if !failed {
				t.Fatal("registration accepted a damaged linked history")
			}
		})
	}
}

// An error in a version only replay needs is not read by a serving process;
// it fails the complete validation that every schema command runs first, and
// any reader that asks for that version.
func TestLazyHistoryHistoricalErrorFailsInSchemaCommand(t *testing.T) {
	const n = 12
	h, base, companion := lazyHistoryFixture(t, n)
	rowTestVersion(base, 5)["schemaSnapshotHash"] = strings.Repeat("a", 64)
	h.HistoryJSON = lazyHistoryJSON(t, base)
	database := lazyHistoryRegister(t, h, companion)
	pgMigrationRegistrations.Lock()
	compiled := compiledRowHistories[h.Family]
	pgMigrationRegistrations.Unlock()
	if compiled == nil {
		t.Fatal("history with a damaged historical version was not registered")
	}
	if _, err := compiled.version(n); err != nil {
		t.Fatal("serving version became unreadable:", err)
	}
	if err := pgValidateCompleteHistory(database); err == nil {
		t.Fatal("complete validation accepted a damaged historical version")
	}
	if _, err := compiled.version(5); err == nil {
		t.Fatal("damaged historical version was returned")
	}
	if _, err := compiled.version(4); err == nil {
		t.Fatal("historical read did not require the complete history")
	}
	if _, err := h.RowSourceInventory(); err == nil {
		t.Fatal("complete inventory accessor accepted a damaged history")
	}
}

// The complete validation runs once per process and is shared by every reader.
func TestLazyHistoryCompleteValidationRunsOnce(t *testing.T) {
	h, _, companion := lazyHistoryFixture(t, 12)
	database := lazyHistoryRegister(t, h, companion)
	before := lazyHistoryCounters()
	for i := 0; i < 3; i++ {
		if err := pgValidateCompleteHistory(database); err != nil {
			t.Fatal(err)
		}
		if _, err := pgReadRowBase(h); err != nil {
			t.Fatal(err)
		}
		if _, err := h.RowSourceInventory(); err != nil {
			t.Fatal(err)
		}
	}
	// One source decode and one row companion validation.
	if got := lazyHistoryCounters().complete - before.complete; got != 2 {
		t.Fatalf("complete validations = %d, want 2", got)
	}
	first, _ := h.RowSourceInventory()
	first.Versions[0].Entities[0].Columns[0].Name = "changed"
	second, _ := h.RowSourceInventory()
	if second.Versions[0].Entities[0].Columns[0].Name != "id" {
		t.Fatal("caller mutation reached the shared decoded history")
	}
}

func BenchmarkLazyHistoryServingStart(b *testing.B) {
	for _, n := range []int{10, 200} {
		b.Run(fmt.Sprintf("versions=%d", n), func(b *testing.B) {
			h, _, companion := lazyHistoryFixture(b, n)
			payload := lazyHistoryJSON(b, companion)
			b.SetBytes(int64(len(h.HistoryJSON)))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
				registerCompiledRowHistory(payload)
				b.StopTimer()
				lazyHistoryForget(h)
				b.StartTimer()
			}
		})
	}
}
