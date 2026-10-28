package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"
)

// Structural reader fixtures, not a replacement for compiler-emitted native
// callback acceptance. Their semantic bodies deliberately contain no executable
// functions. Only the compiler artifact suite supplies a real typed callback.
func rowTestDoc(domain string, node pgRowCanonical) (string, string) {
	raw := []byte(pgRowEncode(pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom(domain), node)))
	return hex.EncodeToString(raw), fmt.Sprintf("%x", sha256.Sum256(raw))
}
func rowTestJSON(t *testing.T, v any) string {
	t.Helper()
	b, e := json.Marshal(v)
	if e != nil {
		t.Fatal(e)
	}
	return string(b)
}
func rowTestFixture(t *testing.T) (PgCompiledMigrationHistory, map[string]any, map[string]any) {
	t.Helper()
	h := PgCompiledMigrationHistory{Database: "App.Db" + fmt.Sprintf("%x", sha256.Sum256([]byte(t.Name()))), Family: fmt.Sprintf("Rows%xSchema", sha256.Sum256([]byte(t.Name()))), Namespace: "row_space", CurrentVersion: 2, SourceCompilerABI: pgTestSourceABI, StoredValueCompatibility: pgTestStoredValueCompatibility}
	atom, list := pgRowAtom, pgRowList
	ref := pgRowTypeReference(h.Family, "Note")
	body := list(atom("entity"), ref, atom("notes"), atom("id"), list(list(atom("field"), atom("id"), atom("fixture-int"), list(atom("none")), list(atom("none"))), list(atom("field"), atom("title"), atom("fixture-string"), list(atom("none")), list(atom("none")))), list())
	schema := list(atom("stored-value-semantics"), atom(h.StoredValueCompatibility), list(atom("closure"), list(ref), list(list(ref, body))))
	schemaHex, schemaHash := rowTestDoc("snapshot", schema)
	typeHex, typeHash := rowTestDoc("contract", schema)
	boolean := func(v bool) pgRowCanonical { return list(atom("bool"), atom(fmt.Sprint(v))) }
	storage := list(atom("postgres-storage-v1"), schema, list(list(atom("notes"), list(list(atom("id"), atom("numeric"), boolean(false), boolean(true)), list(atom("title"), atom("text"), boolean(false), boolean(false))), list())))
	storageHex, storageHash := rowTestDoc("migration", storage)
	columns := func() []any {
		return []any{map[string]any{"field": "id", "name": "id", "type": "numeric", "nullable": false, "primaryKey": true}, map[string]any{"field": "title", "name": "title", "type": "text", "nullable": false, "primaryKey": false}}
	}
	versions, origins := []any{}, []any{}
	for v := 1; v <= 2; v++ {
		versions = append(versions, map[string]any{"version": v, "schemaContract": schemaHex, "schemaSnapshotHash": schemaHash, "storageContract": storageHex, "storageSnapshotHash": storageHash, "entities": []any{map[string]any{"entity": "Note", "table": "notes", "generation": v, "typeContract": typeHex, "typeContractHash": typeHash, "goTypePackage": fmt.Sprintf("tesl.generated/schema_v%d", v), "goTypeName": "Note", "columns": columns()}}})
		origins = append(origins, map[string]any{"initialVersion": v, "steps": nil, "errors": []any{map[string]any{"code": "MIG016", "message": "row execution unavailable"}}})
	}
	baseDB := map[string]any{"database": h.Database, "family": h.Family, "namespace": h.Namespace, "currentVersion": 2, "versions": versions, "origins": origins}
	base := map[string]any{"version": 4, "kind": "compiled-migration-source-history", "compilerAbi": h.SourceCompilerABI, "storedValueCompatibility": h.StoredValueCompatibility, "databases": []any{baseDB}}
	from, to := pgRowTypeReference(h.Family, "Note"), pgRowTypeReference(h.Family, "Note")
	from.children[2].children[2] = atom("from")
	to.children[2].children[2] = atom("to")
	mapping := list(list(atom("computed"), atom("title")), list(atom("copy"), atom("id"), atom("id")))
	typeRoots := []pgRowCanonical{from, to}
	typeDefs := []pgRowCanonical{pgRowProjectRole(list(ref, body), h.Family, "from"), pgRowProjectRole(list(ref, body), h.Family, "to")}
	slices.SortFunc(typeRoots, func(a, b pgRowCanonical) int { return strings.Compare(pgRowEncode(a), pgRowEncode(b)) })
	slices.SortFunc(typeDefs, func(a, b pgRowCanonical) int { return strings.Compare(pgRowEncode(a), pgRowEncode(b)) })
	linkedTypes := list(atom("closure"), list(typeRoots...), list(typeDefs...))
	row := list(atom("entity-transform"), from, to, linkedTypes, mapping, boolean(false), list(atom("migrate"), list()), list())
	link := list(atom("checked-transform-link"), atom("1"), list(atom("compiler-abi"), atom(h.SourceCompilerABI)), list(row), list())
	linkHex, linkHash := rowTestDoc("migration", link)
	descriptor := map[string]any{"migrationVersion": 2, "entity": "Note", "table": "notes", "mode": "migrate", "previousGeneration": 1, "targetGeneration": 2, "fromSchemaSnapshot": schemaHash, "toSchemaSnapshot": schemaHash, "fromStorageSnapshot": storageHash, "toStorageSnapshot": storageHash, "fromTypeContractHash": typeHash, "toTypeContractHash": typeHash, "sourceSchemaColumns": columns(), "targetSchemaColumns": columns(), "fieldMapping": []any{map[string]any{"target": "id", "kind": "copy", "source": "id", "constant": nil}, map[string]any{"target": "title", "kind": "computed", "source": nil, "constant": nil}}, "transformContractFormat": "tesl-row-transform-v1", "transformContract": linkHex, "transformContractHash": linkHash}
	companion := map[string]any{"version": 1, "kind": "compiled-row-transform-history", "compilerAbi": h.SourceCompilerABI, "storedValueCompatibility": h.StoredValueCompatibility, "databases": []any{map[string]any{"database": h.Database, "family": h.Family, "namespace": h.Namespace, "currentVersion": 2, "transforms": []any{descriptor}}}}
	h.HistoryJSON = rowTestJSON(t, base)
	t.Cleanup(func() {
		pgMigrationRegistrations.Lock()
		defer pgMigrationRegistrations.Unlock()
		delete(compiledRowRegistrations, compiledRowHistories[h.Family])
		delete(compiledRowHistories, h.Family)
		delete(pgMigrationClosedFamilies, h.Family)
		compiledMigrationHistories.Delete(h.Family)
		databaseIdentities.Delete(h.Database)
	})
	return h, base, companion
}
func rowTestDB(root map[string]any) map[string]any {
	return root["databases"].([]any)[0].(map[string]any)
}
func rowTestVersion(root map[string]any, v int) map[string]any {
	return rowTestDB(root)["versions"].([]any)[v-1].(map[string]any)
}
func rowTestEntity(root map[string]any, v int) map[string]any {
	return rowTestVersion(root, v)["entities"].([]any)[0].(map[string]any)
}
func rowTestTransform(root map[string]any) map[string]any {
	return rowTestDB(root)["transforms"].([]any)[0].(map[string]any)
}
func rowTestRegister(t *testing.T, h PgCompiledMigrationHistory, companion map[string]any) *Database {
	t.Helper()
	registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
	registerCompiledRowHistory(rowTestJSON(t, companion))
	return RegisterDatabaseMigrationHistory(RegisterDatabaseIdentity(h.Database, NewDatabase("Rows", PostgresConfig{Schema: h.Namespace}, nil)), h.Family)
}
func TestRowSourceReaderAndNoExecutionAuthority(t *testing.T) {
	h, _, companion := rowTestFixture(t)
	parsed, err := pgReadRowCompanion(h, rowTestJSON(t, companion))
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed) != 1 || len(parsed[0].Versions) != 2 || len(parsed[0].Transforms) != 1 {
		t.Fatal("lost source inventory")
	}
	for _, origin := range []int{1, 2} {
		if _, err := h.ExpansionPlan(origin); err == nil {
			t.Fatal("source-only envelope authorized expansion")
		}
	}
	db := rowTestRegister(t, h, companion)
	if err := PreflightApplicationDatabases(db); err == nil || !strings.Contains(err.Error(), "incomplete") {
		t.Fatal("missing typed callback was accepted", err)
	}
	if db.applicationPreflightClosed {
		t.Fatal("failed preflight sealed database")
	}
	ref := LookupCompiledRowTransform(db, h.Family, 2, "Note")
	migrationRegistrationPanics(t, func() {
		RegisterCompiledRowTransform[struct{}, struct{}](ref, func(v struct{}) Migrated[struct{}] { return Migrated[struct{}]{Tag: MigratedRow} })
	})
	migrationRegistrationPanics(t, func() { RegisterCompiledRowTransform[struct{}, struct{}](PgRowTransformSourceRef{}, nil) })
	var zero *PgRowTransform[struct{}, struct{}]
	if _, err := zero.Run(struct{}{}); err == nil {
		t.Fatal("zero callback ran")
	}
	inventory, err := h.RowSourceInventory()
	if err != nil {
		t.Fatal(err)
	}
	inventory.Versions[0].Entities[0].Columns[0].Name = "changed"
	*inventory.Transforms[0].FieldMapping[0].Source = "changed"
	inventory.Transforms[0].SourceSchemaColumns[0].Name = "changed"
	again, err := h.RowSourceInventory()
	if err != nil || again.Versions[0].Entities[0].Columns[0].Name != "id" || *again.Transforms[0].FieldMapping[0].Source != "id" || again.Transforms[0].SourceSchemaColumns[0].Name != "id" {
		t.Fatal("inspection leaked mutable state", err)
	}
	migrationRegistrationPanics(t, func() {
		LookupCompiledRowTransform(NewDatabase("Other", PostgresConfig{Schema: h.Namespace}, nil), h.Family, 2, "Note")
	})
	migrationRegistrationPanics(t, func() { LookupCompiledRowTransform(db, h.Family, 2, "Other") })
}
func TestRowSourceReaderRejectsTampering(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(map[string]any, map[string]any)
	}{
		{"unknown base", func(b, c map[string]any) { b["extra"] = true }},
		{"unknown companion", func(b, c map[string]any) { c["extra"] = true }},
		{"legacy base", func(b, c map[string]any) { b["version"] = 3 }},
		{"changed abi", func(b, c map[string]any) { c["compilerAbi"] = "wrong" }},
		{"missing database", func(b, c map[string]any) { c["databases"] = []any{} }},
		{"wrong namespace", func(b, c map[string]any) { rowTestDB(c)["namespace"] = "other" }},
		{"missing version", func(b, c map[string]any) { rowTestDB(b)["versions"] = rowTestDB(b)["versions"].([]any)[:1] }},
		{"version gap", func(b, c map[string]any) { rowTestVersion(b, 2)["version"] = 3 }},
		{"missing origin", func(b, c map[string]any) { rowTestDB(b)["origins"] = []any{} }},
		{"refused origin steps", func(b, c map[string]any) { rowTestDB(b)["origins"].([]any)[0].(map[string]any)["steps"] = []any{} }},
		{"generation jump", func(b, c map[string]any) { rowTestEntity(b, 2)["generation"] = 3 }},
		{"generation reset", func(b, c map[string]any) { rowTestEntity(b, 1)["generation"] = 2 }},
		{"missing transform", func(b, c map[string]any) { rowTestDB(c)["transforms"] = []any{} }},
		{"duplicate transform", func(b, c map[string]any) {
			rowTestDB(c)["transforms"] = []any{rowTestTransform(c), rowTestTransform(c)}
		}},
		{"wrong entity", func(b, c map[string]any) { rowTestTransform(c)["entity"] = "Other" }},
		{"derived refuses", func(b, c map[string]any) { rowTestTransform(c)["mode"] = "derived" }},
		{"wrong generation", func(b, c map[string]any) { rowTestTransform(c)["previousGeneration"] = 2 }},
		{"wrong snapshot", func(b, c map[string]any) { rowTestTransform(c)["toSchemaSnapshot"] = strings.Repeat("a", 64) }},
		{"wrong storage", func(b, c map[string]any) { rowTestTransform(c)["fromStorageSnapshot"] = strings.Repeat("a", 64) }},
		{"wrong type", func(b, c map[string]any) { rowTestTransform(c)["toTypeContractHash"] = strings.Repeat("a", 64) }},
		{"wrong link", func(b, c map[string]any) { rowTestTransform(c)["transformContractHash"] = strings.Repeat("a", 64) }},
		{"missing mapping", func(b, c map[string]any) { rowTestTransform(c)["fieldMapping"] = []any{} }},
		{"semantic mapping substitution", func(b, c map[string]any) {
			m := rowTestTransform(c)["fieldMapping"].([]any)[1].(map[string]any)
			m["kind"] = "copy"
			m["source"] = "title"
		}},
		{"invalid optional", func(b, c map[string]any) {
			rowTestTransform(c)["fieldMapping"].([]any)[1].(map[string]any)["kind"] = "empty-optional"
		}},
		{"wrong source projection", func(b, c map[string]any) {
			rowTestTransform(c)["sourceSchemaColumns"].([]any)[1].(map[string]any)["name"] = "wrong"
		}},
		{"reserved column", func(b, c map[string]any) {
			rowTestEntity(b, 1)["columns"].([]any)[0].(map[string]any)["name"] = "_tesl_v"
		}},
		{"missing schema entity", func(b, c map[string]any) { rowTestVersion(b, 1)["entities"] = []any{} }},
		{"wrong nominal package", func(b, c map[string]any) { rowTestEntity(b, 1)["goTypePackage"] = "user/arbitrary" }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			h, b, c := rowTestFixture(t)
			test.mutate(b, c)
			h.HistoryJSON = rowTestJSON(t, b)
			if _, err := pgReadRowCompanion(h, rowTestJSON(t, c)); err == nil {
				t.Fatal("tampered source metadata accepted")
			}
		})
	}
}
func TestRowTypeContractRootSubstitution(t *testing.T) {
	for _, kind := range []string{"other entity", "other family", "changed definition"} {
		t.Run(kind, func(t *testing.T) {
			h, b, c := rowTestFixture(t)
			e := rowTestEntity(b, 1)
			node, _, err := pgReadRowCanonical(e["typeContract"].(string))
			if err != nil {
				t.Fatal(err)
			}
			payload := node.children[3]
			closure := &payload.children[2]
			if kind == "changed definition" {
				closure.children[2].children[0].children[1].children[4].children[1].children[2] = pgRowAtom("different-type")
			} else {
				family, entity := h.Family, "Note"
				if kind == "other family" {
					family = "OtherSchema"
				} else {
					entity = "Other"
				}
				ref := pgRowTypeReference(family, entity)
				closure.children[1].children[0] = ref
				closure.children[2].children[0].children[0] = ref
				closure.children[2].children[0].children[1].children[1] = ref
			}
			e["typeContract"], e["typeContractHash"] = rowTestDoc("contract", payload)
			rowTestTransform(c)["fromTypeContractHash"] = e["typeContractHash"]
			h.HistoryJSON = rowTestJSON(t, b)
			if _, err := pgReadRowBase(h); err == nil {
				t.Fatal("base source reader accepted substituted canonical type root/definition")
			}
			if _, err := pgReadRowCompanion(h, rowTestJSON(t, c)); err == nil {
				t.Fatal("valid differently owned canonical contract was accepted")
			}
		})
	}
}
func TestRowCanonicalFraming(t *testing.T) {
	for _, raw := range []string{"", "s0", "s01:x", "s1:", "s0:extra", "l1:", "l999999999999999999999999:", "s999999999999999999999999:", "q0:", strings.Repeat("l1:", 514) + "s0:"} {
		if _, _, err := pgReadRowCanonical(hex.EncodeToString([]byte(raw))); err == nil {
			t.Fatalf("invalid canonical accepted: %.30s", raw)
		}
	}
	for _, raw := range []string{"s0:", "l0:", "s3:abc", "l2:s0:s3:abc", "s1:\xff"} {
		if _, _, err := pgReadRowCanonical(hex.EncodeToString([]byte(raw))); err != nil {
			t.Fatalf("valid canonical rejected: %q %v", raw, err)
		}
	}
	if _, _, err := pgReadRowCanonical("6C303A"); err == nil {
		t.Fatal("uppercase hex accepted")
	}
}
func TestRowCompanionRegistrationAtomicAndConcurrent(t *testing.T) {
	h, _, c := rowTestFixture(t)
	registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
	original := rowTestJSON(t, c)
	rowTestDB(c)["transforms"] = []any{}
	migrationRegistrationPanics(t, func() { registerCompiledRowHistory(rowTestJSON(t, c)) })
	if compiledRowHistories[h.Family] != nil {
		t.Fatal("failed companion registration published partial state")
	}
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() { registerCompiledRowHistory(original) })
	}
	wg.Wait()
	if compiledRowHistories[h.Family] == nil {
		t.Fatal("concurrent identical registration lost history")
	}
}

func TestRowColumnLogicalPhysicalBinding(t *testing.T) {
	for name, want := range map[string]string{"givenName": "given_name", "familyName": "family_name", "userID": "user_id", "userId": "user_id", "HTTPServer": "http_server", "item2ID": "item2_id", "already_named": "already_named"} {
		if got := pgRowSQLColumnName(name); got != want {
			t.Fatalf("%s -> %s, want %s", name, got, want)
		}
	}
	// Both swapped labels are real, non-key string fields. The canonical SQL
	// column list is unchanged: only the claimed logical-to-physical map changed.
	raw := `[{"field":"givenName","name":"family_name","type":"text","nullable":false,"primaryKey":false},{"field":"familyName","name":"given_name","type":"text","nullable":false,"primaryKey":false},{"field":"id","name":"id","type":"numeric","nullable":false,"primaryKey":true}]`
	correct := strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(raw, `"field":"givenName"`, `"field":"TEMP"`), `"field":"familyName"`, `"field":"givenName"`), `"field":"TEMP"`, `"field":"familyName"`)
	positive := &pgMigrationWireReader{}
	pgRowColumns(positive, json.RawMessage(correct))
	if positive.err != nil {
		t.Fatal("correct sorted same-carrier columns refused", positive.err)
	}
	r := &pgMigrationWireReader{}
	pgRowColumns(r, json.RawMessage(raw))
	if r.err == nil {
		t.Fatal("swapped same-carrier fields accepted")
	}
}
func TestRowApplicationBatchDoesNotPartiallySeal(t *testing.T) {
	var ready, missing *Database
	var readyHistory PgCompiledMigrationHistory
	var readyCompanion map[string]any

	h, b, c := rowTestFixture(t)
	rowTestEntity(b, 2)["generation"] = 1
	rowTestDB(c)["transforms"] = []any{}
	h.HistoryJSON = rowTestJSON(t, b)
	ready = rowTestRegister(t, h, c)
	readyHistory, readyCompanion = h, c
	// A second exact source family with a missing callback must fail the whole
	// batch, including the otherwise complete first family's zero-callback case.
	t.Run("second family", func(t *testing.T) {
		h, _, c := rowTestFixture(t)
		missing = rowTestRegister(t, h, c)
		if err := PreflightApplicationDatabases(ready, missing); err == nil {
			t.Fatal("incomplete batch passed")
		}
		if ready.applicationPreflightClosed || missing.applicationPreflightClosed || pgMigrationClosedFamilies[readyHistory.Family] {
			t.Fatal("failed batch partially sealed")
		}
	})
	if err := PreflightApplicationDatabases(ready); err != nil {
		t.Fatal(err)
	}
	if !ready.applicationPreflightClosed {
		t.Fatal("complete metadata family was not sealed")
	}
	migrationRegistrationPanics(t, func() { registerCompiledRowHistory(rowTestJSON(t, readyCompanion)) })
}
func TestRowBaseWithoutCompanionRefusesPreflight(t *testing.T) {
	h, _, _ := rowTestFixture(t)
	registerCompiledMigrationHistory(h.Database, h.Family, h.Namespace, h.CurrentVersion, h.SourceCompilerABI, h.StoredValueCompatibility, h.HistoryJSON)
	db := RegisterDatabaseMigrationHistory(RegisterDatabaseIdentity(h.Database, NewDatabase("Rows", PostgresConfig{Schema: h.Namespace}, nil)), h.Family)
	if err := PreflightApplicationDatabases(db); err == nil || !strings.Contains(err.Error(), "missing compiled row") {
		t.Fatal("source history without companion passed", err)
	}
	if db.applicationPreflightClosed {
		t.Fatal("missing metadata closed registration")
	}
}

func TestRowSemanticLinkTypeSubstitution(t *testing.T) {
	for _, kind := range []string{"field proof", "field type", "missing closure", "different root", "swapped roles"} {
		t.Run(kind, func(t *testing.T) {
			h, _, c := rowTestFixture(t)
			d := rowTestTransform(c)
			node, _, err := pgReadRowCanonical(d["transformContract"].(string))
			if err != nil {
				t.Fatal(err)
			}
			link := node.children[3]
			types := &link.children[3].children[0].children[3]
			switch kind {
			case "field proof":
				types.children[2].children[0].children[1].children[4].children[1].children[3] = pgRowList(pgRowAtom("some"), pgRowAtom("changed-proof-semantics"))
			case "field type":
				types.children[2].children[0].children[1].children[4].children[1].children[2] = pgRowAtom("same-carrier-different-type")
			case "missing closure":
				*types = pgRowList()
			case "swapped roles":
				types.children[2].children[0].children[1].children[1], types.children[2].children[1].children[1].children[1] = types.children[2].children[1].children[1].children[1], types.children[2].children[0].children[1].children[1]
			case "different root":
				types.children[1].children[0] = pgRowTypeReference("OtherSchema", "Note")
			}
			d["transformContract"], d["transformContractHash"] = rowTestDoc("migration", link)
			if _, err := pgReadRowCompanion(h, rowTestJSON(t, c)); err == nil {
				t.Fatal("same-shaped alternative type contract link accepted")
			}
		})
	}
}
