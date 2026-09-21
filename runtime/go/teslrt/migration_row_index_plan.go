package teslrt

import (
	"fmt"
	"slices"
)

// A derived descriptor carries no job, lease, compiled owner or SQL authority.
// Execution must separately bind the complete row manifest and protected jobs.
type pgRowConcurrentIndex struct {
	entity, table string
	index         PgMigrationCatalogIndex
}

func pgDeriveRowConcurrentIndexes(previous, plan *pgRowPhysicalPlan) ([]pgRowConcurrentIndex, error) {
	if previous == nil || plan == nil || plan.version < 2 || plan.version > 2147483646 || !pgRowEpochPreserving(plan) {
		return nil, fmt.Errorf("concurrent row indexes require an adjacent additive physical revision")
	}
	if err := pgValidateRowPhysicalLineage(previous, plan); err != nil {
		return nil, err
	}
	// Validate the full relation/key inventory, including collisions across
	// tables. These descriptions omit the separately fixed internal marker.
	for _, source := range []*pgRowPhysicalPlan{previous, plan} {
		catalog := make([]PgMigrationCatalogTable, 0, len(source.entities))
		for _, entity := range source.entities {
			table := PgMigrationCatalogTable{Name: entity.table, Indexes: entity.indexes}
			for _, column := range entity.columns {
				table.Columns = append(table.Columns, column.catalog)
			}
			catalog = append(catalog, table)
		}
		if err := pgValidateMigrationCatalog(catalog); err != nil {
			return nil, err
		}
	}
	var result []pgRowConcurrentIndex
	for _, entity := range plan.entities {
		old := previous.entity(entity.identity)
		if old == nil {
			// Indexes on a new empty table belong to its atomic CREATE TABLE.
			continue
		}
		for _, index := range entity.indexes {
			if slices.ContainsFunc(old.indexes, func(prior PgMigrationCatalogIndex) bool { return prior.Name == index.Name }) {
				continue // Exact retained shape was checked by lineage above.
			}
			if index.Unique {
				return nil, fmt.Errorf("unique row indexes require separately checked enforcement readiness")
			}
			// The all-new NULL case is safe only with current/newer readiness
			// held until physical and protected index validity. Old INSERT
			// omission alone does not protect unrelated non-HOT updates.
			bounded, allNewNull := true, true
			for _, key := range index.Columns {
				column := entity.column(key)
				if column == nil {
					return nil, fmt.Errorf("concurrent row index has no exact physical key")
				}
				switch column.catalog.Type {
				case "bool", "int4", "int8", "float8":
				case "text", "numeric", "jsonb":
					bounded = false
				default:
					return nil, fmt.Errorf("concurrent row index key has an unsupported physical domain")
				}
				if old.column(key) != nil || column.introducedVersion != plan.version || !column.catalog.Nullable || column.catalog.Default != nil {
					allNewNull = false
				}
			}
			if !bounded && !allNewNull {
				return nil, fmt.Errorf("concurrent row index can reject writes from an admitted schema")
			}
			index.Columns = slices.Clone(index.Columns)
			result = append(result, pgRowConcurrentIndex{entity: entity.identity, table: entity.table, index: index})
		}
	}
	return result, nil
}
