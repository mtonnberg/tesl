//go:build tesl_migration_test

package teslrt

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// Exercise actual compiler metadata, including a coherently rehashed loss of a
// payload codec. Valid hashes and an exact source/companion match are necessary
// but must not substitute for equality with the historical payload contract.
func TestPgRowTableDropCompiledQueueSource(t *testing.T) {
	root := os.Getenv("TESL_ROW_TABLE_DROP_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated table Drop applications required")
	}
	read := func(name string) []byte {
		t.Helper()
		b, err := os.ReadFile(filepath.Join(root, "v2", name))
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	generated, err := parser.ParseFile(token.NewFileSet(), "generated.go", read("internal/teslrt/migration_history_generated.go"), 0)
	if err != nil {
		t.Fatal(err)
	}
	queueJSON := ""
	ast.Inspect(generated, func(n ast.Node) bool {
		if spec, ok := n.(*ast.ValueSpec); ok && len(spec.Names) == 1 && spec.Names[0].Name == "teslGeneratedQueueHistoryJSON" {
			literal, ok := spec.Values[0].(*ast.BasicLit)
			if !ok {
				t.Fatal("queue history is not a literal")
			}
			queueJSON, err = strconv.Unquote(literal.Value)
			if err != nil {
				t.Fatal(err)
			}
		}
		return true
	})
	for _, loss := range []bool{false, true} {
		source, companion := map[string]any{}, map[string]any{}
		if err := json.Unmarshal(read("migration-source-history.json"), &source); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal([]byte(queueJSON), &companion); err != nil {
			t.Fatal(err)
		}
		db := rowTestDB(source)
		h := PgCompiledMigrationHistory{Database: db["database"].(string), Family: db["family"].(string), Namespace: db["namespace"].(string), CurrentVersion: int(db["currentVersion"].(float64)), SourceCompilerABI: source["compilerAbi"].(string), StoredValueCompatibility: source["storedValueCompatibility"].(string)}
		if loss {
			v := db["versions"].([]any)[1].(map[string]any)
			qv := rowTestDB(companion)["versions"].([]any)[1].(map[string]any)
			payload := qv["contracts"].([]any)[0].(map[string]any)["payloads"].([]any)[0].(map[string]any)
			r := &pgMigrationWireReader{}
			contract := pgRowDocument(r, payload["contract"].(string), payload["contractHash"].(string), "contract")
			closure := &contract.children[1].children[2]
			removed := map[string]bool{}
			closure.children[2].children = slices.DeleteFunc(closure.children[2].children, func(d pgRowCanonical) bool {
				ref := d.children[0]
				if ref.list(3) && ref.children[1].isAtom("codec") {
					removed[pgRowEncode(ref)] = true
					return true
				}
				return false
			})
			if len(removed) == 0 {
				t.Fatal("compiled payload omitted its codec dependency")
			}
			payload["contract"], payload["contractHash"] = rowTestDoc("contract", contract)
			schema := pgRowDocument(r, v["schemaContract"].(string), v["schemaSnapshotHash"].(string), "snapshot")
			schema.children[2].children[1].children = slices.DeleteFunc(schema.children[2].children[1].children, func(n pgRowCanonical) bool { return removed[pgRowEncode(n)] })
			schema.children[2].children[2].children = slices.DeleteFunc(schema.children[2].children[2].children, func(n pgRowCanonical) bool { return removed[pgRowEncode(n.children[0])] })
			v["schemaContract"], v["schemaSnapshotHash"] = rowTestDoc("snapshot", schema)
			storage := pgRowDocument(r, v["storageContract"].(string), v["storageSnapshotHash"].(string), "migration")
			storage.children[1] = schema
			v["storageContract"], v["storageSnapshotHash"] = rowTestDoc("migration", storage)
			db["retirements"].([]any)[0].(map[string]any)["toSchemaSnapshot"] = v["schemaSnapshotHash"]
			qv["schemaSnapshotHash"], qv["storageSnapshotHash"] = v["schemaSnapshotHash"], v["storageSnapshotHash"]
			// This mutation claims source metadata only, never executable steps
			// carrying the old storage identity. Refused origins still require
			// complete queue contracts and cannot conceal dependency loss.
			for _, raw := range db["origins"].([]any) {
				origin := raw.(map[string]any)
				origin["steps"] = nil
				origin["errors"] = []any{map[string]any{"code": "MIG016", "message": "source-only dependency-loss fixture"}}
			}
			if r.err != nil {
				t.Fatal(r.err)
			}
		}
		h.HistoryJSON = rowTestJSON(t, source)
		_, err := pgReadQueueHistory(h, rowTestJSON(t, companion), 1)
		if !loss && err != nil {
			t.Fatal("compiled unchanged queues refused", err)
		}
		if loss && (err == nil || !strings.Contains(err.Error(), "unchanged historical queue payload/proof/codec contracts")) {
			t.Fatal("coherently rehashed codec loss was not rejected at the full-contract boundary", err)
		}
	}
}
