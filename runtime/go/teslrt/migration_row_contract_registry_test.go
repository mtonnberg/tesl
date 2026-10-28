package teslrt

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestRowContractMalformedEnvelopeCannotPublish(t *testing.T) {
	for _, payload := range []string{
		`{}`, `{"version":2,"kind":"compiled-row-contract-history","compilerAbi":"bad","databases":[]}`,
		`{"version":1,"kind":"wrong","compilerAbi":"bad","databases":[]}`,
		`{"version":1,"kind":"compiled-row-contract-history","compilerAbi":"bad","databases":[{"database":"Foreign.Main","family":"Foreign.Schema","namespace":"foreign","contracts":[]}]}`,
		`{"version":1,"kind":"compiled-row-contract-history","compilerAbi":"bad","databases":[],"invented":true}`,
	} {
		t.Run(payload, func(t *testing.T) {
			pgMigrationRegistrations.Lock()
			before := make(map[*pgCompiledRowHistory]map[int]*pgRowContract, len(compiledRowContracts))
			for owner, contracts := range compiledRowContracts {
				copy := make(map[int]*pgRowContract, len(contracts))
				for version, contract := range contracts {
					copy[version] = contract
				}
				before[owner] = copy
			}
			pgMigrationRegistrations.Unlock()
			rejected := false
			func() { defer func() { rejected = recover() != nil }(); registerCompiledRowContractHistory(payload) }()
			if !rejected {
				t.Fatal("malformed compiler envelope was accepted")
			}
			pgMigrationRegistrations.Lock()
			unchanged := reflect.DeepEqual(before, compiledRowContracts)
			pgMigrationRegistrations.Unlock()
			if !unchanged {
				t.Fatal("refused envelope partially published Contract authority")
			}
		})
	}
}

// The dependency records below are untouched actual compiler outputs. Empty
// Contract inventories describe absence only and cannot grant a settled plan.
func TestRowContractCompleteEnvelopeRefusesPartialPublication(t *testing.T) {
	seed := rowPhysicalSeed(t)
	db := seed.Databases[0]
	if compiledRowHistories[db.Family] != nil {
		t.Fatal("compiler fixture unexpectedly registered")
	}
	registerCompiledMigrationHistory(db.Database, db.Family, db.Namespace, db.CurrentVersion, seed.CompilerABI, seed.StoredValueCompatibility, rowPhysicalSourceSeed)
	registerCompiledRowHistory(rowPhysicalTransformSeed)
	registerCompiledRowPhysicalHistory(rowPhysicalCompilerSeed)
	compiled := compiledRowHistories[db.Family]
	t.Cleanup(func() {
		pgMigrationRegistrations.Lock()
		defer pgMigrationRegistrations.Unlock()
		delete(compiledRowContracts, compiled)
		delete(compiledRowPhysicalHistories, compiled)
		delete(compiledRowRegistrations, compiled)
		delete(compiledRowHistories, db.Family)
		delete(pgMigrationClosedFamilies, db.Family)
		compiledMigrationHistories.Delete(db.Family)
		databaseIdentities.Delete(db.Database)
	})
	entry := map[string]any{"database": db.Database, "family": db.Family, "namespace": db.Namespace, "contracts": []any{}}
	payload := func(entries []any) string {
		raw, err := json.Marshal(map[string]any{"version": 1, "kind": "compiled-row-contract-history", "compilerAbi": seed.CompilerABI, "databases": entries})
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}
	for _, entries := range [][]any{{}, {entry, entry}, {entry, map[string]any{"database": "Foreign.Main", "family": "Foreign.Schema", "namespace": "foreign", "contracts": []any{}}}} {
		failed := false
		func() {
			defer func() { failed = recover() != nil }()
			registerCompiledRowContractHistory(payload(entries))
		}()
		if !failed || compiledRowContracts[compiled] != nil {
			t.Fatal("incomplete or late-invalid envelope published its valid prefix")
		}
	}
	registerCompiledRowContractHistory(payload([]any{entry}))
	if contracts, ok := compiledRowContracts[compiled]; !ok || len(contracts) != 0 {
		t.Fatal("complete empty inventory was not recorded")
	}
	failed := false
	func() {
		defer func() { failed = recover() != nil }()
		registerCompiledRowContractHistory(payload([]any{entry}))
	}()
	if !failed || len(compiledRowContracts[compiled]) != 0 {
		t.Fatal("duplicate registration replaced absence inventory")
	}
	if _, err := pgCompiledRowSettledPlan(nil, 2); err == nil {
		t.Fatal("empty source inventory fabricated owner authority")
	}
	if _, err := pgCompiledRowPredecessorPlan(nil, 1); err == nil {
		t.Fatal("invalid predecessor version fabricated authority")
	}
}
