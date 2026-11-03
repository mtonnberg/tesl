//go:build tesl_migration_test

package teslrt

import (
	"context"
	"fmt"
	"github.com/jackc/pgx/v5"
	"slices"
)

// The probe receives only the actual generated owner. It changes one descriptor
// after deriving the real source operation, and never accepts source metadata.
func TeslTestRowIndexRegistration(ctx context.Context, conn *pgx.Conn, database *Database, roles PgMigrationControlRoles, wrong bool) error {
	if err := PreflightApplicationDatabases(database); err != nil {
		return err
	}
	b, err := pgCompiledRowBaseline(database)
	if err != nil {
		return err
	}
	previous, err := pgCompiledRowPredecessorPlan(database, b.target.version)
	if err != nil {
		return err
	}
	operations, err := pgRowForwardOperations(previous, b.target)
	if err != nil {
		return err
	}
	if len(operations) != 1 || operations[0].index == nil {
		return fmt.Errorf("probe requires original single-index V2")
	}
	descriptor := *operations[0].index
	descriptor.index.Columns = slices.Clone(descriptor.index.Columns)
	if wrong {
		descriptor.index.Columns = []string{"title"}
	}
	return pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
		if err := pgRegisterRowIndex(ctx, tx, b, roles, 0, descriptor); err != nil {
			return err
		}
		if wrong {
			return nil
		}
		return fmt.Errorf("test rollback after exact row index registration")
	})
}
