package teslrt

import (
	"encoding/json"
	"fmt"
	"reflect"
)

// All maps and sealing state below are protected by pgMigrationRegistrations.
// The heterogeneous registry retains metadata only. The callback remains in its
// concrete generic handle and never passes through an interface or a cast.
type pgCompiledRowHistory struct {
	history   PgCompiledMigrationHistory
	payload   string
	inventory PgRowSourceInventory
}
type pgRowRegistration struct {
	database          *Database
	compiled          *pgCompiledRowHistory
	index             int
	sealed            bool
	storageAttached   bool
	writeBackAttached bool
	accessAttached    bool
}

var compiledRowHistories = map[string]*pgCompiledRowHistory{}
var compiledRowRegistrations = map[*pgCompiledRowHistory]map[int]*pgRowRegistration{}

// Called by compiler-generated runtime initialization only, after every base
// history is linked. Validate the entire multi-database artifact before publishing.
func registerCompiledRowHistory(payload string) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if len(payload) == 0 || len(payload) > pgRowSourceLimit {
		panic("database: invalid compiled row history size")
	}
	if err := pgMigrationCheckJSON(payload); err != nil {
		panic(err)
	}
	r := &pgMigrationWireReader{}
	o := r.object(json.RawMessage(payload), "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	dbs := pgMigrationRead[[]json.RawMessage](r, o["databases"])
	if len(dbs) == 0 {
		r.fail("row companion requires a database")
	}
	var linked []PgCompiledMigrationHistory
	for _, raw := range dbs {
		d := r.object(raw, "database", "family", "namespace", "currentVersion", "transforms")
		family := pgMigrationRead[string](r, d["family"])
		value, exists := compiledMigrationHistories.Load(family)
		if !exists {
			r.fail("row companion has no linked base history")
			continue
		}
		history := value.(PgCompiledMigrationHistory) //nolint:forcetypeassert // private base registry
		linked = append(linked, history)
		if pgMigrationClosedFamilies[family] {
			r.fail("row source registration is closed")
		}
	}
	if r.err != nil {
		panic(r.err)
	}
	if len(linked) == 0 {
		panic("database: row companion requires a linked base history")
	}
	inventories, err := pgReadRowCompanion(linked[0], payload)
	if err != nil {
		panic(err)
	}
	pending := make([]*pgCompiledRowHistory, 0, len(inventories))
	for i, inventory := range inventories {
		history := linked[i]
		if history.HistoryJSON != linked[0].HistoryJSON || history.Database != inventory.Database || history.Family != inventory.Family || history.Namespace != inventory.Namespace || history.CurrentVersion != inventory.CurrentVersion || history.SourceCompilerABI != linked[0].SourceCompilerABI || history.StoredValueCompatibility != linked[0].StoredValueCompatibility {
			panic("database: row companion disagrees with linked database history")
		}
		if previous := compiledRowHistories[history.Family]; previous != nil {
			if previous.history != history || previous.payload != payload {
				panic("database: conflicting compiled row histories")
			}
			pending = append(pending, previous)
		} else {
			pending = append(pending, &pgCompiledRowHistory{history: history, payload: payload, inventory: inventory})
		}
	}
	for _, compiled := range pending {
		compiledRowHistories[compiled.history.Family] = compiled
	}
}

// RowSourceInventory returns a defensive copy of the compiler's checked source
// descriptions. It reports neither applied migrations nor physical row layouts.
func (history PgCompiledMigrationHistory) RowSourceInventory() (PgRowSourceInventory, error) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	compiled := compiledRowHistories[history.Family]
	if compiled == nil || compiled.history != history {
		return PgRowSourceInventory{}, fmt.Errorf("missing exact compiled row source history")
	}
	// Reparse the immutable linked artifact to avoid exposing any owned slice or
	// mapping operand pointer to callers. This never reads source or loose files.
	inventories, err := pgReadRowCompanion(history, compiled.payload)
	if err != nil {
		return PgRowSourceInventory{}, err
	}
	for _, inventory := range inventories {
		if inventory.Family == history.Family {
			return inventory, nil
		}
	}
	return PgRowSourceInventory{}, fmt.Errorf("missing compiled row source database")
}

// PgRowTransformSourceRef is an opaque selection of a private linked descriptor
// and the actual owning database. Its zero value grants no registration rights.
type PgRowTransformSourceRef struct {
	database *Database
	compiled *pgCompiledRowHistory
	index    int
}

func pgCheckRowOwner(database *Database, compiled *pgCompiledRowHistory) error {
	if database == nil || compiled == nil {
		return fmt.Errorf("missing compiled row source reference")
	}
	history, ok := database.CompiledMigrationHistory()
	owner, exists := databaseIdentities.Load(compiled.history.Database)
	if !ok || history != compiled.history || !exists || owner != database || database.Config.Schema != history.Namespace {
		return fmt.Errorf("row source belongs to another database connection")
	}
	return nil
}

// LookupCompiledRowTransform selects a descriptor already linked by the compiler;
// supplying matching names cannot manufacture a transform or a checked contract.
func LookupCompiledRowTransform(database *Database, family string, migrationVersion int, entity string) PgRowTransformSourceRef {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	compiled := compiledRowHistories[family]
	if compiled == nil {
		panic(fmt.Errorf("missing compiled row source reference"))
	}
	if err := pgCheckRowOwner(database, compiled); err != nil {
		panic(err)
	}
	for i, d := range compiled.inventory.Transforms {
		if d.MigrationVersion == migrationVersion && d.Entity == entity {
			return PgRowTransformSourceRef{database: database, compiled: compiled, index: i}
		}
	}
	panic("database: missing compiled row transform")
}

// PgRowTransform retains a statically typed compiler-emitted function. It is a
// local callback binding; Run does not migrate persisted rows or authorize DDL.
type PgRowTransform[From, To any] struct {
	registration *pgRowRegistration
	callback     func(From) Migrated[To]
}

// RegisterCompiledRowTransform is emitted with explicit exact source and target
// entity types. Go nominal layout is checked in addition to the compiler's source
// contracts, so a same-shaped function from another generated version cannot be
// attached to this descriptor. No structural or JSON conversion is performed.
func RegisterCompiledRowTransform[From, To any](ref PgRowTransformSourceRef, fn func(From) Migrated[To]) *PgRowTransform[From, To] {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if err := pgCheckRowOwner(ref.database, ref.compiled); err != nil {
		panic(err)
	}
	if fn == nil || ref.index < 0 || ref.index >= len(ref.compiled.inventory.Transforms) {
		panic("database: invalid compiled row callback")
	}
	if pgMigrationClosedFamilies[ref.compiled.history.Family] {
		panic("database: row callback registration is closed")
	}
	d := ref.compiled.inventory.Transforms[ref.index]
	from, _ := pgRowFindEntity(ref.compiled.inventory.Versions[d.MigrationVersion-2], d.Entity)
	to, _ := pgRowFindEntity(ref.compiled.inventory.Versions[d.MigrationVersion-1], d.Entity)
	match := func(actual reflect.Type, entity PgRowSourceEntity) bool {
		return actual.Kind() == reflect.Struct && actual.Name() == entity.GoTypeName && actual.PkgPath() == entity.GoTypePackage
	}
	if !match(reflect.TypeFor[From](), from) || !match(reflect.TypeFor[To](), to) {
		panic("database: row callback nominal types disagree with the compiler-owned source inventory")
	}
	registrations := compiledRowRegistrations[ref.compiled]
	if registrations == nil {
		registrations = map[int]*pgRowRegistration{}
		compiledRowRegistrations[ref.compiled] = registrations
	}
	if registrations[ref.index] != nil {
		panic("database: duplicate compiled row callback")
	}
	registration := &pgRowRegistration{database: ref.database, compiled: ref.compiled, index: ref.index}
	registrations[ref.index] = registration
	return &PgRowTransform[From, To]{registration: registration, callback: fn}
}

// Run is available only after atomic application preflight has verified and
// sealed every required binding. A callback rejection is an ordinary result;
// unknown result tags are errors and can never be treated as accepted rows.
func (transform *PgRowTransform[From, To]) Run(from From) (Migrated[To], error) {
	pgMigrationRegistrations.Lock()
	ready := transform != nil && transform.registration != nil && transform.registration.sealed && transform.callback != nil
	pgMigrationRegistrations.Unlock()
	if !ready {
		return Migrated[To]{}, fmt.Errorf("row callback is not sealed by application preflight")
	}
	result := transform.callback(from)
	if result.Tag != MigratedRow && result.Tag != MigratedReject {
		return Migrated[To]{}, fmt.Errorf("row callback returned an invalid Migrated tag")
	}
	return result, nil
}

// Called under the registration transaction, before any closure is published.
func pgCheckApplicationRowTransforms(database *Database, history PgCompiledMigrationHistory) ([]*pgRowRegistration, error) {
	compiled := compiledRowHistories[history.Family]
	if compiled == nil {
		// Recognize only the header for absence detection; registration itself
		// validates the whole closed artifact. Legacy histories need no companion.
		var header struct {
			Version int    `json:"version"`
			Kind    string `json:"kind"`
		}
		if err := json.Unmarshal([]byte(history.HistoryJSON), &header); err != nil {
			return nil, fmt.Errorf("invalid compiled migration history")
		}
		if header.Version == 4 || header.Kind == "compiled-migration-source-history" {
			return nil, fmt.Errorf("missing compiled row source companion")
		}
		return nil, nil
	}
	if err := pgCheckRowOwner(database, compiled); err != nil {
		return nil, err
	}
	registrations := compiledRowRegistrations[compiled]
	if len(registrations) != len(compiled.inventory.Transforms) {
		return nil, fmt.Errorf("compiled row callback bindings are incomplete")
	}
	result := make([]*pgRowRegistration, 0, len(registrations))
	for i := range compiled.inventory.Transforms {
		registration := registrations[i]
		if registration == nil || registration.database != database || registration.compiled != compiled || registration.index != i {
			return nil, fmt.Errorf("compiled row callback belongs to another source or database")
		}
		if len(compiled.inventory.Transforms[i].SourceProjection) != 0 && !registration.storageAttached {
			return nil, fmt.Errorf("compiled row storage adapter bindings are incomplete")
		}
		if len(compiled.inventory.Transforms[i].WriteBacks)+len(compiled.inventory.Transforms[i].LegacyWrites) != 0 && !registration.writeBackAttached {
			return nil, fmt.Errorf("compiled WriteBack adapter bindings are incomplete")
		}
		if compiledRowPhysicalHistories[compiled] != nil && !registration.accessAttached {
			return nil, fmt.Errorf("compiled row entity access bindings are incomplete")
		}
		result = append(result, registration)
	}
	return result, nil
}
