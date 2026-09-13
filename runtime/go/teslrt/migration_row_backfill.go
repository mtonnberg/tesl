package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Only operations are erased. A captured From or To remains its exact generated
// Go type for its entire lifetime; no registry cast or JSON row conversion occurs.
type pgRowBackfillItem struct {
	cursor  json.RawMessage
	convert func() (pgRowBackfillCommit, error)
}
type pgRowBackfillCommit func(context.Context, *pgRowTransactionAdmission) (bool, error)
type pgRowBackfillBinding struct {
	registration *pgRowRegistration
	read         func(context.Context, pgx.Tx, *pgRowPhysicalPlan, *pgRowPhysicalEntity, json.RawMessage, int) ([]pgRowBackfillItem, error)
}

var compiledRowBackfills = map[*pgRowRegistration]*pgRowBackfillBinding{}

// Called by the compiler's typed access attachment with the registration mutex
// held. This captures code and exact storage metadata; it performs no SQL and
// creates no admission or execution capability.
func pgAttachRowBackfill[From, To any](storage *PgRowStorage[From, To]) error {
	if storage == nil || storage.transform == nil || storage.transform.registration == nil {
		return fmt.Errorf("missing typed backfill storage")
	}
	r := storage.transform.registration
	if !r.storageAttached || r.sealed || compiledRowBackfills[r] != nil || compiledRowPhysicalHistories[r.compiled] == nil {
		return fmt.Errorf("duplicate, closed or unbound backfill storage")
	}
	d := r.compiled.inventory.Transforms[r.index]
	binding := &pgRowBackfillBinding{registration: r}
	binding.read = func(ctx context.Context, tx pgx.Tx, plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity, cursor json.RawMessage, limit int) ([]pgRowBackfillItem, error) {
		if plan == nil || entity == nil || plan.compiled != r.compiled || plan.version != d.MigrationVersion || entity.identity != d.Entity || entity.generation != d.TargetGeneration || limit < 1 || limit > 10000 {
			return nil, fmt.Errorf("backfill read differs from typed window")
		}
		previous, err := pgCompiledRowPhysicalPlan(r.database, plan.version-1)
		if err != nil {
			return nil, err
		}
		old := previous.entity(entity.identity)
		if old == nil {
			return nil, fmt.Errorf("backfill lacks exact previous projection")
		}
		key := pgPhysicalPrimary(entity)
		if key == "" || pgPhysicalPrimary(old) != key {
			return nil, fmt.Errorf("backfill primary key differs")
		}
		columns := []string{quoteIdentifier("_tesl_v")}
		for _, c := range entity.columns {
			columns = append(columns, quoteIdentifier(c.catalog.Name))
		}
		// The cursor round-trips through PostgreSQL's own declared key carrier. It is
		// never compared as text or decoded into an invented nominal Go row.
		cursorKey := "(pg_catalog.jsonb_populate_record(null::" + pgx.Identifier{plan.namespace, entity.table}.Sanitize() + ",pg_catalog.jsonb_build_object(" + pgLiteralString(key) + ",$1::jsonb)))." + quoteIdentifier(key)
		if column := entity.column(key); column != nil && column.catalog.Type == "jsonb" {
			// JSON null is a valid non-SQL-NULL JSONB key. populate_record
			// would collapse it to SQL NULL and lose the remainder of a pass.
			cursorKey = "$1::jsonb"
		}
		sql := "select " + strings.Join(columns, ",") + ",xmin::text as tesl_xmin,pg_catalog.pg_current_xact_id()::text as tesl_xid8,pg_catalog.to_jsonb(" + quoteIdentifier(key) + ") as tesl_cursor,pg_catalog.clock_timestamp() as tesl_read_at from " + pgx.Identifier{plan.namespace, entity.table}.Sanitize() + " where \"_tesl_v\"=$2 and ($1::jsonb is null or " + quoteIdentifier(key) + ">" + cursorKey + ") order by " + quoteIdentifier(key) + " limit $3"
		var cursorArg any
		if len(cursor) > 0 {
			cursorArg = []byte(cursor)
		}
		readStarted := time.Now()
		rows, err := tx.Query(ctx, sql, cursorArg, d.PreviousGeneration, limit)
		if err != nil {
			return nil, err
		}
		return pgx.CollectRows(rows, func(row pgx.CollectableRow) (pgRowBackfillItem, error) {
			fields := row.FieldDescriptions()
			count := len(columns)
			if len(fields) != count+4 || fields[count].Name != "tesl_xmin" || fields[count+1].Name != "tesl_xid8" || fields[count+2].Name != "tesl_cursor" || fields[count+3].Name != "tesl_read_at" {
				return pgRowBackfillItem{}, fmt.Errorf("backfill source snapshot metadata differs")
			}
			var xmin, xid8 string
			var keyJSON json.RawMessage
			var readAt time.Time
			dest := make([]any, len(fields))
			dest[count] = &xmin
			dest[count+1] = &xid8
			dest[count+2] = &keyJSON
			dest[count+3] = &readAt
			if err := row.Scan(dest...); err != nil {
				return pgRowBackfillItem{}, err
			}
			if _, err := strconv.ParseUint(xmin, 10, 32); err != nil {
				return pgRowBackfillItem{}, fmt.Errorf("invalid source tuple xmin")
			}
			if _, err := strconv.ParseUint(xid8, 10, 64); err != nil {
				return pgRowBackfillItem{}, fmt.Errorf("invalid source full transaction id")
			}
			indices := make([]int, count)
			for i := range indices {
				indices[i] = i
			}
			physical := &pgRowProjectedRow{row: row, indices: indices, fields: fields[:count]}
			projection, err := pgPhysicalProjection(physical, entity, old, storage.source)
			if err != nil {
				return pgRowBackfillItem{}, err
			}
			source, err := storage.Decode(PgRowProjectionPlan{storage.source}, projection)
			if err != nil {
				return pgRowBackfillItem{}, err
			}
			encoded, err := storage.EncodeSource(source)
			if err != nil {
				return pgRowBackfillItem{}, err
			}
			values, err := encoded.Parameters(PgRowProjectionPlan{storage.source})
			if err != nil {
				return pgRowBackfillItem{}, err
			}
			var originalKey any
			found := false
			for i, name := range storage.source.fields {
				if old.field(name) == key {
					if i >= len(values) {
						return pgRowBackfillItem{}, fmt.Errorf("source key encoding missing")
					}
					originalKey = values[i]
					found = true
					break
				}
			}
			if !found {
				return pgRowBackfillItem{}, fmt.Errorf("source key projection missing")
			}
			item := pgRowBackfillItem{cursor: append(json.RawMessage(nil), keyJSON...)}
			item.convert = func() (pgRowBackfillCommit, error) {
				migrated, err := storage.transform.Run(source)
				if err != nil {
					return nil, err
				}
				if migrated.Tag != MigratedRow {
					return nil, fmt.Errorf("stored row rejected by checked backfill migration")
				}
				// The typed result is captured here after the read transaction has ended.
				return func(ctx context.Context, a *pgRowTransactionAdmission) (bool, error) {
					if a == nil || a.plan != plan || a.entity != entity {
						return false, fmt.Errorf("backfill commit belongs to another admitted window")
					}
					write, err := pgMaterializePhysicalWrite(a, storage, migrated.RowValue)
					if err != nil {
						return false, err
					}
					return pgCommitBackfillRow(ctx, a, write, originalKey, xmin, xid8, readAt, readStarted, d.PreviousGeneration)
				}, nil
			}
			return item, nil
		})
	}
	compiledRowBackfills[r] = binding
	return nil
}

func pgLiteralString(value string) string { return "'" + strings.ReplaceAll(value, "'", "''") + "'" }

// The worker holds its current lease row through this entire transaction. The
// tuple guard and full transaction-id bound exclude both old-writer races and
// xmin reuse after wraparound. A skipped CAS is not a materializing write.
func pgCommitBackfillRow(ctx context.Context, a *pgRowTransactionAdmission, row pgPhysicalWrite, originalKey any, xmin, xid8 string, readAt, readStarted time.Time, previous int) (changed bool, err error) {
	if err = a.check(true); err != nil {
		return false, err
	}
	if a.backfill == nil || a.backfill.leaseToken <= 0 {
		return false, fmt.Errorf("backfill write requires a live fenced worker lease")
	}
	if time.Since(readStarted) > 30*time.Second {
		return false, fmt.Errorf("backfill source snapshot exceeded bounded age")
	}
	assignments := make([]string, len(row.columns))
	args := append([]any(nil), row.values...)
	for i, column := range row.columns {
		assignments[i] = quoteIdentifier(column) + "=$" + strconv.Itoa(i+1)
	}
	base := len(args)
	args = append(args, originalKey, row.primary, xmin, xid8, readAt, previous)
	p := func(offset int) string { return "$" + strconv.Itoa(base+offset) }
	key := quoteIdentifier(pgPhysicalPrimary(a.entity))
	sql := "update " + pgx.Identifier{a.plan.namespace, a.entity.table}.Sanitize() + " set " + strings.Join(assignments, ",") + " where " + key + "=" + p(1) + " and " + key + " is not distinct from " + p(2) + " and xmin=" + p(3) + "::xid and \"_tesl_v\"=" + p(6) + " and pg_catalog.pg_current_xact_id()::text::numeric-" + p(4) + "::numeric between 0 and 2147483647 and pg_catalog.clock_timestamp() between " + p(5) + "::timestamptz and " + p(5) + "::timestamptz+interval '30 seconds'"
	err = a.withWriter(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, sql, args...)
		if err != nil {
			return err
		}
		if tag.RowsAffected() > 1 {
			return fmt.Errorf("backfill primary key matched multiple rows")
		}
		changed = tag.RowsAffected() == 1
		if !changed {
			return nil
		}
		migrationBoundary("row-backfill-after-dml")
		return a.latchProcessing(ctx)
	})
	return changed, err
}
