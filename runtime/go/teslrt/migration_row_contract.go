package teslrt

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
)

type pgRowContract struct {
	compiled         *pgCompiledRowHistory
	window, settled  *pgRowPhysicalPlan
	contract, hash   string
	operations       []pgRowCanonical
	preparationCount int
	finalGenerations map[string]int
}

var compiledRowContracts = map[*pgCompiledRowHistory]map[int]*pgRowContract{}

func pgRowColumnNode(c pgRowPhysicalColumn) pgRowCanonical {
	d := pgRowList(pgRowAtom("null"))
	if c.catalog.Default != nil {
		d = pgRowList(pgRowAtom(c.catalog.Default.Kind), pgRowAtom(c.catalog.Default.Value))
	}
	return pgRowList(pgRowAtom(c.catalog.Name), pgRowAtom(c.catalog.Type), pgRowList(pgRowAtom("bool"), pgRowAtom(strconv.FormatBool(c.catalog.Nullable))), pgRowList(pgRowAtom("bool"), pgRowAtom(strconv.FormatBool(c.catalog.PrimaryKey))), pgRowAtom(strconv.Itoa(c.introducedVersion)), d)
}
func pgRowIndexNode(index PgMigrationCatalogIndex) pgRowCanonical {
	cols := make([]pgRowCanonical, len(index.Columns))
	for i, c := range index.Columns {
		cols[i] = pgRowAtom(c)
	}
	return pgRowList(pgRowAtom(index.Name), pgRowList(cols...), pgRowList(pgRowAtom("bool"), pgRowAtom(strconv.FormatBool(index.Unique))))
}

// Observation validates the complete known transition grammar. It neither binds
// local code nor marks rows final. The exact canonical operation order is the
// compiler's per-entity indexes, invalidation, columns, tightenings, marker order.
func pgParseRowContract(encoded, hash string, window, settled *pgRowPhysicalPlan) (*pgRowContract, error) {
	r := &pgMigrationWireReader{}
	n := pgRowDocument(r, encoded, hash, "contract")
	if r.err != nil || !n.list(10) || !n.children[0].isAtom("tesl-row-contract-v1") || window == nil || settled == nil || window.settled || !settled.settled || window.version != settled.version || window.version < 2 || len(window.windows) == 0 {
		return nil, fmt.Errorf("invalid checked row Contract document")
	}
	if !n.children[1].isAtom(window.family) || !n.children[2].isAtom(window.namespace) || !n.children[3].isAtom(strconv.Itoa(window.version)) || !n.children[4].isAtom(window.schemaSnapshotHash) || !n.children[6].isAtom(window.hash) || !n.children[7].isAtom(settled.hash) || n.children[8].atom || n.children[9].atom {
		return nil, fmt.Errorf("row Contract owner, source or physical identity differs")
	}
	result := &pgRowContract{window: window, settled: settled, contract: encoded, hash: hash, finalGenerations: map[string]int{}}
	finals := []pgRowCanonical{}
	for _, w := range window.windows {
		if !n.children[5].isAtom(w.transformBehaviorHash) {
			return nil, fmt.Errorf("row Contract migration behavior differs")
		}
		result.finalGenerations[w.entity] = w.targetGeneration
		finals = append(finals, pgRowList(pgRowAtom(w.entity), pgRowAtom(strconv.Itoa(w.targetGeneration))))
	}
	slices.SortFunc(finals, func(a, b pgRowCanonical) int {
		if a.children[0].value < b.children[0].value {
			return -1
		}
		if a.children[0].value > b.children[0].value {
			return 1
		}
		return 0
	})
	if !pgRowCanonicalEqual(n.children[8], pgRowList(finals...)) {
		return nil, fmt.Errorf("row Contract final generation inventory differs")
	}
	expected := []pgRowCanonical{}
	if len(window.entities) != len(settled.entities) {
		return nil, fmt.Errorf("row Contract cannot remove an entity")
	}
	for _, before := range window.entities {
		after := settled.entity(before.identity)
		if after == nil {
			return nil, fmt.Errorf("row Contract cannot remove an entity")
		}
		for _, column := range before.columns {
			if after.column(column.catalog.Name) == nil && !column.catalog.Nullable {
				if column.catalog.PrimaryKey {
					return nil, fmt.Errorf("row Contract cannot drop primary key")
				}
				prepared := column
				prepared.catalog.Nullable = true
				expected = append(expected, pgRowList(pgRowAtom("relax-retired-nullability"), pgRowAtom(before.identity), pgRowColumnNode(column), pgRowColumnNode(prepared)))
			}
		}
	}
	result.preparationCount = len(expected)
	for _, before := range window.entities {
		after := settled.entity(before.identity)
		if after == nil || after.table != before.table || after.generation != before.generation || after.typeContractHash != before.typeContractHash || !slices.Equal(after.projection, before.projection) || len(after.aliases) != 0 || len(after.reverseWrites) != 0 {
			return nil, fmt.Errorf("row Contract settled identity or projection differs")
		}
		entity := pgRowAtom(before.identity)
		for _, index := range before.indexes {
			found := false
			for _, current := range after.indexes {
				if current.Name == index.Name {
					if !pgPhysicalIndexEqual(index, current) {
						return nil, fmt.Errorf("row Contract cannot replace index shape")
					}
					found = true
					break
				}
			}
			if !found {
				expected = append(expected, pgRowList(pgRowAtom("drop-index"), entity, pgRowIndexNode(index)))
			}
		}
		for _, current := range after.indexes {
			found := false
			for _, prior := range before.indexes {
				if current.Name == prior.Name {
					found = true
					break
				}
			}
			if !found {
				return nil, fmt.Errorf("row Contract cannot create index")
			}
		}
		for _, w := range window.windows {
			if w.entity == before.identity {
				cols := make([]pgRowCanonical, len(w.invalidation))
				for i, c := range w.invalidation {
					cols[i] = pgRowAtom(c)
				}
				expected = append(expected, pgRowList(pgRowAtom("drop-invalidation"), entity, pgRowAtom(strconv.Itoa(w.previousGeneration)), pgRowAtom(strconv.Itoa(w.targetGeneration)), pgRowList(cols...)))
			}
		}
		for _, column := range before.columns {
			if after.column(column.catalog.Name) == nil {
				if column.catalog.PrimaryKey {
					return nil, fmt.Errorf("row Contract cannot drop primary key")
				}
				column.catalog.Nullable = true
				expected = append(expected, pgRowList(pgRowAtom("drop-column"), entity, pgRowColumnNode(column)))
			}
		}
		for _, column := range after.columns {
			prior := before.column(column.catalog.Name)
			if prior == nil {
				return nil, fmt.Errorf("row Contract cannot create column")
			}
			if pgPhysicalColumnEqual(*prior, column) {
				continue
			}
			tightened := *prior
			tightened.catalog.Nullable = false
			if !prior.catalog.Nullable || column.catalog.Nullable || !pgPhysicalColumnEqual(tightened, column) {
				return nil, fmt.Errorf("row Contract column differs beyond nullability")
			}
			name := pgRowNotNullCheckName(window, before.identity, column.catalog.Name)
			absent := pgRowList(pgRowAtom("absent"))
			unvalidated := pgRowList(pgRowAtom("not-null-check"), pgRowAtom(name), pgRowAtom(column.catalog.Name), pgRowAtom("false"))
			validated := pgRowList(pgRowAtom("not-null-check"), pgRowAtom(name), pgRowAtom(column.catalog.Name), pgRowAtom("true"))
			expected = append(expected,
				pgRowList(pgRowAtom("add-not-null-check"), entity, absent, unvalidated),
				pgRowList(pgRowAtom("validate-not-null-check"), entity, unvalidated, validated),
				pgRowList(pgRowAtom("set-not-null"), entity, pgRowColumnNode(*prior), pgRowColumnNode(column)),
				pgRowList(pgRowAtom("drop-not-null-check"), entity, validated, absent))
		}
		if before.insertGeneration != after.insertGeneration {
			if after.insertGeneration != after.generation {
				return nil, fmt.Errorf("row Contract marker default is not final generation")
			}
			expected = append(expected, pgRowList(pgRowAtom("set-insert-generation"), entity, pgRowAtom(strconv.Itoa(before.insertGeneration)), pgRowAtom(strconv.Itoa(after.insertGeneration))))
		}
	}
	if !pgRowCanonicalEqual(n.children[9], pgRowList(expected...)) {
		return nil, fmt.Errorf("row Contract exact ordered operation inventory differs")
	}
	result.operations = expected
	return result, nil
}

// Private compiler emission only. Parsed documents remain descriptions until
// the complete envelope has been bound to exact local source/physical owners.
func registerCompiledRowContractHistory(payload string) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	r := &pgMigrationWireReader{}
	root := r.object(json.RawMessage(payload), "version", "kind", "compilerAbi", "databases")
	if pgMigrationRead[int](r, root["version"]) != 1 || pgMigrationRead[string](r, root["kind"]) != "compiled-row-contract-history" {
		r.fail("unsupported compiled Contract envelope")
	}
	abi := pgMigrationRead[string](r, root["compilerAbi"])
	pending := map[*pgCompiledRowHistory]map[int]*pgRowContract{}
	for _, raw := range pgMigrationRead[[]json.RawMessage](r, root["databases"]) {
		entry := r.object(raw, "database", "family", "namespace", "contracts")
		family := pgMigrationRead[string](r, entry["family"])
		compiled := compiledRowHistories[family]
		if compiled == nil || compiled.history.Database != pgMigrationRead[string](r, entry["database"]) || compiled.history.Namespace != pgMigrationRead[string](r, entry["namespace"]) || compiled.history.SourceCompilerABI != abi || compiledRowPhysicalHistories[compiled] == nil || pgMigrationClosedFamilies[family] {
			r.fail("Contract envelope lacks exact open compiled owner")
			continue
		}
		if pending[compiled] != nil || compiledRowContracts[compiled] != nil {
			r.fail("duplicate Contract history")
			continue
		}
		contracts := map[int]*pgRowContract{}
		last := 1
		for _, rawContract := range pgMigrationRead[[]json.RawMessage](r, entry["contracts"]) {
			c := r.object(rawContract, "contract", "hash", "settled", "settledHash")
			settled, err := pgParseRowSettledPlan(pgMigrationRead[string](r, c["settled"]), pgMigrationRead[string](r, c["settledHash"]))
			if err != nil {
				r.fail(err.Error())
				continue
			}
			history := compiledRowPhysicalHistories[compiled]
			if settled.version <= last || settled.version > len(history.versions) {
				r.fail("Contract version inventory is unordered or unavailable")
				continue
			}
			window := history.versions[settled.version-1]
			if err := pgBindRowSettledPlan(compiled, window, settled); err != nil {
				r.fail(err.Error())
				continue
			}
			contract, err := pgParseRowContract(pgMigrationRead[string](r, c["contract"]), pgMigrationRead[string](r, c["hash"]), window, settled)
			if err != nil {
				r.fail(err.Error())
				continue
			}
			contracts[settled.version] = contract
			last = settled.version
		}
		pending[compiled] = contracts
	}
	for compiled := range compiledRowPhysicalHistories {
		if pending[compiled] == nil {
			r.fail("Contract envelope omits a complete physical owner inventory")
		}
	}
	if r.err != nil {
		panic(r.err)
	}
	for compiled, contracts := range pending {
		for _, contract := range contracts {
			contract.compiled = compiled
			contract.settled.compiled = compiled
		}
		compiledRowContracts[compiled] = contracts
	}
}

func pgCompiledRowSettledPlan(database *Database, version int) (*pgRowPhysicalPlan, error) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if database == nil {
		return nil, fmt.Errorf("missing settled database owner")
	}
	history, ok := database.CompiledMigrationHistory()
	if !ok {
		return nil, fmt.Errorf("missing settled source history")
	}
	compiled := compiledRowHistories[history.Family]
	if err := pgCheckRowOwner(database, compiled); err != nil {
		return nil, err
	}
	if version == 1 {
		physical := compiledRowPhysicalHistories[compiled]
		if physical != nil && len(physical.versions) > 0 {
			return physical.versions[0], nil
		}
	}
	contract := compiledRowContracts[compiled][version]
	if contract == nil || contract.compiled != compiled || contract.settled.compiled != compiled {
		return nil, fmt.Errorf("missing exact checked settled Contract plan")
	}
	return contract.settled, nil
}

func pgCompiledRowPredecessorPlan(database *Database, version int) (*pgRowPhysicalPlan, error) {
	if version < 2 {
		return nil, fmt.Errorf("missing physical predecessor version")
	}
	return pgCompiledRowSettledPlan(database, version-1)
}

func pgRowNotNullCheckName(window *pgRowPhysicalPlan, entity, physical string) string {
	payload := pgRowList(pgRowAtom("tesl-row-not-null-name-v1"), pgRowAtom(window.family), pgRowAtom(window.namespace), pgRowAtom(strconv.Itoa(window.version)), pgRowAtom(window.hash), pgRowAtom(entity), pgRowAtom(physical))
	document := pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("contract"), payload)
	return "tesl_nn_" + fmt.Sprintf("%x", sha256.Sum256([]byte(pgRowEncode(document))))[:48]
}
