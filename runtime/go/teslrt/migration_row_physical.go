package teslrt

import (
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
)

// Physical descriptions are immutable compiler-linked plans, not live catalog
// observations. Structural parsing also serves old binaries reading a protected
// future manifest; only separate private registration binds execution authority.
type pgRowPhysicalField struct{ logical, physical string }
type pgRowPhysicalReverse struct {
	previous, current, physical string
	legacy                      bool
}
type pgRowPhysicalColumn struct {
	catalog           PgMigrationCatalogColumn
	introducedVersion int
}
type pgRowPhysicalEntity struct {
	identity, table, typeContractHash string
	generation, insertGeneration      int
	columns                           []pgRowPhysicalColumn
	projection, aliases               []pgRowPhysicalField
	reverseWrites                     []pgRowPhysicalReverse
	indexes                           []PgMigrationCatalogIndex
}
type pgRowPhysicalWindow struct {
	entity                                                        string
	previousGeneration, targetGeneration, requiresFinalGeneration int
	fromSchemaHash, toSchemaHash, transformBehaviorHash           string
	invalidation                                                  []string
}
type pgRowPhysicalPlan struct {
	compiled                                *pgCompiledRowHistory
	settled                                 bool
	requiresContractVersion                 int
	family, namespace                       string
	version                                 int
	schemaSnapshotHash, storageSnapshotHash string
	entities                                []pgRowPhysicalEntity
	windows                                 []pgRowPhysicalWindow
	contract, hash                          string
}
type pgCompiledRowPhysicalHistory struct {
	compiled *pgCompiledRowHistory
	payload  string
	versions []*pgRowPhysicalPlan
}

// A structural plan is a description only. No pointer to local compiled code is
// attached here; a V1 binary can use it to check a protected future catalog.
func pgParseRowPhysicalPlan(contract, hash string) (*pgRowPhysicalPlan, error) {
	return pgParseRowPhysicalShape(contract, hash, false)
}
func pgParseRowSettledPlan(contract, hash string) (*pgRowPhysicalPlan, error) {
	return pgParseRowPhysicalShape(contract, hash, true)
}
func pgParseRowPhysicalShape(contract, hash string, settled bool) (*pgRowPhysicalPlan, error) {
	r := &pgMigrationWireReader{}
	n := pgRowDocument(r, contract, hash, "migration")
	if r.err != nil || (!n.list(8) && !n.list(9)) {
		return nil, fmt.Errorf("invalid retained physical document")
	}
	if settled {
		if !n.list(8) || !n.children[0].isAtom("tesl-settled-physical-version-v1") {
			return nil, fmt.Errorf("invalid settled physical document")
		}
	} else {
		valid := n.list(8) && (n.children[0].isAtom("tesl-retained-physical-version-v1") || n.children[0].isAtom("tesl-retained-physical-version-v2"))
		valid = valid || (n.list(9) && (n.children[0].isAtom("tesl-retained-physical-version-v3") || n.children[0].isAtom("tesl-retained-physical-version-v4")))
		if !valid {
			return nil, fmt.Errorf("invalid retained physical document")
		}
	}
	atom := func(n pgRowCanonical) string {
		if !n.atom {
			r.fail("physical atom expected")
		}
		return n.value
	}
	number := func(n pgRowCanonical, max int) int {
		value := atom(n)
		i, err := strconv.Atoi(value)
		if err != nil || i < 1 || i > max || strconv.Itoa(i) != value {
			r.fail("invalid physical integer")
		}
		return i
	}
	boolean := func(n pgRowCanonical) bool {
		if !pgRowBool(n, true) && !pgRowBool(n, false) {
			r.fail("invalid physical boolean")
		}
		return pgRowBool(n, true)
	}
	sequence := func(n pgRowCanonical) []pgRowCanonical {
		if n.atom {
			r.fail("physical sequence expected")
			return nil
		}
		return n.children
	}
	plan := &pgRowPhysicalPlan{settled: settled, family: atom(n.children[1]), namespace: atom(n.children[2]), version: number(n.children[3], 2147483646), schemaSnapshotHash: atom(n.children[4]), storageSnapshotHash: atom(n.children[5]), contract: contract, hash: hash}
	if !pgMigrationIdentifier(plan.namespace) || !pgMigrationFamily(plan.family) || !pgMigrationDigest(plan.schemaSnapshotHash) || !pgMigrationDigest(plan.storageSnapshotHash) {
		r.fail("invalid physical owner")
	}
	legacyFormat := n.children[0].isAtom("tesl-retained-physical-version-v4")
	requiresContract := n.children[0].isAtom("tesl-retained-physical-version-v3")
	prerequisite := pgRowCanonical{}
	if requiresContract {
		prerequisite = n.children[8]
	}
	if legacyFormat {
		optional := sequence(n.children[8])
		if len(optional) > 1 {
			r.fail("invalid legacy Contract prerequisite")
		}
		if len(optional) == 1 {
			requiresContract = true
			prerequisite = optional[0]
		}
	}
	if requiresContract {
		plan.requiresContractVersion = number(prerequisite, 2147483646)
		if plan.requiresContractVersion >= plan.version {
			r.fail("physical contract prerequisite must precede expansion")
		}
	}
	reverseFormat := legacyFormat || requiresContract || n.children[0].isAtom("tesl-retained-physical-version-v2")
	entityWidth := 9
	if reverseFormat {
		entityWidth = 10
	}
	hasReverse, hasLegacy := false, false
	names, tables, relations := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, raw := range sequence(n.children[6]) {
		if !raw.list(entityWidth) {
			return nil, fmt.Errorf("invalid physical entity")
		}
		c := raw.children
		e := pgRowPhysicalEntity{identity: atom(c[0]), table: atom(c[1]), generation: number(c[2], 32767), insertGeneration: number(c[3], 32767), typeContractHash: atom(c[4])}
		if !pgQueueIdentity(e.identity) || !pgMigrationIdentifier(e.table) || names[e.identity] || tables[e.table] || e.insertGeneration > e.generation || !pgMigrationDigest(e.typeContractHash) {
			r.fail("invalid physical entity identity")
		}
		names[e.identity], tables[e.table] = true, true
		if relations[e.table] || relations[e.table+"_pkey"] || len(e.table+"_pkey") > 63 {
			r.fail("physical relation collision")
		}
		relations[e.table], relations[e.table+"_pkey"] = true, true
		columns := map[string]PgMigrationCatalogColumn{}
		last := ""
		for _, rawColumn := range sequence(c[5]) {
			if !rawColumn.list(6) {
				return nil, fmt.Errorf("invalid physical column")
			}
			cc := rawColumn.children
			col := pgRowPhysicalColumn{catalog: PgMigrationCatalogColumn{Name: atom(cc[0]), Type: atom(cc[1]), Nullable: boolean(cc[2]), PrimaryKey: boolean(cc[3])}, introducedVersion: number(cc[4], plan.version)}
			if col.catalog.Name <= last || col.catalog.Name == "_tesl_v" {
				r.fail("physical columns require unique canonical order")
			}
			last = col.catalog.Name
			d := cc[5]
			if d.list(1) && d.children[0].isAtom("null") {
				col.catalog.Default = nil
			} else if d.list(2) {
				col.catalog.Default = &PgMigrationCatalogConstant{Kind: atom(d.children[0]), Value: atom(d.children[1])}
			} else {
				r.fail("invalid physical default")
			}
			columns[col.catalog.Name] = col.catalog
			e.columns = append(e.columns, col)
		}
		pairs := func(raw pgRowCanonical) []pgRowPhysicalField {
			var result []pgRowPhysicalField
			prior := ""
			for _, pair := range sequence(raw) {
				if !pair.list(2) {
					r.fail("invalid physical field pair")
					continue
				}
				field := pgRowPhysicalField{logical: atom(pair.children[0]), physical: atom(pair.children[1])}
				key := field.logical + "\x00" + field.physical
				if !pgRowName(field.logical) || !pgMigrationIdentifier(field.physical) || key <= prior {
					r.fail("physical pairs require unique canonical order")
				}
				prior = key
				if _, ok := columns[field.physical]; !ok {
					r.fail("physical pair references missing column")
				}
				result = append(result, field)
			}
			return result
		}
		e.projection = pairs(c[6])
		e.aliases = pairs(c[8])
		logical, physical := map[string]string{}, map[string]bool{}
		for _, field := range e.projection {
			if _, ok := logical[field.logical]; ok || physical[field.physical] {
				r.fail("physical projection is not one-to-one")
			}
			logical[field.logical] = field.physical
			physical[field.physical] = true
		}
		for _, alias := range e.aliases {
			target, ok := logical[alias.logical]
			if !ok || physical[alias.physical] || columns[target].Type != columns[alias.physical].Type || columns[alias.physical].PrimaryKey {
				r.fail("invalid physical alias")
			}
			physical[alias.physical] = true
		}
		if reverseFormat {
			prior := ""
			for _, raw := range sequence(c[9]) {
				if !raw.list(3) && (!legacyFormat || !raw.list(2)) {
					r.fail("invalid reverse physical binding")
					continue
				}
				write := pgRowPhysicalReverse{previous: atom(raw.children[0]), physical: atom(raw.children[len(raw.children)-1]), legacy: raw.list(2)}
				if !write.legacy {
					write.current = atom(raw.children[1])
				} else {
					hasLegacy = true
				}
				key := write.previous + "\x00" + write.current + "\x00" + write.physical
				column, exists := columns[write.physical]
				target, current := logical[write.current]
				_, stillCurrent := logical[write.previous]
				validTarget := current && !columns[target].PrimaryKey
				if write.legacy {
					validTarget = !stillCurrent
				}
				if !pgRowName(write.previous) || !validTarget || !exists || physical[write.physical] || column.PrimaryKey || key <= prior {
					r.fail("invalid reverse physical owner")
				}
				prior = key
				physical[write.physical] = true
				e.reverseWrites = append(e.reverseWrites, write)
				hasReverse = true
			}
		}
		if len(physical) != len(columns) {
			r.fail("retained column lacks a complete write source")
		}
		last = ""
		for _, rawIndex := range sequence(c[7]) {
			if !rawIndex.list(3) {
				return nil, fmt.Errorf("invalid physical index")
			}
			index := PgMigrationCatalogIndex{Name: atom(rawIndex.children[0]), Unique: boolean(rawIndex.children[2])}
			if index.Name <= last || relations[index.Name] {
				r.fail("physical index identity collision")
			}
			last = index.Name
			relations[index.Name] = true
			for _, col := range sequence(rawIndex.children[1]) {
				index.Columns = append(index.Columns, atom(col))
			}
			e.indexes = append(e.indexes, index)
		}
		catalog := PgMigrationCatalogTable{Name: e.table, Indexes: e.indexes}
		for _, col := range e.columns {
			catalog.Columns = append(catalog.Columns, col.catalog)
		}
		if err := pgValidateMigrationCatalog([]PgMigrationCatalogTable{catalog}); err != nil {
			r.fail(err.Error())
		}
		plan.entities = append(plan.entities, e)
	}
	if !slices.IsSortedFunc(plan.entities, func(a, b pgRowPhysicalEntity) int { return strings.Compare(a.identity, b.identity) }) {
		r.fail("physical entities require canonical order")
	}
	seen := map[string]bool{}
	for _, raw := range sequence(n.children[7]) {
		if !raw.list(8) {
			return nil, fmt.Errorf("invalid physical window")
		}
		c := raw.children
		w := pgRowPhysicalWindow{entity: atom(c[0]), previousGeneration: number(c[1], 32767), targetGeneration: number(c[2], 32767), requiresFinalGeneration: number(c[3], 32767), fromSchemaHash: atom(c[4]), toSchemaHash: atom(c[5]), transformBehaviorHash: atom(c[6])}
		if seen[w.entity] || !names[w.entity] || w.previousGeneration+1 != w.targetGeneration || w.requiresFinalGeneration != w.previousGeneration || !pgMigrationDigest(w.fromSchemaHash) || w.toSchemaHash != plan.schemaSnapshotHash || !pgMigrationDigest(w.transformBehaviorHash) {
			r.fail("invalid physical window binding")
		}
		seen[w.entity] = true
		for _, col := range sequence(c[7]) {
			w.invalidation = append(w.invalidation, atom(col))
		}
		if len(w.invalidation) == 0 || !slices.IsSorted(w.invalidation) || len(slices.Compact(slices.Clone(w.invalidation))) != len(w.invalidation) {
			r.fail("invalid physical invalidation columns")
		}
		plan.windows = append(plan.windows, w)
	}
	if !slices.IsSortedFunc(plan.windows, func(a, b pgRowPhysicalWindow) int { return strings.Compare(a.entity, b.entity) }) {
		r.fail("physical windows require canonical order")
	}
	if r.err != nil {
		return nil, r.err
	}
	if legacyFormat && !hasLegacy {
		return nil, fmt.Errorf("legacy physical format requires an explicit legacy obligation")
	}
	if reverseFormat && !requiresContract && !hasReverse {
		return nil, fmt.Errorf("reverse physical format has no reverse bindings")
	}
	if settled {
		if len(plan.windows) != 0 {
			return nil, fmt.Errorf("settled physical plan cannot contain windows")
		}
		for _, entity := range plan.entities {
			if len(entity.aliases) != 0 || len(entity.reverseWrites) != 0 || entity.insertGeneration != entity.generation {
				return nil, fmt.Errorf("settled physical plan retained window obligations")
			}
		}
	}
	return plan, nil
}

func (plan *pgRowPhysicalPlan) entity(identity string) *pgRowPhysicalEntity {
	for i := range plan.entities {
		if plan.entities[i].identity == identity {
			return &plan.entities[i]
		}
	}
	return nil
}
func (entity *pgRowPhysicalEntity) column(name string) *pgRowPhysicalColumn {
	for i := range entity.columns {
		if entity.columns[i].catalog.Name == name {
			return &entity.columns[i]
		}
	}
	return nil
}
func (entity *pgRowPhysicalEntity) field(name string) string {
	for _, field := range entity.projection {
		if field.logical == name {
			return field.physical
		}
	}
	return ""
}
func (plan *pgRowPhysicalPlan) window(identity string) *pgRowPhysicalWindow {
	for i := range plan.windows {
		if plan.windows[i].entity == identity {
			return &plan.windows[i]
		}
	}
	return nil
}
func pgPhysicalColumnEqual(a, b pgRowPhysicalColumn) bool {
	ac, bc := a.catalog, b.catalog
	if a.introducedVersion != b.introducedVersion || ac.Name != bc.Name || ac.Type != bc.Type || ac.Nullable != bc.Nullable || ac.PrimaryKey != bc.PrimaryKey {
		return false
	}
	if ac.Default == nil || bc.Default == nil {
		return ac.Default == nil && bc.Default == nil
	}
	return *ac.Default == *bc.Default
}
func pgPhysicalIndexEqual(a, b PgMigrationCatalogIndex) bool {
	return a.Name == b.Name && a.Unique == b.Unique && slices.Equal(a.Columns, b.Columns)
}

// Validate a complete retained lineage, including the physical obligations a
// later logical schema omits. This does not grant permission to execute DDL.
func pgValidateRowPhysicalLineage(previous, plan *pgRowPhysicalPlan) error {
	if plan == nil || plan.settled {
		return fmt.Errorf("retained lineage requires a window physical plan")
	}
	if plan.requiresContractVersion > 0 && (previous == nil || !previous.settled) {
		return fmt.Errorf("physical expansion requires settled predecessor from exact contract")
	}
	if plan == nil {
		return fmt.Errorf("missing physical plan")
	}
	if previous == nil {
		if plan.version != 1 || len(plan.windows) != 0 {
			return fmt.Errorf("physical origin must be V1")
		}
	} else if previous.version+1 != plan.version || previous.family != plan.family || previous.namespace != plan.namespace {
		return fmt.Errorf("physical plan has no exact adjacent predecessor")
	}
	for _, entity := range plan.entities {
		var old *pgRowPhysicalEntity
		if previous != nil {
			old = previous.entity(entity.identity)
		}
		window := plan.window(entity.identity)
		if old == nil {
			if entity.generation != 1 || entity.insertGeneration != 1 || len(entity.aliases) != 0 || len(entity.reverseWrites) != 0 || window != nil {
				return fmt.Errorf("new entity has historical write obligations")
			}
			for _, column := range entity.columns {
				if column.introducedVersion != plan.version || column.catalog.Default != nil {
					return fmt.Errorf("new entity has invented physical defaults or origins")
				}
			}
			continue
		}
		if entity.table != old.table || entity.generation < old.generation || entity.generation > old.generation+1 {
			return fmt.Errorf("physical entity changed identity or skipped generation")
		}
		for _, column := range old.columns {
			next := entity.column(column.catalog.Name)
			if next == nil || !pgPhysicalColumnEqual(column, *next) {
				return fmt.Errorf("retained physical column was removed or changed")
			}
		}
		for _, index := range old.indexes {
			if !slices.ContainsFunc(entity.indexes, func(next PgMigrationCatalogIndex) bool {
				return next.Name == index.Name && pgPhysicalIndexEqual(index, next)
			}) {
				return fmt.Errorf("retained physical index was removed or changed")
			}
		}
		if window == nil {
			if entity.generation != old.generation || entity.insertGeneration != old.insertGeneration || !slices.Equal(old.aliases, entity.aliases) || !slices.Equal(old.reverseWrites, entity.reverseWrites) {
				return fmt.Errorf("additive revision changed row generation or aliases")
			}
			for _, field := range old.projection {
				if entity.field(field.logical) != field.physical {
					return fmt.Errorf("additive revision changed a retained projection")
				}
			}
		} else {
			if previous == nil || entity.generation != old.generation+1 || entity.insertGeneration != old.generation || window.previousGeneration != old.generation || window.targetGeneration != entity.generation || window.fromSchemaHash != previous.schemaSnapshotHash {
				return fmt.Errorf("physical window changed source generation or contract")
			}
			var invalidation []string
			for _, field := range old.projection {
				invalidation = append(invalidation, field.physical)
			}
			slices.Sort(invalidation)
			if !slices.Equal(invalidation, window.invalidation) {
				return fmt.Errorf("physical window omits predecessor invalidation")
			}
			for _, field := range entity.projection {
				if old.column(field.physical) != nil && old.field(field.logical) != field.physical {
					return fmt.Errorf("physical window repurposed an existing projection")
				}
			}
			owners := map[string]bool{}
			var expectedAliases []pgRowPhysicalField
			var expectedReverse []pgRowPhysicalReverse
			if len(old.reverseWrites) != 0 {
				return fmt.Errorf("next physical window requires contracted predecessor reverse obligations")
			}
			for _, field := range old.projection {
				owner := field.logical
				reverse, legacy := false, false
				if entity.field(owner) != field.physical {
					owner = ""
					for _, alias := range entity.aliases {
						if alias.physical == field.physical && old.column(entity.field(alias.logical)) == nil {
							owner = alias.logical
						}
					}
					if owner == "" {
						for _, write := range entity.reverseWrites {
							if write.previous == field.logical && write.physical == field.physical {
								if write.legacy && entity.field(field.logical) == "" {
									owner, reverse, legacy = field.logical, true, true
								} else if !write.legacy && old.column(entity.field(write.current)) == nil {
									owner, reverse = write.current, true
								}
							}
						}
					}
					if owner == "" {
						return fmt.Errorf("physical window must preserve, rename or reverse every predecessor projection")
					}
					if reverse {
						expectedReverse = append(expectedReverse, pgRowPhysicalReverse{previous: field.logical, current: owner, physical: field.physical, legacy: legacy})
					} else {
						expectedAliases = append(expectedAliases, pgRowPhysicalField{logical: owner, physical: field.physical})
					}
				}
				if owners[owner] {
					return fmt.Errorf("physical window merged independent predecessor lineages")
				}
				owners[owner] = true
				for _, alias := range old.aliases {
					if alias.logical == field.logical {
						if reverse {
							expectedReverse = append(expectedReverse, pgRowPhysicalReverse{previous: field.logical, current: owner, physical: alias.physical, legacy: legacy})
						} else {
							expectedAliases = append(expectedAliases, pgRowPhysicalField{logical: owner, physical: alias.physical})
						}
					}
				}
			}
			slices.SortFunc(expectedAliases, func(a, b pgRowPhysicalField) int {
				if n := strings.Compare(a.logical, b.logical); n != 0 {
					return n
				}
				return strings.Compare(a.physical, b.physical)
			})
			for i := range expectedReverse {
				if expectedReverse[i].legacy {
					expectedReverse[i].current = ""
				}
			}
			pgSortRowPhysicalReverse(expectedReverse)
			if !slices.Equal(expectedReverse, entity.reverseWrites) {
				return fmt.Errorf("physical window changed exact reverse obligations")
			}
			if !slices.Equal(expectedAliases, entity.aliases) {
				return fmt.Errorf("physical window changed complete historical alias obligations")
			}
		}
		for _, column := range entity.columns {
			if old.column(column.catalog.Name) != nil {
				continue
			}
			if column.introducedVersion != plan.version || column.catalog.PrimaryKey {
				return fmt.Errorf("invalid physical column introduction")
			}
			if window != nil && (!column.catalog.Nullable || column.catalog.Default != nil) {
				return fmt.Errorf("transform target must remain NULL behind its marker")
			}
			if window == nil && !column.catalog.Nullable && column.catalog.Default == nil {
				return fmt.Errorf("additive physical column needs a checked default")
			}
		}
	}
	if previous != nil {
		for _, old := range previous.entities {
			if plan.entity(old.identity) == nil {
				return fmt.Errorf("retained entity was dropped")
			}
		}
	}
	return nil
}

// Protected by pgMigrationRegistrations. Entries originate only in generated
// runtime initialization; parsed documents and exported source inventories do not
// enter this registry.
var compiledRowPhysicalHistories = map[*pgCompiledRowHistory]*pgCompiledRowPhysicalHistory{}

func pgBindRowPhysicalPlan(compiled *pgCompiledRowHistory, previous, plan *pgRowPhysicalPlan) error {
	if compiled == nil || plan.family != compiled.history.Family || plan.namespace != compiled.history.Namespace || plan.version < 1 || plan.version > len(compiled.inventory.Versions) {
		return fmt.Errorf("physical plan has no exact compiled source")
	}
	expectedContract := 0
	if len(plan.windows) > 0 {
		for _, d := range compiled.inventory.Transforms {
			if d.MigrationVersion < plan.version && d.MigrationVersion > expectedContract {
				expectedContract = d.MigrationVersion
			}
		}
	}
	if plan.requiresContractVersion != expectedContract {
		return fmt.Errorf("physical expansion contract prerequisite differs from complete checked history")
	}
	if expectedContract > 0 {
		var err error
		previous, err = pgRowSettledSourceShape(compiled, previous)
		if err != nil {
			return err
		}
	}
	if err := pgValidateRowPhysicalLineage(previous, plan); err != nil {
		return err
	}
	source := compiled.inventory.Versions[plan.version-1]
	if source.Version != plan.version || source.SchemaSnapshotHash != plan.schemaSnapshotHash || source.StorageSnapshotHash != plan.storageSnapshotHash || len(source.Entities) != len(plan.entities) {
		return fmt.Errorf("physical plan source snapshot differs")
	}
	reader := &pgMigrationWireReader{}
	sourceStorage := pgRowDocument(reader, source.StorageContract, source.StorageSnapshotHash, "migration")
	if reader.err != nil || !sourceStorage.list(3) || sourceStorage.children[2].atom {
		return fmt.Errorf("missing exact physical source storage")
	}
	for _, entity := range source.Entities {
		retained := plan.entity(entity.Entity)
		if retained == nil || retained.table != entity.Table || retained.typeContractHash != entity.TypeContractHash || retained.generation != entity.Generation || len(retained.projection) != len(entity.Columns) {
			return fmt.Errorf("physical entity differs from checked source")
		}
		for _, column := range entity.Columns {
			physical := retained.column(retained.field(column.Field))
			if physical == nil || physical.catalog.Name != column.Name || physical.catalog.Type != column.Type || physical.catalog.PrimaryKey != column.PrimaryKey {
				return fmt.Errorf("physical projection differs from nominal source column")
			}
			if (previous == nil || previous.entity(entity.Entity) == nil) && physical.catalog.Nullable != column.Nullable {
				return fmt.Errorf("physical origin changed source nullability")
			}
		}
		expectedIndexes := map[string]PgMigrationCatalogIndex{}
		if previous != nil {
			if old := previous.entity(entity.Entity); old != nil {
				for _, index := range old.indexes {
					expectedIndexes[index.Name] = index
				}
			}
		}
		foundTable := false
		for _, table := range sourceStorage.children[2].children {
			if !table.list(3) || !table.children[0].isAtom(entity.Table) {
				continue
			}
			foundTable = true
			for _, rawIndex := range table.children[2].children {
				if !rawIndex.list(3) || !rawIndex.children[0].atom || rawIndex.children[1].atom {
					return fmt.Errorf("invalid bound source index")
				}
				index := PgMigrationCatalogIndex{Name: rawIndex.children[0].value, Unique: pgRowBool(rawIndex.children[2], true)}
				for _, column := range rawIndex.children[1].children {
					if !column.atom {
						return fmt.Errorf("invalid bound source index column")
					}
					index.Columns = append(index.Columns, column.value)
				}
				if old, ok := expectedIndexes[index.Name]; ok && !pgPhysicalIndexEqual(old, index) {
					return fmt.Errorf("source changed retained index identity")
				}
				expectedIndexes[index.Name] = index
			}
		}
		if !foundTable || len(expectedIndexes) != len(retained.indexes) {
			return fmt.Errorf("physical indexes differ from complete source union")
		}
		for _, index := range retained.indexes {
			expected, ok := expectedIndexes[index.Name]
			if !ok || !pgPhysicalIndexEqual(expected, index) {
				return fmt.Errorf("physical index differs from exact source name and shape")
			}
		}
		window := plan.window(entity.Entity)
		var descriptor *PgRowTransformDescriptor
		for i := range compiled.inventory.Transforms {
			d := &compiled.inventory.Transforms[i]
			if d.MigrationVersion == plan.version && d.Entity == entity.Entity {
				descriptor = d
			}
		}
		if window == nil || descriptor == nil {
			if window != nil || descriptor != nil {
				return fmt.Errorf("physical window lacks exact typed callback")
			}
			continue
		}
		behaviorHash, err := pgRowTransformBehaviorHash(compiled, *descriptor)
		if err != nil {
			return err
		}
		if previous == nil || window.fromSchemaHash != descriptor.FromSchemaSnapshot || window.toSchemaHash != descriptor.ToSchemaSnapshot || window.transformBehaviorHash != behaviorHash || window.previousGeneration != descriptor.PreviousGeneration || window.targetGeneration != descriptor.TargetGeneration {
			return fmt.Errorf("physical window differs from typed callback")
		}
		old := previous.entity(entity.Entity)
		if old == nil {
			return fmt.Errorf("physical callback has no predecessor entity")
		}
		var aliases []pgRowPhysicalField
		for _, mapping := range descriptor.FieldMapping {
			target := retained.column(retained.field(mapping.Target))
			if target == nil {
				return fmt.Errorf("callback target lacks physical projection")
			}
			if mapping.Kind == "copy" || mapping.Kind == "rename" {
				if mapping.Source == nil {
					return fmt.Errorf("callback copy lacks source")
				}
				name := old.field(*mapping.Source)
				from := old.column(name)
				if from == nil || from.catalog.Type != target.catalog.Type {
					return fmt.Errorf("callback copy changed SQL carrier")
				}
				if mapping.Kind == "copy" && target.catalog.Name != name {
					return fmt.Errorf("callback copy changed physical identity")
				}
				if mapping.Kind == "rename" {
					if old.column(target.catalog.Name) != nil {
						return fmt.Errorf("callback rename reused retained physical column")
					}
					aliases = append(aliases, pgRowPhysicalField{logical: mapping.Target, physical: name})
				}
				for _, alias := range old.aliases {
					if alias.logical == *mapping.Source {
						aliases = append(aliases, pgRowPhysicalField{logical: mapping.Target, physical: alias.physical})
					}
				}
			} else {
				if !slices.Contains([]string{"computed", "default", "empty-optional", "retype"}, mapping.Kind) || old.column(target.catalog.Name) != nil {
					return fmt.Errorf("callback target has unsupported physical operation")
				}
			}
		}
		slices.SortFunc(aliases, func(a, b pgRowPhysicalField) int {
			if n := strings.Compare(a.logical, b.logical); n != 0 {
				return n
			}
			return strings.Compare(a.physical, b.physical)
		})
		var reverse []pgRowPhysicalReverse
		for _, write := range descriptor.WriteBacks {
			from := old.column(old.field(write.Previous))
			target := retained.column(retained.field(write.Current))
			if from == nil || target == nil || old.column(target.catalog.Name) != nil {
				return fmt.Errorf("reverse callback lacks new target or previous physical owner")
			}
			reverse = append(reverse, pgRowPhysicalReverse{previous: write.Previous, current: write.Current, physical: from.catalog.Name})
			for _, alias := range old.aliases {
				if alias.logical == write.Previous {
					reverse = append(reverse, pgRowPhysicalReverse{previous: write.Previous, current: write.Current, physical: alias.physical})
				}
			}
		}
		for _, field := range descriptor.LegacyWrites {
			from := old.column(old.field(field))
			if from == nil || from.catalog.PrimaryKey || retained.field(field) != "" {
				return fmt.Errorf("legacy reverse callback lacks exact old-only physical owner")
			}
			reverse = append(reverse, pgRowPhysicalReverse{previous: field, physical: from.catalog.Name, legacy: true})
			for _, alias := range old.aliases {
				if alias.logical == field {
					reverse = append(reverse, pgRowPhysicalReverse{previous: field, physical: alias.physical, legacy: true})
				}
			}
		}
		pgSortRowPhysicalReverse(reverse)
		if !slices.Equal(reverse, retained.reverseWrites) {
			return fmt.Errorf("physical reverse bindings differ from checked WriteBack")
		}
		if !slices.Equal(aliases, retained.aliases) {
			return fmt.Errorf("physical aliases differ from checked copy/rename lineage")
		}
	}
	return nil
}

func registerCompiledRowPhysicalHistory(payload string) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if len(payload) == 0 || len(payload) > pgRowSourceLimit {
		panic("database: invalid physical companion size")
	}
	if err := pgMigrationCheckJSON(payload); err != nil {
		panic(err)
	}
	r := &pgMigrationWireReader{}
	root := r.object(json.RawMessage(payload), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	if pgMigrationRead[int](r, root["version"]) != 1 || pgMigrationRead[string](r, root["kind"]) != "compiled-retained-physical-history" {
		r.fail("unsupported physical companion")
	}
	abi, compatibility := pgMigrationRead[string](r, root["compilerAbi"]), pgMigrationRead[string](r, root["storedValueCompatibility"])
	databases := pgMigrationRead[[]json.RawMessage](r, root["databases"])
	if len(databases) == 0 {
		r.fail("physical companion requires complete databases")
	}
	var pending []*pgCompiledRowPhysicalHistory
	seen := map[string]bool{}
	for _, raw := range databases {
		db := r.object(raw, "database", "family", "namespace", "currentVersion", "versions")
		identity, family, namespace := pgMigrationRead[string](r, db["database"]), pgMigrationRead[string](r, db["family"]), pgMigrationRead[string](r, db["namespace"])
		version := pgMigrationRead[int](r, db["currentVersion"])
		compiled := compiledRowHistories[family]
		if compiled == nil || seen[family] || pgMigrationClosedFamilies[family] {
			r.fail("physical companion source missing, duplicated or closed")
			continue
		}
		seen[family] = true
		h := compiled.history
		if h.Database != identity || h.Namespace != namespace || h.CurrentVersion != version || h.SourceCompilerABI != abi || h.StoredValueCompatibility != compatibility {
			r.fail("physical companion owner/source identity differs")
		}
		entry := &pgCompiledRowPhysicalHistory{compiled: compiled, payload: payload}
		versions := pgMigrationRead[[]json.RawMessage](r, db["versions"])
		if len(versions) != len(compiled.inventory.Versions) {
			r.fail("physical source revision inventory differs")
		}
		var previous *pgRowPhysicalPlan
		for i, raw := range versions {
			encoded := r.object(raw, "contract", "hash")
			plan, err := pgParseRowPhysicalPlan(pgMigrationRead[string](r, encoded["contract"]), pgMigrationRead[string](r, encoded["hash"]))
			if err != nil {
				r.fail(err.Error())
				break
			}
			if plan.version != i+1 {
				r.fail("physical revisions are not complete and ordered")
			}
			if err := pgBindRowPhysicalPlan(compiled, previous, plan); err != nil {
				r.fail(err.Error())
				break
			}
			entry.versions = append(entry.versions, plan)
			previous = plan
		}
		if old := compiledRowPhysicalHistories[compiled]; old != nil && old.payload != payload {
			r.fail("conflicting physical history")
		}
		pending = append(pending, entry)
	}
	// Require the same complete database set as the linked source envelope. An
	// incomplete sidecar must not make an omitted database look unversioned.
	if len(pending) > 0 {
		bases, err := pgReadRowBase(pending[0].compiled.history)
		if err != nil {
			r.fail(err.Error())
		} else if len(bases) != len(pending) {
			r.fail("physical database set is incomplete")
		} else {
			for _, base := range bases {
				if !seen[base.Family] {
					r.fail("physical database set differs")
				}
			}
		}
		for _, entry := range pending {
			if entry.compiled.history.HistoryJSON != pending[0].compiled.history.HistoryJSON {
				r.fail("physical databases belong to different source envelopes")
			}
		}
	}
	if r.err != nil {
		panic(r.err)
	}
	for _, entry := range pending {
		if compiledRowPhysicalHistories[entry.compiled] != nil {
			continue
		}
		for _, plan := range entry.versions {
			plan.compiled = entry.compiled
		}
		compiledRowPhysicalHistories[entry.compiled] = entry
	}
}

func pgCompiledRowPhysicalPlan(database *Database, version int) (*pgRowPhysicalPlan, error) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if database == nil {
		return nil, fmt.Errorf("missing physical database owner")
	}
	history, ok := database.CompiledMigrationHistory()
	if !ok {
		return nil, fmt.Errorf("missing physical source history")
	}
	compiled := compiledRowHistories[history.Family]
	if compiled == nil {
		return nil, fmt.Errorf("missing physical compiled source")
	}
	if err := pgCheckRowOwner(database, compiled); err != nil {
		return nil, err
	}
	database.mutex.RLock()
	sealed := database.applicationPreflightClosed
	database.mutex.RUnlock()
	entry := compiledRowPhysicalHistories[compiled]
	if !sealed || entry == nil || version < 1 || version > len(entry.versions) {
		return nil, fmt.Errorf("physical plan requires a sealed exact application and known revision")
	}
	return entry.versions[version-1], nil
}

// Only the dedicated provenance member is separated. The full local link is
// still validated against this compiler ABI; all source/type/proof/codec/fixture
// and Same judgments remain in the behavior document. A digest never attests
// arbitrary handwritten Go or grants permission to ignore a processing latch.
func pgRowTransformBehaviorHash(compiled *pgCompiledRowHistory, descriptor PgRowTransformDescriptor) (string, error) {
	if compiled == nil {
		return "", fmt.Errorf("missing checked behavior owner")
	}
	r := &pgMigrationWireReader{}
	link := pgRowDocument(r, descriptor.TransformContract, descriptor.TransformContractHash, "migration")
	if r.err != nil || !link.list(5) || !link.children[0].isAtom("checked-transform-link") || !link.children[1].isAtom("1") || !link.children[2].list(2) || !link.children[2].children[0].isAtom("compiler-abi") || !link.children[2].children[1].isAtom(compiled.history.SourceCompilerABI) || link.children[3].atom || link.children[4].atom {
		return "", fmt.Errorf("behavior requires exact locally checked compiler link")
	}
	_, hash := pgRowBaselineDocument(pgRowList(pgRowAtom("checked-transform-behavior"), pgRowAtom("1"), pgRowList(pgRowAtom("stored-value-compatibility"), pgRowAtom(compiled.history.StoredValueCompatibility)), link.children[3], link.children[4]))
	return hash, nil
}

func pgSortRowPhysicalReverse(writes []pgRowPhysicalReverse) {
	slices.SortFunc(writes, func(a, b pgRowPhysicalReverse) int {
		if n := strings.Compare(a.previous, b.previous); n != 0 {
			return n
		}
		if n := strings.Compare(a.current, b.current); n != 0 {
			return n
		}
		return strings.Compare(a.physical, b.physical)
	})
}

// Requires an already compiler-bound window. A successful description check
// does not publish a capability: complete Contract registration owns that step.
func pgBindRowSettledPlan(compiled *pgCompiledRowHistory, window, settled *pgRowPhysicalPlan) error {
	if compiled == nil || window == nil || settled == nil || window.compiled != compiled || window.settled || !settled.settled || settled.compiled != nil ||
		settled.family != window.family || settled.namespace != window.namespace || settled.version != window.version ||
		settled.schemaSnapshotHash != window.schemaSnapshotHash || settled.storageSnapshotHash != window.storageSnapshotHash ||
		len(settled.entities) != len(window.entities) || len(settled.windows) != 0 || settled.version < 1 || settled.version > len(compiled.inventory.Versions) {
		return fmt.Errorf("settled physical description has no exact compiled window")
	}
	source := compiled.inventory.Versions[settled.version-1]
	reader := &pgMigrationWireReader{}
	storage := pgRowDocument(reader, source.StorageContract, source.StorageSnapshotHash, "migration")
	if reader.err != nil || !storage.list(3) || storage.children[2].atom {
		return fmt.Errorf("settled physical plan lacks checked storage source")
	}
	for _, logical := range source.Entities {
		before, after := window.entity(logical.Entity), settled.entity(logical.Entity)
		if before == nil || after == nil || after.table != logical.Table || after.typeContractHash != logical.TypeContractHash ||
			after.generation != logical.Generation || after.insertGeneration != logical.Generation ||
			len(after.columns) != len(logical.Columns) || !slices.Equal(after.projection, before.projection) || len(after.aliases) != 0 || len(after.reverseWrites) != 0 {
			return fmt.Errorf("settled physical entity differs from exact current source")
		}
		for _, column := range logical.Columns {
			old := before.column(before.field(column.Field))
			actual := after.column(after.field(column.Field))
			if old == nil || actual == nil {
				return fmt.Errorf("settled physical projection omitted source column")
			}
			expected := *old
			expected.catalog.Nullable = column.Nullable
			if !pgPhysicalColumnEqual(expected, *actual) {
				return fmt.Errorf("settled physical column changed source carrier or retained provenance")
			}
		}
		expectedIndexes := map[string]PgMigrationCatalogIndex{}
		found := false
		for _, table := range storage.children[2].children {
			if !table.list(3) || !table.children[0].isAtom(logical.Table) {
				continue
			}
			found = true
			if table.children[2].atom {
				return fmt.Errorf("settled source index list malformed")
			}
			for _, raw := range table.children[2].children {
				if !raw.list(3) || !raw.children[0].atom || raw.children[1].atom {
					return fmt.Errorf("settled source index malformed")
				}
				index := PgMigrationCatalogIndex{Name: raw.children[0].value, Unique: pgRowBool(raw.children[2], true)}
				for _, column := range raw.children[1].children {
					if !column.atom {
						return fmt.Errorf("settled index column malformed")
					}
					index.Columns = append(index.Columns, column.value)
				}
				expectedIndexes[index.Name] = index
			}
		}
		if !found || len(expectedIndexes) != len(after.indexes) {
			return fmt.Errorf("settled index inventory differs from source")
		}
		for _, index := range after.indexes {
			expected, ok := expectedIndexes[index.Name]
			if !ok || !pgPhysicalIndexEqual(expected, index) {
				return fmt.Errorf("settled index differs from source")
			}
		}
	}
	return nil
}

// Pure local source-derived shape for checking a later window's prerequisite.
// It has neither a durable hash nor a compiled execution pointer. Runtime
// expansion still requires the exact recorded Contract and its settled plan.
func pgRowSettledSourceShape(compiled *pgCompiledRowHistory, window *pgRowPhysicalPlan) (*pgRowPhysicalPlan, error) {
	if compiled == nil || window == nil || window.version < 1 || window.version > len(compiled.inventory.Versions) {
		return nil, fmt.Errorf("settled source shape lacks checked predecessor")
	}
	result := *window
	result.compiled = nil
	result.settled = true
	result.requiresContractVersion = 0
	result.hash = ""
	result.contract = ""
	result.windows = nil
	result.entities = nil
	source := compiled.inventory.Versions[window.version-1]
	reader := &pgMigrationWireReader{}
	storage := pgRowDocument(reader, source.StorageContract, source.StorageSnapshotHash, "migration")
	if reader.err != nil || !storage.list(3) || storage.children[2].atom {
		return nil, fmt.Errorf("settled predecessor lacks checked source storage")
	}
	for _, logical := range source.Entities {
		old := window.entity(logical.Entity)
		if old == nil {
			return nil, fmt.Errorf("settled predecessor entity missing")
		}
		e := *old
		e.insertGeneration = e.generation
		e.aliases = nil
		e.reverseWrites = nil
		e.columns = nil
		e.indexes = nil
		for _, field := range logical.Columns {
			oldColumn := old.column(old.field(field.Field))
			if oldColumn == nil {
				return nil, fmt.Errorf("settled predecessor column missing")
			}
			column := *oldColumn
			column.catalog.Nullable = field.Nullable
			e.columns = append(e.columns, column)
		}
		slices.SortFunc(e.columns, func(a, b pgRowPhysicalColumn) int { return strings.Compare(a.catalog.Name, b.catalog.Name) })
		found := false
		for _, table := range storage.children[2].children {
			if !table.list(3) || !table.children[0].isAtom(logical.Table) {
				continue
			}
			found = true
			if table.children[2].atom {
				return nil, fmt.Errorf("settled predecessor indexes malformed")
			}
			for _, raw := range table.children[2].children {
				if !raw.list(3) || !raw.children[0].atom || raw.children[1].atom {
					return nil, fmt.Errorf("settled predecessor index malformed")
				}
				index := PgMigrationCatalogIndex{Name: raw.children[0].value, Unique: pgRowBool(raw.children[2], true)}
				for _, c := range raw.children[1].children {
					if !c.atom {
						return nil, fmt.Errorf("settled predecessor index column malformed")
					}
					index.Columns = append(index.Columns, c.value)
				}
				e.indexes = append(e.indexes, index)
			}
		}
		if !found {
			return nil, fmt.Errorf("settled predecessor source table missing")
		}
		slices.SortFunc(e.indexes, func(a, b PgMigrationCatalogIndex) int { return strings.Compare(a.Name, b.Name) })
		result.entities = append(result.entities, e)
	}
	return &result, nil
}
