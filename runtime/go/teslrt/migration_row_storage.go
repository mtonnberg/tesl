package teslrt

import (
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// A projection binds logical aliases and their order to one compiled adapter.
// It grants no physical column, SQL, generation, or admission authority.
type pgRowProjection struct {
	fields  []string
	columns []PgRowSchemaColumn
}
type PgRowProjection struct{ projection *pgRowProjection }
type PgRowProjectionPlan struct{ projection *pgRowProjection }

func (projection PgRowProjection) Fields() []string {
	if projection.projection == nil {
		return nil
	}
	return slices.Clone(projection.projection.fields)
}

func (projection PgRowProjection) CheckOrder(fields []string) (PgRowProjectionPlan, error) {
	if projection.projection == nil || !slices.Equal(fields, projection.projection.fields) {
		return PgRowProjectionPlan{}, fmt.Errorf("row projection order differs from the compiled adapter")
	}
	return PgRowProjectionPlan(projection), nil
}

// PgRowStorage keeps both codecs nominally typed. No heterogeneous callback
// registry or JSON conversion is involved in moving between schema versions.
type PgRowStorage[From, To any] struct {
	transform      *PgRowTransform[From, To]
	decode         func(pgx.CollectableRow) (From, error)
	encode         func(To) ([]any, error)
	decodeTarget   func(pgx.CollectableRow) (To, error)
	encodeSource   func(From) ([]any, error)
	source, target *pgRowProjection
	writeBack      *PgRowWriteBack[From, To]
}

// RegisterCompiledRowStorage is emitted next to the exact typed transform. The
// complete logical order comes exclusively from its validated v2 companion.
func RegisterCompiledRowStorage[From, To any](transform *PgRowTransform[From, To], decode func(pgx.CollectableRow) (From, error), encode func(To) ([]any, error), decodeTarget func(pgx.CollectableRow) (To, error), encodeSource func(From) ([]any, error)) *PgRowStorage[From, To] {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if transform == nil || transform.registration == nil || decode == nil || encode == nil || decodeTarget == nil || encodeSource == nil {
		panic("database: missing compiled row storage adapter")
	}
	r := transform.registration
	if err := pgCheckRowOwner(r.database, r.compiled); err != nil {
		panic(err)
	}
	if r.sealed || pgMigrationClosedFamilies[r.compiled.history.Family] {
		panic("database: row storage attachment is closed")
	}
	if r.storageAttached {
		panic("database: duplicate row storage attachment")
	}
	d := r.compiled.inventory.Transforms[r.index]
	if len(d.SourceProjection) == 0 || len(d.TargetProjection) == 0 {
		panic("database: row storage requires a compiled v2 projection")
	}
	projection := func(fields []string, columns []PgRowSchemaColumn) *pgRowProjection {
		return &pgRowProjection{slices.Clone(fields), slices.Clone(columns)}
	}
	result := &PgRowStorage[From, To]{transform: transform, decode: decode, encode: encode, decodeTarget: decodeTarget, encodeSource: encodeSource, source: projection(d.SourceProjection, d.SourceSchemaColumns), target: projection(d.TargetProjection, d.TargetSchemaColumns)}
	r.storageAttached = true
	return result
}

func (storage *PgRowStorage[From, To]) SourceProjection() PgRowProjection {
	if storage == nil {
		return PgRowProjection{}
	}
	return PgRowProjection{storage.source}
}
func (storage *PgRowStorage[From, To]) TargetProjection() PgRowProjection {
	if storage == nil {
		return PgRowProjection{}
	}
	return PgRowProjection{storage.target}
}

func (storage *PgRowStorage[From, To]) ready() bool {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	return storage != nil && storage.transform != nil && storage.transform.registration != nil && storage.transform.registration.sealed && storage.transform.registration.storageAttached && storage.source != nil && storage.target != nil
}

func pgRowScalarOID(scalar string) uint32 {
	switch scalar {
	case "numeric":
		return pgtype.NumericOID
	case "float8":
		return pgtype.Float8OID
	case "text":
		return pgtype.TextOID
	case "bool":
		return pgtype.BoolOID
	case "int4":
		return pgtype.Int4OID
	case "int8":
		return pgtype.Int8OID
	case "jsonb":
		return pgtype.JSONBOID
	default:
		return 0
	}
}

// Decode validates alias, count, and SQL carrier type before the generated
// positional scanner can touch a value. A target/foreign database plan refuses
// even when every field happens to have the same SQL type.
func (storage *PgRowStorage[From, To]) Decode(plan PgRowProjectionPlan, row pgx.CollectableRow) (value From, err error) {
	if !storage.ready() {
		return value, fmt.Errorf("row decoder requires a sealed adapter")
	}
	return pgDecodeRowStorage(storage.source, plan, row, storage.decode)
}
func (storage *PgRowStorage[From, To]) DecodeTarget(plan PgRowProjectionPlan, row pgx.CollectableRow) (value To, err error) {
	if !storage.ready() {
		return value, fmt.Errorf("row decoder requires a sealed adapter")
	}
	return pgDecodeRowStorage(storage.target, plan, row, storage.decodeTarget)
}
func pgDecodeRowStorage[Value any](projection *pgRowProjection, plan PgRowProjectionPlan, row pgx.CollectableRow, decode func(pgx.CollectableRow) (Value, error)) (value Value, err error) {
	if plan.projection == nil || plan.projection != projection || row == nil {
		return value, fmt.Errorf("row decoder requires its sealed source projection")
	}
	defer func() {
		if recover() != nil {
			var zero Value
			value = zero
			err = fmt.Errorf("row decoder rejected a stored value")
		}
	}()
	fields := row.FieldDescriptions()
	if len(fields) != len(projection.fields) {
		return value, fmt.Errorf("row decoder projection count mismatch")
	}
	for i, name := range projection.fields {
		var oid uint32
		for _, column := range projection.columns {
			if column.Field == name {
				oid = pgRowScalarOID(column.Type)
				break
			}
		}
		if fields[i].Name != name || oid == 0 || fields[i].DataTypeOID != oid {
			return value, fmt.Errorf("row decoder projection alias or SQL type mismatch")
		}
	}
	value, err = decode(row)
	if err != nil {
		var zero Value
		return zero, fmt.Errorf("row decoder rejected a stored value")
	}
	return value, nil
}

// Encoded values retain their target direction and adapter identity. The caller
// still needs a separate physical storage plan to construct any SQL statement.
type PgEncodedRow struct {
	projection *pgRowProjection
	values     []any
}

func (storage *PgRowStorage[From, To]) Encode(value To) (PgEncodedRow, error) {
	if !storage.ready() {
		return PgEncodedRow{}, fmt.Errorf("row encoder requires a sealed adapter")
	}
	return pgEncodeRowStorage(storage.target, storage.encode, value)
}
func (storage *PgRowStorage[From, To]) EncodeSource(value From) (PgEncodedRow, error) {
	if !storage.ready() {
		return PgEncodedRow{}, fmt.Errorf("row encoder requires a sealed adapter")
	}
	return pgEncodeRowStorage(storage.source, storage.encodeSource, value)
}
func pgEncodeRowStorage[Value any](projection *pgRowProjection, encode func(Value) ([]any, error), value Value) (result PgEncodedRow, err error) {
	defer func() {
		if recover() != nil {
			result = PgEncodedRow{}
			err = fmt.Errorf("row encoder rejected a value")
		}
	}()
	values, err := encode(value)
	if err != nil || len(values) != len(projection.fields) {
		return result, fmt.Errorf("row encoder rejected a value")
	}
	return PgEncodedRow{projection, slices.Clone(values)}, nil
}

func (row PgEncodedRow) Parameters(plan PgRowProjectionPlan) ([]any, error) {
	if row.projection == nil || plan.projection != row.projection {
		return nil, fmt.Errorf("encoded row requires its exact target projection")
	}
	return slices.Clone(row.values), nil
}
