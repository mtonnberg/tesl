package teslrt

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// An opened binary's immutable protocol binding. Cached catalog observations do
// not authorize requests: admission is checked inside every SQL transaction.
type pgMigrationAdmission struct {
	version, fenceNamespace int
	databaseUUID            string
	worker                  string
	roles                   PgMigrationControlRoles
}

type pgMigrationAdmissionError struct{ cause error }

func (err *pgMigrationAdmissionError) Error() string {
	return "migration admission: " + err.cause.Error()
}
func (err *pgMigrationAdmissionError) Unwrap() error { return err.cause }

func pgAdmitMigrationTransaction(ctx context.Context, tx pgx.Tx, db *PostgresDB, write bool) error {
	protocol := db.migration
	if protocol == nil {
		return nil
	}
	if write {
		// This statement must finish before admission gets a fresh read-committed
		// snapshot. The shared key lasts until commit/rollback, not just until DML.
		if _, err := tx.Exec(ctx, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,$2::integer)", protocol.fenceNamespace, protocol.version); err != nil {
			return err
		}
		migrationBoundary("writer-fence")
	}
	var floor int
	if err := tx.QueryRow(ctx, "select "+pgx.Identifier{db.schema, "tesl_admit"}.Sanitize()+"($1::integer)", protocol.version).Scan(&floor); err != nil {
		return &pgMigrationAdmissionError{cause: err}
	}
	return nil
}

// pgMigrationStatement holds implicit transactions through scanning, final read
// admission and commit. A caller-owned transaction gets the same gates and is
// admitted again by WithTransaction before its eventual commit.
func pgMigrationStatement[T any](ctx context.Context, db *PostgresDB, write bool, run func(pgExecutor) (T, error)) (value T, resultErr error) {
	existing := currentTransactionFor(db)
	var executor pgExecutor = db.pool
	if existing != nil {
		executor = existing
	}
	return pgMigrationStatementOn(ctx, db, executor, write, run)
}

type pgMigrationTransactionStarter interface {
	BeginTx(context.Context, pgx.TxOptions) (pgx.Tx, error)
}

// Dedicated listener connections use the same gates without spending a pool
// lease. The caller owns this connection and must not expose results early.
func pgMigrationStatementOn[T any](ctx context.Context, db *PostgresDB, executor pgExecutor, write bool, run func(pgExecutor) (T, error)) (value T, resultErr error) {
	if db.migration == nil {
		return run(executor)
	}
	tx, existing := executor.(pgx.Tx)
	owned := !existing
	if owned {
		starter, ok := executor.(pgMigrationTransactionStarter)
		if !ok {
			return value, fmt.Errorf("migration statement requires a transaction-capable connection")
		}
		var err error
		tx, err = starter.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
		if err != nil {
			return value, err
		}
		defer func() {
			cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
				resultErr = errors.Join(resultErr, fmt.Errorf("rollback migration request: %w", err))
			}
		}()
	}
	if write {
		if err := pgAdmitMigrationTransaction(ctx, tx, db, true); err != nil {
			return value, err
		}
	}
	value, err := run(tx)
	if err != nil {
		return value, err
	}
	if !write {
		migrationBoundary("read-before-admit")
		if err := pgAdmitMigrationTransaction(ctx, tx, db, false); err != nil {
			var empty T
			return empty, err
		}
	}
	if owned {
		if err := tx.Commit(ctx); err != nil {
			var empty T
			return empty, err
		}
	}
	return value, nil
}
