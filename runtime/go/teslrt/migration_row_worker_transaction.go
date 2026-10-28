package teslrt

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

type pgRowLeaseAdmission struct {
	leaseName, holder string
	leaseToken        int64
}

// The only worker constructor uses an actual Worker connection and the exact
// locally registered plan. The protected lease lock lasts through DML, ABI
// publication and cursor progress; a successor cannot claim between them.
func pgWithRowWorkerTransaction[T any](ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity, roles PgMigrationControlRoles, lease pgRowLeaseAdmission, run func(*pgRowTransactionAdmission) (T, error)) (value T, err error) {
	if conn == nil || b == nil || b.database == nil || plan == nil || entity == nil || run == nil || lease.leaseName == "" || lease.holder == "" || lease.leaseToken <= 0 {
		return value, fmt.Errorf("missing exact worker transaction binding")
	}
	selected, err := pgCompiledRowPhysicalPlan(b.database, plan.version)
	if err != nil {
		return value, err
	}
	if selected != plan || plan.compiled == nil || plan.entity(entity.identity) != entity {
		return value, fmt.Errorf("worker plan differs from compiled owner")
	}
	// Acquire ABI coordination before the repeatable-read snapshot and before
	// lease/shard locks. Retirement takes the same order, and waiting cannot
	// leave this transaction observing pre-latch or pre-retirement metadata.
	var observed PgMigrationControlState
	err = pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		var readErr error
		observed, _, readErr = pgReadRowBaselineState(ctx, tx, b, roles, false)
		return readErr
	})
	if err != nil {
		return value, err
	}
	err = pgMigrationSessionLock(ctx, conn, observed.FenceNamespace, -plan.version, true, func() error {
		return pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
			var user, session string
			if err := tx.QueryRow(ctx, "select current_user,session_user").Scan(&user, &session); err != nil {
				return err
			}
			if roles.Worker == "" || user != roles.Worker || session != roles.Worker {
				return fmt.Errorf("row backfill requires exact Worker login")
			}
			state, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,$2::integer)", state.FenceNamespace, plan.version); err != nil {
				return err
			}
			if state.FenceNamespace != observed.FenceNamespace {
				return fmt.Errorf("worker ABI fence changed before transaction")
			}
			if err := pgRowTransactionABI(ctx, tx, plan); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, "select "+pgx.Identifier{plan.namespace, "tesl_lock_row_lease"}.Sanitize()+"($1,$2,$3)", lease.leaseName, lease.leaseToken, lease.holder); err != nil {
				return err
			}
			var leaseVersion, leaseGeneration int
			var leaseEntity string
			if err := tx.QueryRow(ctx, "select version,entity,target_generation from "+pgx.Identifier{plan.namespace, "tesl_schema_backfill_shards"}.Sanitize()+" where lease_name=$1", lease.leaseName).Scan(&leaseVersion, &leaseEntity, &leaseGeneration); err != nil {
				return err
			}
			if leaseVersion != plan.version || leaseEntity != entity.identity || leaseGeneration != entity.generation {
				return fmt.Errorf("worker lease belongs to another entity generation")
			}
			if _, err := tx.Exec(ctx, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,$2::integer)", -state.FenceNamespace, plan.version); err != nil {
				return err
			}
			protocol := &pgMigrationAdmission{version: plan.version, fenceNamespace: state.FenceNamespace, controlFormat: pgRowControlFormat, rowBaseline: b, databaseUUID: state.DatabaseUUID, worker: roles.Worker, roles: roles}
			token := &pgRowTransactionAdmission{tx: tx, database: b.database, protocol: protocol, plan: plan, window: plan, entity: entity, write: true, backfill: &lease}
			token.active.Store(true)
			defer token.active.Store(false)
			value, err = run(token)
			return err
		})
	})
	if err != nil {
		var zero T
		return zero, err
	}
	return value, nil
}

// Mutation scopes explicitly commit. pgControlTransaction itself is a snapshot
// helper and deliberately rolls back callbacks that do not publish a commit.
func pgRowControlWrite(ctx context.Context, conn *pgx.Conn, run func(pgx.Tx) error) error {
	return pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		if err := run(tx); err != nil {
			return err
		}
		migrationBoundary("row-control-before-commit")
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		migrationBoundary("row-control-after-commit")
		return nil
	})
}
