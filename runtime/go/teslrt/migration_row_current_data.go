package teslrt

import (
	"fmt"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
)

func (storage *PgRowCurrentStorage[Row]) decodePhysical(a *pgRowTransactionAdmission, row pgx.CollectableRow) (value Row, err error) {
	if err = storage.check(a, false); err != nil {
		return value, err
	}
	projection, err := pgPhysicalProjection(row, a.entity, a.entity, storage.projection)
	if err != nil {
		return value, err
	}
	var marker int16
	destinations := make([]any, len(row.FieldDescriptions()))
	destinations[0] = &marker
	if err = row.Scan(destinations...); err != nil {
		return value, err
	}
	if !a.acceptsCurrentGeneration(int(marker)) {
		return value, fmt.Errorf("current row has an unsupported stored generation")
	}
	return pgDecodeRowStorage(storage.projection, PgRowProjectionPlan{storage.projection}, projection, storage.decode)
}

func (storage *PgRowCurrentStorage[Row]) materialize(a *pgRowTransactionAdmission, value Row) (pgPhysicalWrite, error) {
	if err := storage.check(a, true); err != nil {
		return pgPhysicalWrite{}, err
	}
	encoded, err := pgEncodeRowStorage(storage.projection, storage.encode, value)
	if err != nil {
		return pgPhysicalWrite{}, err
	}
	values, err := encoded.Parameters(PgRowProjectionPlan{storage.projection})
	if err != nil {
		return pgPhysicalWrite{}, err
	}
	logical := map[string]any{}
	for i, field := range storage.projection.fields {
		logical[field] = values[i]
	}
	physical := map[string]any{}
	for _, field := range a.entity.projection {
		v, ok := logical[field.logical]
		if !ok {
			return pgPhysicalWrite{}, fmt.Errorf("current materialization omitted a logical field")
		}
		physical[field.physical] = v
	}
	result := pgPhysicalWrite{}
	for _, column := range a.entity.columns {
		v, ok := physical[column.catalog.Name]
		if !ok {
			return pgPhysicalWrite{}, fmt.Errorf("current materialization omitted an exact physical field")
		}
		result.columns = append(result.columns, column.catalog.Name)
		result.values = append(result.values, v)
		if column.catalog.PrimaryKey {
			result.primary = v
		}
	}
	result.columns = append(result.columns, "_tesl_v")
	result.values = append(result.values, int16(a.entity.generation))
	return result, nil
}

func pgRowCurrentStatement(a *pgRowTransactionAdmission, q PgRowQuery) (string, error) {
	if err := a.check(false); err != nil {
		return "", err
	}
	if len(q.parts) != len(q.fields)+1 {
		return "", fmt.Errorf("invalid compiled logical query fragments")
	}
	var result strings.Builder
	for i, part := range q.parts {
		result.WriteString(part)
		if i == len(q.fields) {
			break
		}
		column := a.entity.field(q.fields[i])
		if column == "" {
			return "", fmt.Errorf("current query requires an exact logical field")
		}
		result.WriteString(pgx.Identifier{column}.Sanitize())
	}
	return result.String(), nil
}

func RegisterCompiledRowCurrentAccess[Row any](storage *PgRowCurrentStorage[Row], slot *PgRowAccessSlot[Row], capture ...func(PgPlan) PgPlan) *PgRowAccessSlot[Row] {
	if len(capture) > 1 || len(capture) == 1 && capture[0] == nil {
		panic("invalid row access capture binding")
	}
	capture = slices.Clone(capture)
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if storage == nil || storage.registration == nil || slot == nil {
		panic("missing compiled current row access binding")
	}
	r := storage.registration
	if r.sealed || r.accessAttached || pgMigrationClosedFamilies[r.compiled.history.Family] {
		panic("duplicate or late current row access binding")
	}
	if err := pgCheckRowOwner(r.database, r.compiled); err != nil {
		panic(err)
	}
	slot.mutex.Lock()
	defer slot.mutex.Unlock()
	if slot.owners == nil || slot.owners[r.database] != nil {
		panic("compiled current row access slot already bound to database")
	}
	data := pgRowAccessData[Row]{check: storage.check, decode: storage.decodePhysical, materialize: storage.materialize, statement: pgRowCurrentStatement}
	access := pgNewRowAccess(r.database, r.plan.version, r.entity.identity, data, func() bool { return r.sealed }, capture)
	slot.owners[r.database] = access
	r.accessAttached = true
	return slot
}
