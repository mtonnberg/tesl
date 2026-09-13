package teslrt

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

// Decoder view over one actual PostgreSQL row. Scan delegates to the original
// driver with checked positional destinations; no JSON or nominal conversion is
// used to move data between source versions.
type pgRowProjectedRow struct {
	row     pgx.CollectableRow
	indices []int
	fields  []pgconn.FieldDescription
}

func (row *pgRowProjectedRow) FieldDescriptions() []pgconn.FieldDescription {
	return slices.Clone(row.fields)
}
func (row *pgRowProjectedRow) Scan(dest ...any) error {
	if len(dest) != len(row.indices) {
		return fmt.Errorf("physical decoder destination count differs")
	}
	all := make([]any, len(row.row.FieldDescriptions()))
	for i, index := range row.indices {
		all[index] = dest[i]
	}
	return row.row.Scan(all...)
}
func (row *pgRowProjectedRow) Values() ([]any, error) {
	all, err := row.row.Values()
	if err != nil {
		return nil, err
	}
	result := make([]any, len(row.indices))
	for i, index := range row.indices {
		if index >= len(all) {
			return nil, fmt.Errorf("physical row value missing")
		}
		result[i] = all[index]
	}
	return result, nil
}
func (row *pgRowProjectedRow) RawValues() [][]byte {
	all := row.row.RawValues()
	result := make([][]byte, len(row.indices))
	for i, index := range row.indices {
		if index >= len(all) {
			return nil
		}
		result[i] = all[index]
	}
	return result
}
func pgPhysicalProjection(row pgx.CollectableRow, retained, logical *pgRowPhysicalEntity, projection *pgRowProjection) (*pgRowProjectedRow, error) {
	if row == nil || retained == nil || logical == nil || projection == nil {
		return nil, fmt.Errorf("missing physical row projection")
	}
	actual := row.FieldDescriptions()
	if len(actual) != len(retained.columns)+1 || actual[0].Name != "_tesl_v" || actual[0].DataTypeOID != pgtype.Int2OID {
		return nil, fmt.Errorf("physical row marker or column count differs")
	}
	positions := map[string]int{}
	for i, col := range retained.columns {
		if actual[i+1].Name != col.catalog.Name || actual[i+1].DataTypeOID != pgRowScalarOID(col.catalog.Type) {
			return nil, fmt.Errorf("physical row column identity or SQL carrier differs")
		}
		positions[col.catalog.Name] = i + 1
	}
	result := &pgRowProjectedRow{row: row}
	for _, name := range projection.fields {
		physical := logical.field(name)
		index, ok := positions[physical]
		if !ok {
			return nil, fmt.Errorf("logical decoder references absent retained storage")
		}
		field := actual[index]
		field.Name = name
		result.indices = append(result.indices, index)
		result.fields = append(result.fields, field)
	}
	return result, nil
}

func pgPhysicalPrimary(entity *pgRowPhysicalEntity) string {
	for _, column := range entity.columns {
		if column.catalog.PrimaryKey {
			return column.catalog.Name
		}
	}
	return ""
}
func pgPhysicalSelect(plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity, lock bool) string {
	columns := []string{pgx.Identifier{"_tesl_v"}.Sanitize()}
	for _, column := range entity.columns {
		columns = append(columns, pgx.Identifier{column.catalog.Name}.Sanitize())
	}
	sql := "select " + strings.Join(columns, ",") + " from " + pgx.Identifier{plan.namespace, entity.table}.Sanitize() + " where " + pgx.Identifier{pgPhysicalPrimary(entity)}.Sanitize() + "=$1"
	if lock {
		sql += " for update"
	}
	return sql
}
func pgCheckRowData[From, To any](a *pgRowTransactionAdmission, storage *PgRowStorage[From, To], write bool) error {
	if err := a.check(write); err != nil {
		return err
	}
	if a.plan.compiled == nil || !storage.ready() || storage.transform.registration.database != a.database || storage.transform.registration.compiled != a.plan.compiled {
		return fmt.Errorf("physical data operation requires its exact typed storage owner")
	}
	d := a.plan.compiled.inventory.Transforms[storage.transform.registration.index]
	if d.MigrationVersion != a.plan.version || d.Entity != a.entity.identity || d.TargetGeneration != a.entity.generation {
		return fmt.Errorf("physical data operation requires the current typed window")
	}
	return nil
}
func pgReadPhysicalRow[From, To any](ctx context.Context, a *pgRowTransactionAdmission, storage *PgRowStorage[From, To], key any, lock bool) (value To, found bool, err error) {
	if err := pgCheckRowData(a, storage, lock); err != nil {
		return value, false, err
	}
	rows, err := a.tx.Query(ctx, pgPhysicalSelect(a.plan, a.entity, lock), key)
	if err != nil {
		return value, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return value, false, rows.Err()
	}
	value, err = pgDecodePhysicalRow(a, storage, rows)
	if err != nil {
		return value, false, err
	}
	if rows.Next() {
		return value, false, fmt.Errorf("physical primary key returned multiple rows")
	}
	if err := rows.Err(); err != nil {
		return value, false, err
	}
	return value, true, nil
}

func pgDecodePhysicalRow[From, To any](a *pgRowTransactionAdmission, storage *PgRowStorage[From, To], row pgx.CollectableRow) (value To, err error) {
	if a == nil || a.plan == nil || a.plan.compiled == nil {
		return value, fmt.Errorf("physical row decoding requires its compiled owner")
	}
	var marker int16
	markerDest := make([]any, len(row.FieldDescriptions()))
	if len(markerDest) == 0 {
		return value, fmt.Errorf("missing physical marker")
	}
	markerDest[0] = &marker
	if err := row.Scan(markerDest...); err != nil {
		return value, err
	}
	descriptor := a.plan.compiled.inventory.Transforms[storage.transform.registration.index]
	if a.acceptsCurrentGeneration(int(marker)) {
		projection, err := pgPhysicalProjection(row, a.entity, a.entity, storage.target)
		if err != nil {
			return value, err
		}
		value, err = storage.DecodeTarget(PgRowProjectionPlan{storage.target}, projection)
		if err != nil {
			return value, err
		}
	} else if int(marker) == descriptor.PreviousGeneration {
		previous, err := pgCompiledRowPredecessorPlan(a.database, a.plan.version)
		if err != nil {
			return value, err
		}
		old := previous.entity(a.entity.identity)
		projection, err := pgPhysicalProjection(row, a.entity, old, storage.source)
		if err != nil {
			return value, err
		}
		source, err := storage.Decode(PgRowProjectionPlan{storage.source}, projection)
		if err != nil {
			return value, err
		}
		migrated, err := storage.transform.Run(source)
		if err != nil {
			return value, err
		}
		if migrated.Tag != MigratedRow {
			return value, fmt.Errorf("stored row rejected by its checked migration")
		}
		value = migrated.RowValue
	} else {
		return value, fmt.Errorf("stored row has an unsupported generation")
	}
	return value, nil
}

type pgPhysicalWrite struct {
	columns []string
	values  []any
	primary any
}

func pgMaterializePhysicalWrite[From, To any](a *pgRowTransactionAdmission, storage *PgRowStorage[From, To], value To) (pgPhysicalWrite, error) {
	if err := pgCheckRowData(a, storage, true); err != nil {
		return pgPhysicalWrite{}, err
	}
	encoded, err := storage.Encode(value)
	if err != nil {
		return pgPhysicalWrite{}, err
	}
	values, err := encoded.Parameters(PgRowProjectionPlan{storage.target})
	if err != nil {
		return pgPhysicalWrite{}, err
	}
	if len(values) != len(storage.target.fields) {
		return pgPhysicalWrite{}, fmt.Errorf("encoded row differs from complete target projection")
	}
	logical := map[string]any{}
	for i, name := range storage.target.fields {
		logical[name] = values[i]
	}
	physical := map[string]any{}
	for _, field := range a.entity.projection {
		value, ok := logical[field.logical]
		if !ok {
			return pgPhysicalWrite{}, fmt.Errorf("materialization omitted a logical field")
		}
		physical[field.physical] = value
	}
	for _, alias := range a.entity.aliases {
		value, ok := logical[alias.logical]
		if !ok {
			return pgPhysicalWrite{}, fmt.Errorf("materialization omitted a historical alias")
		}
		physical[alias.physical] = value
	}
	if len(a.entity.reverseWrites) > 0 {
		if storage.writeBack == nil {
			return pgPhysicalWrite{}, fmt.Errorf("retained reverse columns require their exact typed WriteBack")
		}
		encoded, err := storage.writeBack.Encode(value)
		if err != nil {
			return pgPhysicalWrite{}, err
		}
		values, err := encoded.Parameters(PgRowProjectionPlan{storage.source})
		if err != nil {
			return pgPhysicalWrite{}, err
		}
		if len(values) != len(storage.source.fields) {
			return pgPhysicalWrite{}, fmt.Errorf("reverse codec differs from complete source projection")
		}
		old := map[string]any{}
		for i, name := range storage.source.fields {
			old[name] = values[i]
		}
		for _, write := range a.entity.reverseWrites {
			value, ok := old[write.previous]
			if !ok {
				return pgPhysicalWrite{}, fmt.Errorf("reverse materialization omitted previous field")
			}
			if _, duplicate := physical[write.physical]; duplicate {
				return pgPhysicalWrite{}, fmt.Errorf("reverse materialization conflicts with target or alias")
			}
			physical[write.physical] = value
		}
	}
	result := pgPhysicalWrite{}
	for _, column := range a.entity.columns {
		value, ok := physical[column.catalog.Name]
		if !ok {
			return pgPhysicalWrite{}, fmt.Errorf("materialization omitted a retained column")
		}
		result.columns = append(result.columns, column.catalog.Name)
		result.values = append(result.values, value)
		if column.catalog.PrimaryKey {
			result.primary = value
		}
	}
	result.columns = append(result.columns, "_tesl_v")
	result.values = append(result.values, int16(a.entity.generation))
	return result, nil
}
func pgInsertPhysicalRow[From, To any](ctx context.Context, a *pgRowTransactionAdmission, storage *PgRowStorage[From, To], value To, capture ...func(PgPlan) PgPlan) error {
	row, err := pgMaterializePhysicalWrite(a, storage, value)
	if err != nil {
		return err
	}
	columns, parameters := []string{}, []string{}
	for i, column := range row.columns {
		columns = append(columns, pgx.Identifier{column}.Sanitize())
		parameters = append(parameters, "$"+strconv.Itoa(i+1))
	}
	sql := "insert into " + pgx.Identifier{a.plan.namespace, a.entity.table}.Sanitize() + " (" + strings.Join(columns, ",") + ") values (" + strings.Join(parameters, ",") + ")"
	plan := pgCapturedRowPlan(sql, func() []any { return row.values }, capture)
	count := 0
	if plan.Capture != nil {
		defer func() { plan.Capture(count) }()
	}
	args := plan.arguments()
	return a.withWriter(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, sql, args...)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return fmt.Errorf("physical insert did not publish one complete row")
		}
		count = 1
		migrationBoundary("row-target-after-dml")
		return a.latchProcessing(ctx)
	})
}
func pgUpdatePhysicalRow[From, To any](ctx context.Context, a *pgRowTransactionAdmission, storage *PgRowStorage[From, To], key any, update func(To) To) (bool, error) {
	if update == nil {
		return false, fmt.Errorf("missing typed row update")
	}
	value, found, err := pgReadPhysicalRow(ctx, a, storage, key, true)
	if err != nil || !found {
		return found, err
	}
	return pgUpdateDecodedPhysicalRow(ctx, a, storage, value, update(value))
}
func pgUpdateDecodedPhysicalRow[From, To any](ctx context.Context, a *pgRowTransactionAdmission, storage *PgRowStorage[From, To], value, next To, capture ...func(PgPlan) PgPlan) (bool, error) {
	before, err := pgMaterializePhysicalWrite(a, storage, value)
	if err != nil {
		return false, err
	}
	row, err := pgMaterializePhysicalWrite(a, storage, next)
	if err != nil {
		return false, err
	}
	assignments := []string{}
	parameters := []any{}
	for i, column := range row.columns {
		if column == pgPhysicalPrimary(a.entity) {
			continue
		}
		parameters = append(parameters, row.values[i])
		assignments = append(assignments, pgx.Identifier{column}.Sanitize()+"=$"+strconv.Itoa(len(parameters)))
	}
	parameters = append(parameters, before.primary, row.primary)
	keyColumn := pgx.Identifier{pgPhysicalPrimary(a.entity)}.Sanitize()
	// Let the exact stored SQL carrier compare keys, including PostgreSQL's NaN
	// and JSONB equality rules. This stays in the same locked-row statement.
	sql := "update " + pgx.Identifier{a.plan.namespace, a.entity.table}.Sanitize() + " set " + strings.Join(assignments, ",") + " where " + keyColumn + "=$" + strconv.Itoa(len(parameters)-1) + " and " + keyColumn + " is not distinct from $" + strconv.Itoa(len(parameters))
	plan := pgCapturedRowPlan(sql, func() []any { return parameters }, capture)
	count := 0
	if plan.Capture != nil {
		defer func() { plan.Capture(count) }()
	}
	args := plan.arguments()
	err = a.withWriter(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, sql, args...)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return fmt.Errorf("migration row update changed its primary key or lost its locked row")
		}
		count = 1
		migrationBoundary("row-target-after-dml")
		return a.latchProcessing(ctx)
	})
	return err == nil, err
}

func pgCapturedRowPlan(sql string, args func() []any, capture []func(PgPlan) PgPlan) PgPlan {
	plan := PgSql(sql, args)
	if len(capture) == 1 {
		return capture[0](plan)
	}
	return plan
}
