package teslrt

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// A transaction-bound capability used only inside the compiled physical data
// path. A parsed durable manifest never creates one, and it cannot outlive the
// admitted callback or be reused on another database/connection.
type pgRowTransactionAdmission struct {
	tx       pgx.Tx
	database *Database
	protocol *pgMigrationAdmission
	plan     *pgRowPhysicalPlan
	window   *pgRowPhysicalPlan
	entity   *pgRowPhysicalEntity
	write    bool
	active   atomic.Bool
	backfill *pgRowLeaseAdmission
}

func pgWithRowTransaction[T any](ctx context.Context, database *Database, plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity, write bool, run func(*pgRowTransactionAdmission) (T, error)) (value T, err error) {
	if database == nil || plan == nil || plan.compiled == nil || entity == nil || run == nil {
		return value, fmt.Errorf("missing compiled row transaction binding")
	}
	if err := pgCheckRowOwner(database, plan.compiled); err != nil {
		return value, err
	}
	selected, err := pgCompiledRowPhysicalPlan(database, plan.version)
	if err != nil {
		return value, err
	}
	if selected != plan {
		return value, fmt.Errorf("row transaction requires exact registered physical plan")
	}
	found := false
	for i := range plan.entities {
		if &plan.entities[i] == entity {
			found = true
			break
		}
	}
	if !found {
		return value, fmt.Errorf("row transaction entity belongs to another physical plan")
	}
	db := database.bound()
	if db == nil || db.migration == nil || db.migration.controlFormat != pgRowControlFormat || db.migration.rowBaseline == nil || db.migration.rowBaseline.database != database || db.migration.version != plan.version {
		return value, fmt.Errorf("row transaction connection is not admitted for this compiled plan")
	}
	return pgMigrationStatement(ctx, db, write, func(executor pgExecutor) (result T, resultErr error) {
		tx, ok := executor.(pgx.Tx)
		if !ok {
			return value, fmt.Errorf("row transaction requires an admitted SQL transaction")
		}
		if !write {
			if err := pgAdmitMigrationTransaction(ctx, tx, db, false); err != nil {
				return value, err
			}
		}
		if err := pgRowTransactionABI(ctx, tx, plan); err != nil {
			return value, err
		}
		if !write {
			migrationBoundary("row-read-after-abi")
		}
		// Compatibility uses (-fenceNamespace, version), disjoint from writer
		// (fenceNamespace, version) and ABI (fenceNamespace, -version) keys.
		// Acquire after first-ABI coordination and before the fresh floor read.
		if _, err := tx.Exec(ctx, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,$2::integer)", -db.migration.fenceNamespace, plan.version); err != nil {
			return value, err
		}
		activePlan, activeEntity := plan, entity
		settled, err := pgRowSettledMode(ctx, tx, database, plan)
		if err != nil {
			return value, err
		}
		if settled {
			activePlan, err = pgCompiledRowSettledPlan(database, plan.version)
			if err != nil {
				return value, err
			}
			activeEntity = activePlan.entity(entity.identity)
			if activeEntity == nil {
				return value, fmt.Errorf("settled plan omitted admitted entity")
			}
		}
		token := &pgRowTransactionAdmission{tx: tx, database: database, protocol: db.migration, plan: activePlan, window: plan, entity: activeEntity, write: write}
		token.active.Store(true)
		completed := false
		defer func() {
			token.active.Store(false)
			if write && (!completed || resultErr != nil) {
				// Never let a caught callback error or panic publish target DML
				// without its same-transaction ABI latch.
				cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				rollbackErr := tx.Rollback(cleanup)
				cancel()
				if rollbackErr != nil && !errors.Is(rollbackErr, pgx.ErrTxClosed) {
					resultErr = errors.Join(resultErr, rollbackErr)
				}
			}
		}()
		result, resultErr = run(token)
		if resultErr == nil {
			resultErr = pgRowTransactionABI(ctx, tx, plan)
		}
		if resultErr != nil {
			var zero T
			result = zero
		}
		completed = true
		return result, resultErr
	})
}

func (a *pgRowTransactionAdmission) check(write bool) error {
	if a == nil || !a.active.Load() || a.tx == nil || a.database == nil || a.protocol == nil || a.plan == nil || a.plan.compiled == nil || a.window == nil || a.window.compiled != a.plan.compiled || a.window.version != a.plan.version || a.entity == nil || write && !a.write {
		return fmt.Errorf("row transaction admission has expired or does not permit this operation")
	}
	return nil
}

func pgRowWriterSetting(namespace, entity string) string {
	return fmt.Sprintf("tesl.row_writer_%x", sha256.Sum256([]byte(namespace+"\x00"+entity)))
}

// The setting is transaction-local and scoped to this exact entity write. It is
// restored before returning even inside a caller-owned multi-statement txn.
func (a *pgRowTransactionAdmission) withWriter(ctx context.Context, run func(pgx.Tx) error) (err error) {
	if err = a.check(true); err != nil {
		return err
	}
	if run == nil {
		return fmt.Errorf("missing row write operation")
	}
	key := pgRowWriterSetting(a.plan.namespace, a.entity.identity)
	var previous string
	if err = a.tx.QueryRow(ctx, "select coalesce(pg_catalog.current_setting($1,true),'')", key).Scan(&previous); err != nil {
		return err
	}
	if _, err = a.tx.Exec(ctx, "select pg_catalog.set_config($1,$2,true)", key, strconv.Itoa(a.entity.generation)); err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_, restoreErr := a.tx.Exec(cleanup, "select pg_catalog.set_config($1,$2,true)", key, previous)
		cancel()
		if restoreErr != nil {
			// A caller-owned transaction may catch the returned error. Explicitly
			// close it so a failed restore can never leave reusable writer state.
			rollback, stop := context.WithTimeout(context.Background(), 5*time.Second)
			rollbackErr := a.tx.Rollback(rollback)
			stop()
			err = errors.Join(err, fmt.Errorf("restore row writer setting: %w", restoreErr), rollbackErr)
		}
	}()
	return run(a.tx)
}

// Call immediately after a successful target-generation write; both latch and DML
// roll back together. Merely opening or reading a new binary never pins its ABI.
func (a *pgRowTransactionAdmission) latchProcessing(ctx context.Context) error {
	if err := a.check(true); err != nil {
		return err
	}
	window := a.window
	if window == nil || window.compiled == nil {
		return fmt.Errorf("row processing requires its compiled window")
	}
	if a.entity.generation == 1 {
		return nil
	}
	_, err := a.tx.Exec(ctx, "select "+pgx.Identifier{a.plan.namespace, "tesl_row_processing"}.Sanitize()+"($1,$2,$3)", window.version, window.compiled.history.SourceCompilerABI, window.hash)
	return err
}

// Check both before work and before publishing its result. A pool may have opened
// before another compiler performed the first materializing write. This check
// coordinates all pre-first-write operations before row locks, avoiding lock
// upgrades in explicit read-then-write transactions. Once ABI is immutable the
// protected function has a comparison-only fast path. Reads never create it.
func pgRowTransactionABI(ctx context.Context, tx pgx.Tx, plan *pgRowPhysicalPlan) error {
	if plan == nil || plan.compiled == nil {
		return fmt.Errorf("row ABI admission requires its compiled window")
	}
	if plan.version == 1 {
		return nil
	}
	// The protected check also knows whether this exact window has retired.
	// Both entry and result checks must share that rule; historical processing
	// provenance does not govern settled writes after retirement.
	_, err := tx.Exec(ctx, "select "+pgx.Identifier{plan.namespace, "tesl_row_check_abi"}.Sanitize()+"($1,$2,$3)", plan.version, plan.compiled.history.SourceCompilerABI, plan.hash)
	return pgRowABIAdmissionError(err)
}

// Only this runtime-owned protected ABI check produces this admission result.
// Unrelated database exceptions, including arbitrary P0001, keep their errors.
func pgRowABIAdmissionError(err error) error {
	var server *pgconn.PgError
	if errors.As(err, &server) && server.Code == "P0001" && server.Message == "tesl: transforming generation compiler ABI is pinned" {
		return &pgMigrationAdmissionError{cause: err}
	}
	return err
}
