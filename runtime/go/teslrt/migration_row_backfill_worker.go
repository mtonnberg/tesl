package teslrt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
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
		migrationBoundary("row-backfill-before-cas")
		changed, err := pgPublishRowBackfills(query, a, commits)
		if err != nil {
			return 0, err
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

// The setting belongs to this fixed entity and fenced Worker transaction, not
// an application callback. Pipeline small groups after the first successful CAS
// has latched the ABI. SQL still checks each tuple's exact source and age; neither
// sending a statement nor advancing the provisional read cursor proves a write.
func pgPublishRowBackfills(ctx context.Context, a *pgRowTransactionAdmission, commits []pgRowBackfillCommit) (int, error) {
	if len(commits) == 0 {
		return 0, nil
	}
	changed := 0
	err := a.withWriter(ctx, func(tx pgx.Tx) error {
		for start := 0; start < len(commits); {
			limit := min(start+128, len(commits))
			// Preserve first-write/latch ordering, including the crash boundary
			// before any later CAS can run. Retries receive a fresh admission.
			if !a.backfillProcessingLatched {
				limit = start + 1
			}
			batch := &pgx.Batch{}
			statements := make([]pgRowBackfillStatement, 0, limit-start)
			for _, prepare := range commits[start:limit] {
				statement, err := prepare(a)
				if err != nil {
					return err
				}
				batch.Queue(statement.sql, statement.args...)
				statements = append(statements, statement)
			}
			if written, used, err := pgPublishBackfillBulk(ctx, a, statements); err != nil {
				return err
			} else if used {
				if written > 0 {
					migrationBoundary("row-backfill-after-bulk")
					migrationBoundary("row-backfill-after-dml")
				}
				changed += written
				start = limit
				continue
			}
			results := tx.SendBatch(ctx, batch)
			written := 0
			for range batch.Len() {
				tag, err := results.Exec()
				if err != nil {
					return errors.Join(err, results.Close())
				}
				if tag.RowsAffected() > 1 {
					return errors.Join(fmt.Errorf("backfill primary key matched multiple rows"), results.Close())
				}
				written += int(tag.RowsAffected())
			}
			if err := results.Close(); err != nil {
				return err
			}
			if written > 0 {
				migrationBoundary("row-backfill-after-dml")
				if err := a.latchProcessing(ctx); err != nil {
					return err
				}
			}
			changed += written
			start = limit
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return changed, nil
}

// A conservative fast path after the first successful, ABI-latched write.
// Secondary uniqueness and staged guards can make statement grouping observable;
// nominal/JSONB keys also retain the existing path. All other cases fall back to
// the same per-row guarded pipeline, without changing conversion or progress.
func pgPublishBackfillBulk(ctx context.Context, a *pgRowTransactionAdmission, statements []pgRowBackfillStatement) (int, bool, error) {
	if err := a.check(true); err != nil {
		return 0, false, err
	}
	if a.backfill == nil || !a.backfillProcessingLatched || len(statements) < 2 || len(statements) > 128 ||
		len(a.plan.stageGuards) != 0 || slices.ContainsFunc(a.entity.indexes, func(i PgMigrationCatalogIndex) bool { return i.Unique }) {
		return 0, false, nil
	}
	key := pgPhysicalPrimary(a.entity)
	primary := a.entity.column(key)
	if primary == nil {
		return 0, false, nil
	}
	switch primary.catalog.Type {
	case "text", "int4", "int8", "numeric", "bool":
	default:
		return 0, false, nil
	}
	columns := statements[0].columns
	if len(columns) == 0 || (len(columns)+6)*len(statements) > 65535 {
		return 0, false, nil
	}
	var types, aliases, assignments []string
	for i, name := range columns {
		typ := "pg_catalog.int2"
		if name != "_tesl_v" {
			column := a.entity.column(name)
			if column == nil {
				return 0, false, nil
			}
			typ = pgMigrationTypeSQL(column.catalog.Type)
			if typ == "" {
				return 0, false, nil
			}
		}
		alias := "c" + strconv.Itoa(i)
		types = append(types, typ)
		aliases = append(aliases, alias)
		assignments = append(assignments, quoteIdentifier(name)+"=i."+alias)
	}
	keyType := pgMigrationTypeSQL(primary.catalog.Type)
	types = append(types, keyType, keyType, "pg_catalog.xid", "pg_catalog.numeric", "pg_catalog.timestamptz", "pg_catalog.int2")
	aliases = append(aliases, "old_key", "new_key", "source_xmin", "source_xid", "read_at", "old_generation")
	var values []string
	var args []any
	for _, statement := range statements {
		if !slices.Equal(statement.columns, columns) || len(statement.args) != len(types) {
			return 0, false, nil
		}
		parameters := make([]string, len(types))
		for i, typ := range types {
			parameters[i] = "$" + strconv.Itoa(len(args)+i+1) + "::" + typ
		}
		args = append(args, statement.args...)
		values = append(values, "("+strings.Join(parameters, ",")+")")
	}
	// Duplicate encoded keys must not let UPDATE FROM pick an arbitrary source.
	// PostgreSQL's own equality decides eligibility; no DML occurs when false,
	// and the caller falls back to the ordered per-row pipeline.
	query := "with input(" + strings.Join(aliases, ",") + ") as materialized (values " + strings.Join(values, ",") + ")," +
		" compatible as (select count(*)=count(distinct old_key) as ok from input)," +
		" changed as (update " + pgx.Identifier{a.plan.namespace, a.entity.table}.Sanitize() + " t set " + strings.Join(assignments, ",") +
		" from input i where (select ok from compatible) and " + pgBackfillPredicate("t.", key, func(offset int) string {
		return "i." + aliases[len(columns)+offset-1]
	}) + " returning 1)" +
		" select (select ok from compatible),count(*) from changed"
	var compatible bool
	var written int
	if err := a.tx.QueryRow(ctx, query, args...).Scan(&compatible, &written); err != nil {
		return 0, false, err
	}
	if written < 0 || written > len(statements) || (!compatible && written != 0) {
		return 0, false, fmt.Errorf("bulk backfill changed an invalid row count")
	}
	return written, compatible, nil
}
