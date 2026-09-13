package teslrt

import (
	"fmt"
	"reflect"
	"slices"

	"github.com/jackc/pgx/v5"
)

// Registration retains metadata only. The concrete codec functions remain in
// PgRowCurrentStorage[Row], alongside the exact generated nominal row type.
type pgRowCurrentRegistration struct {
	database               *Database
	compiled               *pgCompiledRowHistory
	index                  int
	plan                   *pgRowPhysicalPlan
	entity                 *pgRowPhysicalEntity
	sealed, accessAttached bool
}

var compiledRowCurrentRegistrations = map[*pgCompiledRowHistory]map[int]*pgRowCurrentRegistration{}

type PgRowCurrentSourceRef struct {
	database *Database
	compiled *pgCompiledRowHistory
	index    int
}

func LookupCompiledRowCurrent(database *Database, family string, version int, entity string) PgRowCurrentSourceRef {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	compiled := compiledRowHistories[family]
	if err := pgCheckRowOwner(database, compiled); err != nil {
		panic(err)
	}
	for i, d := range compiled.inventory.CurrentCodecs {
		if d.SchemaVersion == version && d.Entity == entity {
			return PgRowCurrentSourceRef{database, compiled, i}
		}
	}
	panic("database: missing compiled current row codec")
}

type PgRowCurrentStorage[Row any] struct {
	registration *pgRowCurrentRegistration
	projection   *pgRowProjection
	decode       func(pgx.CollectableRow) (Row, error)
	encode       func(Row) ([]any, error)
}

// PgCompiledRowCodec binds positional codecs to the field order emitted beside
// those codecs. It only checks an existing source descriptor; it grants no SQL
// or migration authority. Its contents cannot be changed by a registering caller.
type PgCompiledRowCodec[Row any] struct {
	fields []string
	decode func(pgx.CollectableRow) (Row, error)
	encode func(Row) ([]any, error)
}

func NewCompiledRowCodec[Row any](fields []string, decode func(pgx.CollectableRow) (Row, error), encode func(Row) ([]any, error)) PgCompiledRowCodec[Row] {
	return PgCompiledRowCodec[Row]{fields: slices.Clone(fields), decode: decode, encode: encode}
}

func pgCheckCurrentCodecOrder[Row any](codec PgCompiledRowCodec[Row], descriptor PgRowCurrentCodecDescriptor) error {
	if codec.decode == nil || codec.encode == nil || len(codec.fields) == 0 || !slices.Equal(codec.fields, descriptor.Projection) {
		return fmt.Errorf("database: current row codec order differs from compiler-owned source inventory")
	}
	return nil
}

func RegisterCompiledRowCurrentStorage[Row any](ref PgRowCurrentSourceRef, codec PgCompiledRowCodec[Row]) *PgRowCurrentStorage[Row] {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if err := pgCheckRowOwner(ref.database, ref.compiled); err != nil {
		panic(err)
	}
	if ref.index < 0 || ref.index >= len(ref.compiled.inventory.CurrentCodecs) {
		panic("database: invalid current row codec")
	}
	if pgMigrationClosedFamilies[ref.compiled.history.Family] {
		panic("database: current row codec registration is closed")
	}
	d := ref.compiled.inventory.CurrentCodecs[ref.index]
	if err := pgCheckCurrentCodecOrder(codec, d); err != nil {
		panic(err)
	}
	e, ok := pgRowFindEntity(ref.compiled.inventory.Versions[d.SchemaVersion-1], d.Entity)
	actual := reflect.TypeFor[Row]()
	if !ok || actual.Kind() != reflect.Struct || actual.Name() != e.GoTypeName || actual.PkgPath() != e.GoTypePackage {
		panic("database: current row nominal type differs from compiler-owned source inventory")
	}
	physical := compiledRowPhysicalHistories[ref.compiled]
	if physical == nil || d.SchemaVersion != ref.compiled.history.CurrentVersion || len(physical.versions) < d.SchemaVersion {
		panic("database: current row codec requires its exact current physical history")
	}
	plan := physical.versions[d.SchemaVersion-1]
	entity := plan.entity(d.Entity)
	if plan.compiled != ref.compiled || plan.settled || len(plan.windows) != 0 || entity == nil || entity.generation != d.Generation || entity.typeContractHash != d.TypeContractHash || plan.schemaSnapshotHash != d.SchemaSnapshot || plan.storageSnapshotHash != d.StorageSnapshot || len(entity.aliases) != 0 || len(entity.reverseWrites) != 0 || len(entity.columns) != len(entity.projection) || entity.insertGeneration != entity.generation {
		panic("database: current row codec requires a complete zero-window physical projection")
	}
	registrations := compiledRowCurrentRegistrations[ref.compiled]
	if registrations == nil {
		registrations = map[int]*pgRowCurrentRegistration{}
		compiledRowCurrentRegistrations[ref.compiled] = registrations
	}
	if registrations[ref.index] != nil {
		panic("database: duplicate current row codec registration")
	}
	registration := &pgRowCurrentRegistration{database: ref.database, compiled: ref.compiled, index: ref.index, plan: plan, entity: entity}
	registrations[ref.index] = registration
	return &PgRowCurrentStorage[Row]{registration: registration, projection: &pgRowProjection{slices.Clone(d.Projection), slices.Clone(e.Columns)}, decode: codec.decode, encode: codec.encode}
}

func (storage *PgRowCurrentStorage[Row]) ready() bool {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	return storage != nil && storage.registration != nil && storage.registration.sealed && storage.registration.accessAttached && storage.projection != nil
}
func (storage *PgRowCurrentStorage[Row]) check(a *pgRowTransactionAdmission, write bool) error {
	if err := a.check(write); err != nil {
		return err
	}
	if !storage.ready() {
		return fmt.Errorf("current row codec requires sealed application preflight")
	}
	r := storage.registration
	if a.database != r.database || a.plan != r.plan || a.window != r.plan || a.entity != r.entity {
		return fmt.Errorf("current row operation requires its exact admitted current projection")
	}
	return nil
}

// Called inside the same registration transaction as all transforming codecs.
// Failure never partially seals any database, callback, or current codec.
func pgCheckApplicationCurrentRows(database *Database, history PgCompiledMigrationHistory) ([]*pgRowCurrentRegistration, error) {
	compiled := compiledRowHistories[history.Family]
	if compiled == nil || compiledRowPhysicalHistories[compiled] == nil {
		return nil, nil
	}
	if err := pgCheckRowOwner(database, compiled); err != nil {
		return nil, err
	}
	expected := pgExpectedRowCurrentCodecs(compiled.inventory)
	descriptors := compiled.inventory.CurrentCodecs
	registrations := compiledRowCurrentRegistrations[compiled]
	if len(expected) != len(descriptors) || len(registrations) != len(descriptors) {
		return nil, fmt.Errorf("compiled current row codec bindings are incomplete")
	}
	result := make([]*pgRowCurrentRegistration, 0, len(descriptors))
	for i, d := range descriptors {
		r := registrations[i]
		if _, ok := expected[d.Entity]; !ok || r == nil || r.database != database || r.compiled != compiled || r.index != i || !r.accessAttached {
			return nil, fmt.Errorf("compiled current row access belongs to another source or is incomplete")
		}
		delete(expected, d.Entity)
		result = append(result, r)
	}
	if len(expected) != 0 {
		return nil, fmt.Errorf("compiled current row codec inventory is incomplete")
	}
	return result, nil
}
