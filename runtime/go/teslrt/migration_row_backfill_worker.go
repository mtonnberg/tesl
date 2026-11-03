package teslrt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func pgRowBackfillBatchSize() (int, error) {
	value := os.Getenv("TESL_BACKFILL_BATCH")
	if value == "" {
		return 2000, nil
	}
	n, err := strconv.Atoi(value)
	if err != nil || n < 1 || n > 10000 {
		return 0, fmt.Errorf("TESL_BACKFILL_BATCH must be between1 and10000")
	}
	return n, nil
}
func pgRowBackfillBindingFor(database *Database, plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity) (*pgRowBackfillBinding, error) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	if database == nil || plan == nil || entity == nil || plan.compiled == nil {
		return nil, fmt.Errorf("missing backfill owner")
	}
	if err := pgCheckRowOwner(database, plan.compiled); err != nil {
		return nil, err
	}
	for registration, binding := range compiledRowBackfills {
		if registration.database != database || registration.compiled != plan.compiled {
			continue
		}
		d := plan.compiled.inventory.Transforms[registration.index]
		if d.MigrationVersion == plan.version && d.Entity == entity.identity {
			if !registration.sealed || !registration.storageAttached || !registration.accessAttached {
				return nil, fmt.Errorf("backfill typed bindings are unsealed")
			}
			return binding, nil
		}
	}
	return nil, fmt.Errorf("backfill has no exact compiled typed operation")
}

// One provisional batch has three distinct phases. No row lock, lease lock or
// SQL transaction survives across execution of the arbitrary checked row
// function. Only a fresh fenced CAS transaction can publish converted results.
func pgRowBackfillBatch(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity, roles PgMigrationControlRoles, lease pgRowLeaseAdmission) (int, error) {
	query, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	for {
		changed, err := pgRowBackfillBatchAttempt(query, conn, b, plan, entity, roles, lease)
		var server *pgconn.PgError
		if !errors.As(err, &server) || server.Code != "40001" || query.Err() != nil || conn.IsClosed() {
			return changed, err
		}
		// Only a fully rolled-back internal batch is retried. Read current source
		// again and rerun its checked pure conversion; no App callback is replayed.
		if err := pgIndexWait(query, 10*time.Millisecond); err != nil {
			return 0, err
		}
	}
}

func pgRowBackfillBatchAttempt(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity, roles PgMigrationControlRoles, lease pgRowLeaseAdmission) (int, error) {
	binding, err := pgRowBackfillBindingFor(b.database, plan, entity)
	if err != nil {
		return 0, err
	}
	limit, err := pgRowBackfillBatchSize()
	if err != nil {
		return 0, err
	}
	query, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var items []pgRowBackfillItem
	err = pgControlTransaction(query, conn, false, func(tx pgx.Tx) error {
		if _, err := tx.Exec(query, "select "+pgx.Identifier{plan.namespace, "tesl_lock_row_lease"}.Sanitize()+"($1,$2,$3)", lease.leaseName, lease.leaseToken, lease.holder); err != nil {
			return err
		}
		var cursor json.RawMessage
		var v, g int
		var identity string
		if err := tx.QueryRow(query, "select last_pk,version,entity,target_generation from "+pgx.Identifier{plan.namespace, "tesl_schema_backfill_shards"}.Sanitize()+" where lease_name=$1", lease.leaseName).Scan(&cursor, &v, &identity, &g); err != nil {
			return err
		}
		if v != plan.version || identity != entity.identity || g != entity.generation {
			return fmt.Errorf("backfill read lease belongs to another entity generation")
		}
		var err error
		items, err = binding.read(query, tx, plan, entity, cursor, limit)
		return err
	})
	if err != nil {
		return 0, err
	}
	migrationBoundary("row-backfill-after-read")
	commits := make([]pgRowBackfillCommit, len(items))
	for i, item := range items {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		commits[i], err = item.convert()
		if err != nil {
			return 0, err
		}
	}
	migrationBoundary("row-backfill-after-conversion")
	changed, err := pgWithRowWorkerTransaction(query, conn, b, plan, entity, roles, lease, func(a *pgRowTransactionAdmission) (int, error) {
		changed := 0
		migrationBoundary("row-backfill-before-cas")
		for _, commit := range commits {
			ok, err := commit(query, a)
			if err != nil {
				return 0, err
			}
			if ok {
				changed++
			}
		}
		var cursor any
		if len(items) > 0 {
			cursor = []byte(items[len(items)-1].cursor)
		}
		migrationBoundary("row-backfill-before-progress")
		if _, err := a.tx.Exec(query, "select "+pgx.Identifier{plan.namespace, "tesl_record_row_progress"}.Sanitize()+"($1,$2,$3,$4,$5,$6)", lease.leaseName, lease.leaseToken, lease.holder, cursor, changed, len(items) == 0); err != nil {
			return 0, err
		}
		migrationBoundary("row-backfill-after-progress")
		return changed, nil
	})
	return changed, err
}
