package teslrt

import (
	"context"
	"slices"

	"github.com/jackc/pgx/v5"
)

func pgIndexKeys(table *pgCatalogTable, index pgCatalogIndex) ([]string, bool) {
	keys := make([]string, 0, len(index.Keys))
	for _, number := range index.Keys {
		found := false
		for _, column := range table.Columns {
			if column.Number == number {
				keys = append(keys, column.Name)
				found = true
				break
			}
		}
		if !found {
			return nil, false
		}
	}
	return keys, true
}
func pgEqualCatalogExpression(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
func pgEquivalentMigrationIndex(actual, expected *pgCatalogTable, a, b pgCatalogIndex) bool {
	left, lok := pgIndexKeys(actual, a)
	right, rok := pgIndexKeys(expected, b)
	return lok && rok && slices.Equal(left, right) && a.Method == b.Method && a.Unique == b.Unique && a.Primary == b.Primary &&
		a.Exclusion == b.Exclusion && a.Immediate == b.Immediate && a.NullsNotDistinct == b.NullsNotDistinct &&
		a.ConstraintOwned == b.ConstraintOwned && a.KeyCount == b.KeyCount && a.AttributeCount == b.AttributeCount &&
		slices.Equal(a.Opclasses, b.Opclasses) && slices.Equal(a.Collations, b.Collations) && slices.Equal(a.Options, b.Options) &&
		pgEqualCatalogExpression(a.Expression, b.Expression) && pgEqualCatalogExpression(a.Predicate, b.Predicate)
}

func pgCompareMigrationTable(ctx context.Context, tx pgx.Tx, owner string, actual, expected *pgCatalogTable,
	report *PgMigrationCatalogReport) error {
	return pgCompareMigrationTableWithExtras(ctx, tx, owner, actual, expected, report, pgBenignExtraColumn)
}

func pgCompareMigrationTableWithExtras(ctx context.Context, tx pgx.Tx, owner string, actual, expected *pgCatalogTable,
	report *PgMigrationCatalogReport, extra func(context.Context, pgx.Tx, pgCatalogColumn) (bool, error)) error {
	drift := func(object, reason string) {
		report.Drift = append(report.Drift, PgMigrationCatalogIssue{actual.Name, object, reason})
	}
	if actual.Kind != "r" || actual.Persistence != "p" || actual.Method != "heap" || actual.Partition || actual.Inherits {
		drift(actual.Name, "owned storage must be an ordinary persistent heap table without partitioning or inheritance")
	}
	if actual.Owner != owner {
		drift(actual.Name, "table owner differs from the recorded entity owner")
	}
	if actual.RLS || actual.ForceRLS {
		drift(actual.Name, "row-level security is not declared by this migration storage contract")
	}
	columns := map[string]pgCatalogColumn{}
	for _, column := range actual.Columns {
		columns[column.Name] = column
	}
	wanted := map[string]bool{}
	for _, column := range expected.Columns {
		wanted[column.Name] = true
		live, ok := columns[column.Name]
		if !ok {
			report.Missing = append(report.Missing, PgMigrationCatalogIssue{actual.Name, column.Name, "column is absent"})
			continue
		}
		if live.Type != column.Type || live.TypeNamespace != column.TypeNamespace || live.TypeKind != column.TypeKind ||
			live.Typmod != column.Typmod || live.Required != column.Required || live.Collation != column.Collation ||
			live.Generated != column.Generated || live.Identity != column.Identity {
			drift(column.Name, "column type, typmod, nullability, collation, generation or identity differs")
		}
		if !pgEqualCatalogExpression(live.Default, column.Default) {
			drift(column.Name, "column default differs under this server's canonical expression rendering")
		}
	}
	for _, column := range actual.Columns {
		if wanted[column.Name] {
			continue
		}
		benign, err := extra(ctx, tx, column)
		if err != nil {
			return err
		}
		if benign {
			report.Benign = append(report.Benign, PgMigrationCatalogIssue{actual.Name, column.Name, "extra column accepts omitted values without a computing default"})
		} else {
			drift(column.Name, "extra column changes omitted writes or has unsupported storage/default semantics")
		}
	}
	used := make([]bool, len(actual.Indexes))
	for _, index := range expected.Indexes {
		found := false
		for i, live := range actual.Indexes {
			if used[i] || !pgEquivalentMigrationIndex(actual, expected, live, index) {
				continue
			}
			used[i], found = true, true
			if !live.Valid || !live.Ready || !live.Live {
				drift(live.Name, "equivalent index is not valid, ready and live")
			}
			break
		}
		if !found {
			report.Missing = append(report.Missing, PgMigrationCatalogIssue{actual.Name, index.Name, "required semantic index shape is absent"})
		}
	}
	for i, index := range actual.Indexes {
		if !used[i] {
			drift(index.Name, "unrecorded or differently shaped index can change writes")
		}
	}
	for _, constraint := range actual.Constraints {
		valid := constraint.Validated && constraint.Enforced && !constraint.Deferrable && !constraint.Deferred
		switch constraint.Kind {
		case "p":
			keys, ok := pgIndexKeys(actual, pgCatalogIndex{Keys: constraint.Keys})
			matches := false
			for _, index := range expected.Indexes {
				expectedKeys, known := pgIndexKeys(expected, index)
				if index.Primary && known && slices.Equal(keys, expectedKeys) {
					matches = true
				}
			}
			valid = valid && ok && matches
		case "n": // PostgreSQL 18 records NOT NULL constraints separately.
			valid = valid && len(constraint.Keys) == 1
			found := false
			for _, column := range actual.Columns {
				if len(constraint.Keys) == 1 && column.Number == constraint.Keys[0] && column.Required {
					found = true
				}
			}
			valid = valid && found
		default:
			valid = false
		}
		if !valid {
			drift(constraint.Name, "unrecorded, unvalidated, deferred or unsupported constraint")
		}
	}
	for _, name := range actual.Triggers {
		drift(name, "unrecorded trigger")
	}
	for _, name := range actual.Policies {
		drift(name, "unrecorded row policy")
	}
	for _, name := range actual.Rules {
		drift(name, "unrecorded rewrite rule")
	}
	return nil
}
