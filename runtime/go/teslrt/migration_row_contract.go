package teslrt

import (
	"crypto/sha256"
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

// compiledRowContracts holds the validated Contracts of the serving window
// (every Contract of a small history). compiledRowContractHistories validates
// the rest once, when a caller first needs a Contract outside the window. Both
// are protected by pgMigrationRegistrations.
var compiledRowContracts = map[*pgCompiledRowHistory]map[int]*pgRowContract{}
var compiledRowContractHistories = map[*pgCompiledRowHistory]*pgRowContractHistory{}

type pgRowContractHistory struct {
	compiled *pgCompiledRowHistory
	raw      []pgRowContractText
	full     pgMemo[map[int]*pgRowContract]
}

type pgRowContractText struct{ contract, hash, settled, settledHash string }

// complete parses and binds every Contract, reusing the window Contracts.
func (history *pgRowContractHistory) complete(window map[int]*pgRowContract) (map[int]*pgRowContract, error) {
	return history.full.get(func() (map[int]*pgRowContract, error) {
		pgHistoryCounters.complete.Add(1)
		compiled := history.compiled
		physical := compiledRowPhysicalHistories[compiled]
		if physical == nil {
			return nil, fmt.Errorf("row Contract history lacks its physical history")
		}
		plans, err := physical.all()
		if err != nil {
			return nil, err
		}
		contracts := map[int]*pgRowContract{}
		last := 1
		for _, text := range history.raw {
			settled, err := pgParseRowSettledPlan(text.settled, text.settledHash)
			if err != nil {
				return nil, err
			}
			if settled.version <= last || settled.version > len(plans) {
				return nil, fmt.Errorf("invalid compiled migration history: Contract version inventory is unordered or unavailable")
			}
			last = settled.version
			if existing := window[settled.version]; existing != nil {
				contracts[settled.version] = existing
				continue
			}
			contract, err := pgBindRowContractText(compiled, plans[settled.version-1], settled, text)
			if err != nil {
				return nil, err
			}
			contract.compiled = compiled
			contract.settled.compiled = compiled
			contracts[settled.version] = contract
		}
		for version := range window {
			if contracts[version] == nil {
				return nil, fmt.Errorf("invalid compiled migration history: Contract version inventory is unordered or unavailable")
			}
		}
		return contracts, nil
	})
}

func pgBindRowContractText(compiled *pgCompiledRowHistory, window, settled *pgRowPhysicalPlan, text pgRowContractText) (*pgRowContract, error) {
	if err := pgBindRowSettledPlan(compiled, window, settled); err != nil {
		return nil, err
	}
	return pgParseRowContract(text.contract, text.hash, window, settled)
}

// pgRowContractAt returns the compiler Contract for one version, or nil when
// the history has none. The caller holds pgMigrationRegistrations.
func pgRowContractAt(compiled *pgCompiledRowHistory, version int) (*pgRowContract, error) {
	window := compiledRowContracts[compiled]
	if contract := window[version]; contract != nil {
		return contract, nil
	}
	history := compiledRowContractHistories[compiled]
	if history == nil || compiled == nil || pgServingWindow(compiled.history.CurrentVersion, version) {
		return nil, nil
	}
	contracts, err := history.complete(window)
	if err != nil {
		return nil, err
	}
	return contracts[version], nil
}

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

func pgRowPhysicalEntityNode(e pgRowPhysicalEntity) pgRowCanonical {
	columns, indexes := []pgRowCanonical{}, []pgRowCanonical{}
	for _, c := range e.columns {
		columns = append(columns, pgRowColumnNode(c))
	}
	for _, index := range e.indexes {
		indexes = append(indexes, pgRowIndexNode(index))
	}
	pairs := func(fields []pgRowPhysicalField) pgRowCanonical {
		nodes := []pgRowCanonical{}
		for _, f := range fields {
			nodes = append(nodes, pgRowList(pgRowAtom(f.logical), pgRowAtom(f.physical)))
		}
		return pgRowList(nodes...)
	}
	reverse := []pgRowCanonical{}
	for _, w := range e.reverseWrites {
		fields := []pgRowCanonical{pgRowAtom(w.previous)}
		if !w.legacy {
			fields = append(fields, pgRowAtom(w.current))
		}
		reverse = append(reverse, pgRowList(append(fields, pgRowAtom(w.physical))...))
	}
	return pgRowList(pgRowAtom(e.identity), pgRowAtom(e.table), pgRowAtom(strconv.Itoa(e.generation)), pgRowAtom(strconv.Itoa(e.insertGeneration)), pgRowAtom(e.typeContractHash), pgRowList(columns...), pairs(e.projection), pgRowList(indexes...), pairs(e.aliases), pgRowList(reverse...))
}
func pgRowRetirementNode(retirement pgRowPhysicalRetirement) pgRowCanonical {
	return pgRowList(pgRowAtom(retirement.entity), pgRowAtom(retirement.fromSchemaHash), pgRowAtom(retirement.toSchemaHash))
}
func pgRowTableRetirementBehavior(window *pgRowPhysicalPlan) string {
	nodes := []pgRowCanonical{}
	for _, retirement := range window.retirements {
		nodes = append(nodes, pgRowRetirementNode(retirement))
	}
	payload := pgRowList(pgRowAtom("tesl-table-retirement-v1"), pgRowAtom(window.family), pgRowAtom(window.namespace), pgRowAtom(strconv.Itoa(window.version)), pgRowList(nodes...))
	doc := pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("contract"), payload)
	return fmt.Sprintf("%x", sha256.Sum256([]byte(pgRowEncode(doc))))
}
func pgParseTableContract(result *pgRowContract, n pgRowCanonical) (*pgRowContract, error) {
	window, settled := result.window, result.settled
	if len(window.windows) != 0 || len(window.retirements) != 1 || len(settled.windows) != 0 || len(settled.retirements) != 0 || len(settled.entities) == 0 || len(window.entities) != len(settled.entities)+1 || !n.children[8].list(0) || !n.children[5].isAtom(pgRowTableRetirementBehavior(window)) {
		return nil, fmt.Errorf("table Contract requires exact pure retirement and empty final generations")
	}
	retirement := window.retirements[0]
	before := window.entity(retirement.entity)
	if before == nil || settled.entity(retirement.entity) != nil || len(before.aliases) != 0 || len(before.reverseWrites) != 0 {
		return nil, fmt.Errorf("table Contract lacks an exact retired-only predecessor")
	}
	for _, after := range settled.entities {
		prior := window.entity(after.identity)
		if prior == nil || !pgRowCanonicalEqual(pgRowPhysicalEntityNode(*prior), pgRowPhysicalEntityNode(after)) {
			return nil, fmt.Errorf("table Contract changes a surviving entity")
		}
	}
	expected := pgRowList(pgRowAtom("drop-table"), pgRowAtom(before.identity), pgRowPhysicalEntityNode(*before))
	if !pgRowCanonicalEqual(n.children[9], pgRowList(expected)) {
		return nil, fmt.Errorf("table Contract exact ordered operation inventory differs")
	}
	result.operations = []pgRowCanonical{expected}
	return result, nil
}

// Observation validates the complete known transition grammar. It neither binds
// local code nor marks rows final. The exact canonical operation order is the
// compiler's per-entity indexes, invalidation, columns, tightenings, marker order.
func pgParseRowContract(encoded, hash string, window, settled *pgRowPhysicalPlan) (*pgRowContract, error) {
	r := &pgMigrationWireReader{}
	n := pgRowDocument(r, encoded, hash, "contract")
	if r.err != nil || !n.list(10) || (!n.children[0].isAtom("tesl-row-contract-v1") && !n.children[0].isAtom("tesl-table-contract-v1") && !n.children[0].isAtom("tesl-stage-contract-v1")) || window == nil || settled == nil || window.settled || !settled.settled || window.version != settled.version || window.version < 2 {
		return nil, fmt.Errorf("invalid checked row Contract document")
	}
	if !n.children[1].isAtom(window.family) || !n.children[2].isAtom(window.namespace) || !n.children[3].isAtom(strconv.Itoa(window.version)) || !n.children[4].isAtom(window.schemaSnapshotHash) || !n.children[6].isAtom(window.hash) || !n.children[7].isAtom(settled.hash) || n.children[8].atom || n.children[9].atom {
		return nil, fmt.Errorf("row Contract owner, source or physical identity differs")
	}
	result := &pgRowContract{window: window, settled: settled, contract: encoded, hash: hash, finalGenerations: map[string]int{}}
	if n.children[0].isAtom("tesl-stage-contract-v1") {
		return pgParseStageContract(result, n)
	}
	if n.children[0].isAtom("tesl-table-contract-v1") {
		return pgParseTableContract(result, n)
	}
	if len(window.windows) == 0 || len(window.retirements) != 0 {
		return nil, fmt.Errorf("row Contract requires transforming windows without table retirement")
	}
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
// Registration validates the Contracts of the serving window; see
// migration_history_lazy.go.
func registerCompiledRowContractHistory(payload string) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	fail := func(message string) { panic(fmt.Errorf("invalid compiled migration history: %s", message)) }
	must := func(err error) {
		if err != nil {
			panic(err)
		}
	}
	must(pgJSONIntegrity(payload))
	root, err := pgJSONObject(payload, "version", "kind", "contractEncoding", "compilerAbi", "databases")
	must(err)
	must(pgCanonicalEncodingCheck(root["contractEncoding"]))
	format, err := pgJSONValue[int](root["version"])
	must(err)
	kind, err := pgJSONValue[string](root["kind"])
	must(err)
	if format != 1 || kind != "compiled-row-contract-history" {
		fail("unsupported compiled Contract envelope")
	}
	abi, err := pgJSONValue[string](root["compilerAbi"])
	must(err)
	entries, err := pgJSONArray(root["databases"])
	must(err)
	pending := map[*pgCompiledRowHistory]map[int]*pgRowContract{}
	histories := map[*pgCompiledRowHistory]*pgRowContractHistory{}
	for _, raw := range entries {
		entry, err := pgJSONObject(raw, "database", "family", "namespace", "contracts", "canonicalNodes")
		must(err)
		nodes, err := pgReadCanonicalNodes(entry["canonicalNodes"])
		must(err)
		family, err := pgJSONValue[string](entry["family"])
		must(err)
		database, err := pgJSONValue[string](entry["database"])
		must(err)
		namespace, err := pgJSONValue[string](entry["namespace"])
		must(err)
		compiled := compiledRowHistories[family]
		physical := compiledRowPhysicalHistories[compiled]
		if compiled == nil || physical == nil || compiled.history.Database != database || compiled.history.Namespace != namespace || compiled.history.SourceCompilerABI != abi || pgMigrationClosedFamilies[family] {
			panic(fmt.Errorf("invalid compiled migration history: Contract envelope lacks exact open compiled owner"))
		}
		if pending[compiled] != nil || compiledRowContracts[compiled] != nil {
			fail("duplicate Contract history")
		}
		raws, err := pgJSONArray(entry["contracts"])
		must(err)
		history := &pgRowContractHistory{compiled: compiled}
		for _, rawContract := range raws {
			c, err := pgJSONObject(rawContract, "contract", "hash", "settled", "settledHash")
			must(err)
			var text pgRowContractText
			for _, field := range []struct {
				name     string
				target   *string
				contract bool
			}{{"contract", &text.contract, true}, {"hash", &text.hash, false}, {"settled", &text.settled, true}, {"settledHash", &text.settledHash, false}} {
				var value string
				if field.contract {
					value, err = pgCanonicalReference(nodes, c[field.name])
				} else {
					value, err = pgJSONValue[string](c[field.name])
				}
				must(err)
				*field.target = value
			}
			history.raw = append(history.raw, text)
		}
		current := compiled.history.CurrentVersion
		contracts := map[int]*pgRowContract{}
		if pgHistoryInWindow(current) || pgLinkedSourceOf(compiled.history) == nil {
			all, err := history.complete(nil)
			must(err)
			contracts = all
		} else {
			// Contracts are ordered by version; the window's are at the end.
			for i := len(history.raw) - 1; i >= 0; i-- {
				text := history.raw[i]
				settled, err := pgParseRowSettledPlan(text.settled, text.settledHash)
				must(err)
				if settled == nil {
					panic(fmt.Errorf("invalid compiled migration history: missing settled physical document"))
				}
				if settled.version <= 1 || settled.version > current {
					fail("Contract version inventory is unordered or unavailable")
				}
				if !pgServingWindow(current, settled.version) {
					break
				}
				if contracts[settled.version] != nil {
					fail("Contract version inventory is unordered or unavailable")
				}
				pgHistoryCounters.elements.Add(1)
				window, err := physical.plan(settled.version)
				must(err)
				contract, err := pgBindRowContractText(compiled, window, settled, text)
				must(err)
				contracts[settled.version] = contract
			}
		}
		pending[compiled] = contracts
		histories[compiled] = history
	}
	for compiled := range compiledRowPhysicalHistories {
		if pending[compiled] == nil {
			fail("Contract envelope omits a complete physical owner inventory")
		}
	}
	for compiled, contracts := range pending {
		for _, contract := range contracts {
			contract.compiled = compiled
			contract.settled.compiled = compiled
		}
		compiledRowContracts[compiled] = contracts
		compiledRowContractHistories[compiled] = histories[compiled]
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
	if compiled == nil {
		return nil, fmt.Errorf("missing settled compiled source")
	}
	if err := pgCheckRowOwner(database, compiled); err != nil {
		return nil, err
	}
	physical := compiledRowPhysicalHistories[compiled]
	if physical != nil && version > 0 && version <= len(physical.raw) {
		contracts := compiledRowContractHistories[compiled]
		_, _, complete := contracts.fullPeek()
		plan, err := pgRowAdditiveTailPlan(compiled, physical, version, complete)
		if err != nil || plan != nil {
			return plan, err
		}
	}
	contract, err := pgRowContractAt(compiled, version)
	if err != nil {
		return nil, err
	}
	if contract == nil || contract.compiled != compiled || contract.settled.compiled != compiled {
		return nil, fmt.Errorf("missing exact checked settled Contract plan")
	}
	return contract.settled, nil
}

func (history *pgRowContractHistory) fullPeek() (map[int]*pgRowContract, error, bool) {
	if history == nil {
		return nil, nil, false
	}
	return history.full.peek()
}

// pgRowTransforming reports a version that transforms rows, from the decoded
// transform and retirement lists, without loading its plan.
func pgRowTransforming(compiled *pgCompiledRowHistory, v int) bool {
	for _, d := range compiled.transforms {
		if d.MigrationVersion == v {
			return true
		}
	}
	for _, d := range compiled.retirements {
		if d.MigrationVersion == v {
			return true
		}
	}
	return false
}

// pgRowAdditiveTailPlan returns version's own plan when it needs no Contract
// of its own (a purely additive prefix, or an additive or queue-only tail whose
// earlier transformations have their exact Contracts), and nil otherwise.
// Earlier transformations outside the serving window are checked only when
// full is set: serving never reads them, and complete validation checks them
// with full set. Caller holds pgMigrationRegistrations.
func pgRowAdditiveTailPlan(compiled *pgCompiledRowHistory, physical *pgCompiledRowPhysicalHistory, version int, full bool) (*pgRowPhysicalPlan, error) {
	current, err := physical.plan(version)
	if err != nil {
		return nil, err
	}
	// A purely additive prefix has no retained conversion state to contract.
	// Do not extend this judgment across an earlier transforming window:
	// that requires its exact registered Contract and durable completion.
	additivePrefix := true
	for v := 1; v <= version; v++ {
		if pgRowTransforming(compiled, v) {
			additivePrefix = false
			break
		}
	}
	if additivePrefix {
		return current, nil
	}
	if !pgRowEpochPreserving(current) && !pgRowQueueEdge(current) {
		return nil, nil
	}
	// An additive or queue-only tail has a complete row projection. Earlier
	// transformations still need their exact registered Contracts; durable
	// completion is independently required by expansion/admission checks.
	for v := 1; v <= version; v++ {
		if !pgRowTransforming(compiled, v) || !full && !pgServingWindow(compiled.history.CurrentVersion, v) {
			continue
		}
		plan, err := physical.plan(v)
		if err != nil {
			return nil, err
		}
		prior, err := pgRowContractAt(compiled, v)
		if err != nil {
			return nil, err
		}
		if prior == nil || prior.compiled != compiled || prior.window != plan || prior.settled.compiled != compiled {
			return nil, fmt.Errorf("additive tail lacks its exact earlier Contract source")
		}
	}
	return current, nil
}

func pgCompiledRowPredecessorPlan(database *Database, version int) (*pgRowPhysicalPlan, error) {
	if version < 2 {
		return nil, fmt.Errorf("missing physical predecessor version")
	}
	previous, err := pgCompiledRowPhysicalPlan(database, version-1)
	if err != nil {
		return nil, err
	}
	if len(previous.stageGuards) > 0 {
		c, err := pgRowContractFor(database, version-1)
		if err != nil {
			return nil, fmt.Errorf("stage reliance requires reviewed PromoteStage Contract: %w", err)
		}
		return c.settled, nil
	}
	return pgCompiledRowSettledPlan(database, version-1)
}

func pgRowNotNullCheckName(window *pgRowPhysicalPlan, entity, physical string) string {
	payload := pgRowList(pgRowAtom("tesl-row-not-null-name-v1"), pgRowAtom(window.family), pgRowAtom(window.namespace), pgRowAtom(strconv.Itoa(window.version)), pgRowAtom(window.hash), pgRowAtom(entity), pgRowAtom(physical))
	document := pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("contract"), payload)
	return "tesl_nn_" + fmt.Sprintf("%x", sha256.Sum256([]byte(pgRowEncode(document))))[:48]
}
