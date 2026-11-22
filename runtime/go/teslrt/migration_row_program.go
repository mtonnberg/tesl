package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
)

// All maps and sealing state below are protected by pgMigrationRegistrations.
// The heterogeneous registry retains metadata only. The callback remains in its
// concrete generic handle and never passes through an interface or a cast.
type pgCompiledRowHistory struct {
	history PgCompiledMigrationHistory
	payload string
	format  int
	// Decoded from the linked bytes at registration and never modified. They are
	// the same values the complete inventory carries. A transform descriptor is
	// used to bind generated callbacks immediately but is validated against its
	// source versions only by transformChecked, before any use of that transform.
	transforms  []PgRowTransformDescriptor
	codecs      []PgRowCurrentCodecDescriptor
	retirements []PgRowRetirementDescriptor
	checked     map[int]bool // transforms validated inside the serving window
	full        pgMemo[PgRowSourceInventory]
}
type pgRowRegistration struct {
	database          *Database
	compiled          *pgCompiledRowHistory
	index             int
	sealed            bool
	storageAttached   bool
	writeBackAttached bool
	accessAttached    bool
	// Nominal callback types, compared with the source inventory once the
	// descriptor's adjacent source versions are validated.
	from, to     reflect.Type
	typesChecked bool
}

var compiledRowHistories = map[string]*pgCompiledRowHistory{}
var compiledRowRegistrations = map[*pgCompiledRowHistory]map[int]*pgRowRegistration{}

// complete validates the entire row companion together with the complete
// source history, once per process.
func (compiled *pgCompiledRowHistory) complete() (PgRowSourceInventory, error) {
	return compiled.full.get(func() (PgRowSourceInventory, error) {
		pgHistoryCounters.complete.Add(1)
		inventories, err := pgReadRowCompanion(compiled.history, compiled.payload)
		if err != nil {
			return PgRowSourceInventory{}, err
		}
		for _, inventory := range inventories {
			if inventory.Family == compiled.history.Family {
				return inventory, nil
			}
		}
		return PgRowSourceInventory{}, fmt.Errorf("missing compiled row source database")
	})
}

// version returns one validated source version (see pgLinkedSource.version).
func (compiled *pgCompiledRowHistory) version(k int) (PgRowSourceVersion, error) {
	if source := pgLinkedSourceOf(compiled.history); source != nil {
		return source.version(compiled.history.Family, k)
	}
	inventory, err := compiled.complete()
	if err != nil {
		return PgRowSourceVersion{}, err
	}
	if k < 1 || k > len(inventory.Versions) {
		return PgRowSourceVersion{}, fmt.Errorf("source version V%d is outside the linked history", k)
	}
	return inventory.Versions[k-1], nil
}

// mustVersion is version for registration paths that already panic on error.
func (compiled *pgCompiledRowHistory) mustVersion(k int) PgRowSourceVersion {
	v, err := compiled.version(k)
	if err != nil {
		panic(err)
	}
	return v
}

// transformChecked validates transform i against its adjacent source versions.
// Outside the serving window this validates the complete companion. The caller
// holds pgMigrationRegistrations.
func (compiled *pgCompiledRowHistory) transformChecked(i int) error {
	if i < 0 || i >= len(compiled.transforms) {
		return fmt.Errorf("missing compiled row transform")
	}
	if compiled.checked[i] {
		return nil
	}
	if _, err := compiled.complete(); err != nil {
		return err
	}
	compiled.checked[i] = true
	return nil
}

// pgCheckRowRegistrationTypes compares a callback's nominal Go types with the
// validated source inventory. It runs before the callback or its storage is
// used, and for every binding when the complete history is validated.
func pgCheckRowRegistrationTypes(registration *pgRowRegistration) error {
	if registration.typesChecked {
		return nil
	}
	compiled := registration.compiled
	if err := compiled.transformChecked(registration.index); err != nil {
		return err
	}
	d := compiled.transforms[registration.index]
	fromVersion, err := compiled.version(d.MigrationVersion - 1)
	if err != nil {
		return err
	}
	toVersion, err := compiled.version(d.MigrationVersion)
	if err != nil {
		return err
	}
	from, _ := pgRowFindEntity(fromVersion, d.Entity)
	to, _ := pgRowFindEntity(toVersion, d.Entity)
	match := func(actual reflect.Type, entity PgRowSourceEntity) bool {
		return actual != nil && actual.Kind() == reflect.Struct && actual.Name() == entity.GoTypeName && actual.PkgPath() == entity.GoTypePackage
	}
	if !match(registration.from, from) || !match(registration.to, to) {
		return fmt.Errorf("database: row callback nominal types disagree with the compiler-owned source inventory")
	}
	registration.typesChecked = true
	return nil
}

// Called by compiler-generated runtime initialization only, after every base
// history is linked. Checks integrity, identity and the serving window of the
// entire multi-database artifact before publishing; see migration_history_lazy.go.
func registerCompiledRowHistory(payload string) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if len(payload) == 0 || len(payload) > pgRowSourceLimit {
		panic("database: invalid compiled row history size")
	}
	if err := pgJSONIntegrity(payload); err != nil {
		panic(err)
	}
	root, err := pgJSONObject(payload, "version", "kind", "compilerAbi", "storedValueCompatibility", "databases")
	if err != nil {
		panic(err)
	}
	version, err := pgJSONValue[int](root["version"])
	if err != nil {
		panic(err)
	}
	dbs, err := pgJSONArray(root["databases"])
	if err != nil {
		panic(err)
	}
	if len(dbs) == 0 {
		panic("invalid compiled migration history: row companion requires a database")
	}
	var linked []PgCompiledMigrationHistory
	var entries []map[string]string
	for _, raw := range dbs {
		fields := []string{"database", "family", "namespace", "currentVersion", "transforms"}
		if version == 5 {
			fields = append(fields, "currentCodecs")
		}
		d, err := pgJSONObject(raw, fields...)
		if err != nil {
			panic(err)
		}
		family, err := pgJSONValue[string](d["family"])
		if err != nil {
			panic(err)
		}
		value, exists := compiledMigrationHistories.Load(family)
		if !exists {
			panic("invalid compiled migration history: row companion has no linked base history")
		}
		history := value.(PgCompiledMigrationHistory) //nolint:forcetypeassert // private base registry
		if pgMigrationClosedFamilies[family] {
			panic("invalid compiled migration history: row source registration is closed")
		}
		linked = append(linked, history)
		entries = append(entries, d)
	}
	pending := make([]*pgCompiledRowHistory, 0, len(linked))
	for i, history := range linked {
		if history.HistoryJSON != linked[0].HistoryJSON || history.SourceCompilerABI != linked[0].SourceCompilerABI || history.StoredValueCompatibility != linked[0].StoredValueCompatibility {
			panic("database: row companion disagrees with linked database history")
		}
		if previous := compiledRowHistories[history.Family]; previous != nil {
			if previous.history != history || previous.payload != payload {
				panic("database: conflicting compiled row histories")
			}
			pending = append(pending, previous)
			continue
		}
		compiled := &pgCompiledRowHistory{history: history, payload: payload, format: version, checked: map[int]bool{}}
		if err := pgRowRegistrationWindow(compiled, root, entries[i], len(dbs)); err != nil {
			panic(err)
		}
		pending = append(pending, compiled)
	}
	for _, compiled := range pending {
		compiledRowHistories[compiled.history.Family] = compiled
	}
}

// pgRowRegistrationWindow validates one database's row companion entry. Small
// histories and legacy source formats are validated completely, as before.
func pgRowRegistrationWindow(compiled *pgCompiledRowHistory, root, fields map[string]string, databases int) error {
	history := compiled.history
	source := pgLinkedSourceOf(history)
	complete := source == nil || pgHistoryInWindow(history.CurrentVersion)
	var header *pgLinkedSourceHeader
	if !complete {
		var err error
		if header, err = source.readHeader(); err != nil {
			complete = true
		}
	}
	if complete {
		inventory, err := compiled.complete()
		if err != nil {
			return err
		}
		compiled.transforms, compiled.codecs, compiled.retirements = inventory.Transforms, inventory.CurrentCodecs, inventory.Retirements
		for i := range compiled.transforms {
			compiled.checked[i] = true
		}
		return nil
	}
	if err := source.window(history.Family); err != nil {
		return err
	}
	kind, err := pgJSONValue[string](root["kind"])
	if err != nil {
		return err
	}
	abi, err := pgJSONValue[string](root["compilerAbi"])
	if err != nil {
		return err
	}
	compatibility, err := pgJSONValue[string](root["storedValueCompatibility"])
	if err != nil {
		return err
	}
	format := compiled.format
	if (format < 1 || format > 5) || kind != "compiled-row-transform-history" || abi != history.SourceCompilerABI || compatibility != history.StoredValueCompatibility {
		return fmt.Errorf("invalid compiled migration history: row companion format or linked ABI mismatch")
	}
	if len(header.databases) != databases {
		return fmt.Errorf("invalid compiled migration history: row companion database inventory is incomplete")
	}
	database, err := pgJSONValue[string](fields["database"])
	if err != nil {
		return err
	}
	namespace, err := pgJSONValue[string](fields["namespace"])
	if err != nil {
		return err
	}
	current, err := pgJSONValue[int](fields["currentVersion"])
	if err != nil {
		return err
	}
	if database != history.Database || namespace != history.Namespace || current != history.CurrentVersion {
		return fmt.Errorf("invalid compiled migration history: row companion database identity mismatch")
	}
	sourceDatabase, err := source.database(history.Family)
	if err != nil {
		return err
	}
	compiled.retirements = sourceDatabase.retirements
	raws, err := pgJSONArray(fields["transforms"])
	if err != nil {
		return err
	}
	r := &pgMigrationWireReader{}
	lastVersion, lastEntity := 0, ""
	for _, raw := range raws {
		d := pgRowDescriptorFields(r, json.RawMessage(raw), format)
		if r.err != nil {
			return r.err
		}
		if d.MigrationVersion < 2 || d.MigrationVersion > current || d.MigrationVersion < lastVersion || d.MigrationVersion == lastVersion && d.Entity <= lastEntity {
			return fmt.Errorf("invalid compiled migration history: unexpected, duplicated or unordered row transform")
		}
		lastVersion, lastEntity = d.MigrationVersion, d.Entity
		compiled.transforms = append(compiled.transforms, d)
	}
	previous, err := compiled.version(current - 1)
	if err != nil {
		return err
	}
	last, err := compiled.version(current)
	if err != nil {
		return err
	}
	// The transforms targeting the current version are validated now, and they
	// must be exactly the current version's generation transitions.
	expected := map[string]bool{}
	for _, e := range last.Entities {
		if old, exists := pgRowFindEntity(previous, e.Entity); exists && e.Generation == old.Generation+1 {
			expected[e.Entity] = true
		}
	}
	for i, d := range compiled.transforms {
		if d.MigrationVersion != current {
			continue
		}
		pgHistoryCounters.elements.Add(1)
		if err := pgMigrationCheckJSON(raws[i]); err != nil {
			return err
		}
		pgRowCheckDescriptor(r, d, history.Family, previous, last, history.SourceCompilerABI, format)
		if !expected[d.Entity] {
			r.fail("unexpected, duplicated or unordered row transform")
		}
		delete(expected, d.Entity)
		compiled.checked[i] = true
	}
	if len(expected) != 0 {
		r.fail("row companion omits a generation transition")
	}
	if format == 5 {
		if err := pgMigrationCheckJSON(fields["currentCodecs"]); err != nil {
			return err
		}
		compiled.codecs = pgReadRowCurrentCodecsAt(r, json.RawMessage(fields["currentCodecs"]), compiled.transforms, current, last, true)
	}
	first, err := compiled.version(1)
	if err != nil {
		return err
	}
	pgRowCheckColumnOriginsAt(r, first, PgRowSourceVersion{}, true, compiled.transforms, format)
	pgRowCheckColumnOriginsAt(r, last, previous, false, compiled.transforms, format)
	return r.err
}

// RowSourceInventory returns a defensive copy of the compiler's checked source
// descriptions. It reports neither applied migrations nor physical row layouts.
// It validates the complete history.
func (history PgCompiledMigrationHistory) RowSourceInventory() (PgRowSourceInventory, error) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	compiled := compiledRowHistories[history.Family]
	if compiled == nil || compiled.history != history {
		return PgRowSourceInventory{}, fmt.Errorf("missing exact compiled row source history")
	}
	inventory, err := compiled.complete()
	if err != nil {
		return PgRowSourceInventory{}, err
	}
	// The complete inventory is shared; never expose its slices or pointers.
	return pgCloneRowSourceInventory(inventory), nil
}

func pgCloneRowSourceInventory(inventory PgRowSourceInventory) PgRowSourceInventory {
	clone := func(s *string) *string {
		if s == nil {
			return nil
		}
		v := *s
		return &v
	}
	result := inventory
	result.Versions = slices.Clone(inventory.Versions)
	for i := range result.Versions {
		v := &result.Versions[i]
		v.Entities = slices.Clone(v.Entities)
		for j := range v.Entities {
			v.Entities[j].Columns = slices.Clone(v.Entities[j].Columns)
		}
	}
	result.Transforms = slices.Clone(inventory.Transforms)
	for i := range result.Transforms {
		d := &result.Transforms[i]
		d.LegacyWrites, d.WriteBacks = slices.Clone(d.LegacyWrites), slices.Clone(d.WriteBacks)
		d.SourceSchemaColumns, d.TargetSchemaColumns = slices.Clone(d.SourceSchemaColumns), slices.Clone(d.TargetSchemaColumns)
		d.SourceProjection, d.TargetProjection = slices.Clone(d.SourceProjection), slices.Clone(d.TargetProjection)
		d.FieldMapping = slices.Clone(d.FieldMapping)
		for j := range d.FieldMapping {
			d.FieldMapping[j].Source, d.FieldMapping[j].Constant = clone(d.FieldMapping[j].Source), clone(d.FieldMapping[j].Constant)
		}
	}
	result.CurrentCodecs = slices.Clone(inventory.CurrentCodecs)
	for i := range result.CurrentCodecs {
		result.CurrentCodecs[i].Projection = slices.Clone(result.CurrentCodecs[i].Projection)
	}
	result.Retirements = slices.Clone(inventory.Retirements)
	return result
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
	for i, d := range compiled.transforms {
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
	callback     func(From) RowChange[To]
}

// RegisterCompiledRowTransform is emitted with explicit exact source and target
// entity types. Go nominal layout is checked in addition to the compiler's source
// contracts, so a same-shaped function from another generated version cannot be
// attached to this descriptor. No structural or JSON conversion is performed.
func RegisterCompiledRowTransform[From, To any](ref PgRowTransformSourceRef, fn func(From) Migrated[To]) *PgRowTransform[From, To] {
	if fn == nil {
		panic("database: invalid compiled row callback")
	}
	return RegisterCompiledRowChange(ref, func(value From) RowChange[To] {
		result := fn(value)
		switch result.Tag {
		case MigratedRow:
			return RowChange[To]{Tag: RowChangeKeep, KeepValue: result.RowValue}
		case MigratedReject:
			return RowChange[To]{Tag: RowChangeReject, Reason: result.RejectReason}
		default:
			return RowChange[To]{Tag: -1}
		}
	})
}

func RegisterCompiledRowChange[From, To any](ref PgRowTransformSourceRef, fn func(From) RowChange[To]) *PgRowTransform[From, To] {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if err := pgCheckRowOwner(ref.database, ref.compiled); err != nil {
		panic(err)
	}
	if fn == nil || ref.index < 0 || ref.index >= len(ref.compiled.transforms) {
		panic("database: invalid compiled row callback")
	}
	if pgMigrationClosedFamilies[ref.compiled.history.Family] {
		panic("database: row callback registration is closed")
	}
	registration := &pgRowRegistration{database: ref.database, compiled: ref.compiled, index: ref.index, from: reflect.TypeFor[From](), to: reflect.TypeFor[To]()}
	// A transform inside the serving window is checked now; an older one is
	// checked before its first use and by complete validation.
	if ref.compiled.checked[ref.index] {
		if err := pgCheckRowRegistrationTypes(registration); err != nil {
			panic(err.Error())
		}
	}
	registrations := compiledRowRegistrations[ref.compiled]
	if registrations == nil {
		registrations = map[int]*pgRowRegistration{}
		compiledRowRegistrations[ref.compiled] = registrations
	}
	if registrations[ref.index] != nil {
		panic("database: duplicate compiled row callback")
	}
	registrations[ref.index] = registration
	return &PgRowTransform[From, To]{registration: registration, callback: fn}
}

// Run is available only after atomic application preflight has verified and
// sealed every required binding. A callback rejection is an ordinary result;
// unknown result tags are errors and can never be treated as accepted rows.
func (transform *PgRowTransform[From, To]) Run(from From, contexts ...context.Context) (result RowChange[To], err error) {
	pgMigrationRegistrations.Lock()
	ready := transform != nil && transform.registration != nil && transform.registration.sealed && transform.callback != nil
	var checked error
	if ready {
		// A transform outside the serving window is validated before it runs.
		checked = pgCheckRowRegistrationTypes(transform.registration)
	}
	pgMigrationRegistrations.Unlock()
	if !ready {
		return RowChange[To]{}, fmt.Errorf("row callback is not sealed by application preflight")
	}
	if checked != nil {
		return RowChange[To]{}, checked
	}
	defer func() {
		if trapped := recover(); trapped != nil {
			result = RowChange[To]{}
			err = fmt.Errorf("row conversion trapped")
			if failure, bounded := trapped.(migrationExecutionFailure); bounded {
				err = failure
			}
		}
	}()
	defer BeginMigrationExecution(contexts...)()
	result = transform.callback(from)
	MigrationStep()
	if result.Tag != RowChangeKeep && result.Tag != RowChangeReject && result.Tag != RowChangeDelete {
		return RowChange[To]{}, fmt.Errorf("row callback returned an invalid result tag")
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
	if len(registrations) != len(compiled.transforms) {
		return nil, fmt.Errorf("compiled row callback bindings are incomplete")
	}
	result := make([]*pgRowRegistration, 0, len(registrations))
	for i := range compiled.transforms {
		registration := registrations[i]
		if registration == nil || registration.database != database || registration.compiled != compiled || registration.index != i {
			return nil, fmt.Errorf("compiled row callback belongs to another source or database")
		}
		if len(compiled.transforms[i].SourceProjection) != 0 && !registration.storageAttached {
			return nil, fmt.Errorf("compiled row storage adapter bindings are incomplete")
		}
		if len(compiled.transforms[i].WriteBacks)+len(compiled.transforms[i].LegacyWrites) != 0 && !registration.writeBackAttached {
			return nil, fmt.Errorf("compiled WriteBack adapter bindings are incomplete")
		}
		if compiledRowPhysicalHistories[compiled] != nil && !registration.accessAttached {
			return nil, fmt.Errorf("compiled row entity access bindings are incomplete")
		}
		result = append(result, registration)
	}
	return result, nil
}
