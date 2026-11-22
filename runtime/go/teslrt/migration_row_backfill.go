package teslrt

import (
	"context"
	"encoding/json"
	"errors"
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
type pgRowBackfillCommit func(*pgRowTransactionAdmission) (pgRowBackfillStatement, error)
type pgRowBackfillStatement struct {
	sql     string
	args    []any
	columns []string
}
type pgRowBackfillBinding struct {
	registration *pgRowRegistration
	read         func(context.Context, pgx.Tx, *pgRowPhysicalPlan, *pgRowPhysicalEntity, json.RawMessage, int) (pgRowBackfillChunk, error)
}

// One batch covers a bounded primary-key range: the next `limit` keys after the
// cursor, whether or not their rows still need conversion. A pass over a table
// whose rows are already converted therefore never runs one unbounded scan.
// next is the last key the range covered; exhausted means the range reached
// the end of the table, which completes the pass.
type pgRowBackfillChunk struct {
	items     []pgRowBackfillItem
	next      json.RawMessage
	exhausted bool
}

var compiledRowBackfills = map[*pgRowRegistration]*pgRowBackfillBinding{}

// pgRowRejectedError is a stored row its checked migration rejected. It names
// the entity and primary key so an operator can find and repair the row; the
// callback's reason text is not repeated, as for rejected queue payloads.
type pgRowRejectedError struct {
	entity string
	key    json.RawMessage
}

func (e *pgRowRejectedError) Error() string {
	return fmt.Sprintf("stored %s row with primary key %s was rejected by its checked migration", e.entity, e.key)
}

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
	d := r.compiled.transforms[r.index]
	binding := &pgRowBackfillBinding{registration: r}
	binding.read = func(ctx context.Context, tx pgx.Tx, plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity, cursor json.RawMessage, limit int) (chunk pgRowBackfillChunk, err error) {
		if plan == nil || entity == nil || plan.compiled != r.compiled || plan.version != d.MigrationVersion || entity.identity != d.Entity || entity.generation != d.TargetGeneration || limit < 1 || limit > 10000 {
			return chunk, fmt.Errorf("backfill read differs from typed window")
		}
		previous, err := pgCompiledRowPredecessorPlan(r.database, plan.version)
		if err != nil {
			return chunk, err
		}
		old := previous.entity(entity.identity)
		if old == nil {
			return chunk, fmt.Errorf("backfill lacks exact previous projection")
		}
		key := pgPhysicalPrimary(entity)
		if key == "" || pgPhysicalPrimary(old) != key {
			return chunk, fmt.Errorf("backfill primary key differs")
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
		boundKey := strings.Replace(cursorKey, "$1::jsonb", "$4::jsonb", 1)
		table := pgx.Identifier{plan.namespace, entity.table}.Sanitize()
		var cursorArg any
		if len(cursor) > 0 {
			cursorArg = []byte(cursor)
		}
		// The range's last key, found by walking at most `limit` primary-key
		// entries. No row means fewer than `limit` keys remain: this range
		// reaches the end of the table.
		var bound []byte
		if err := tx.QueryRow(ctx, "select pg_catalog.to_jsonb("+quoteIdentifier(key)+") from "+table+" where ($1::jsonb is null or "+quoteIdentifier(key)+">"+cursorKey+") order by "+quoteIdentifier(key)+" offset $2 limit 1", cursorArg, limit-1).Scan(&bound); err != nil {
			if !errors.Is(err, pgx.ErrNoRows) {
				return chunk, err
			}
			bound = nil
		}
		var boundArg any
		if bound != nil {
			boundArg = bound
		}
		sql := "select " + strings.Join(columns, ",") + ",xmin::text as tesl_xmin,pg_catalog.pg_current_xact_id()::text as tesl_xid8,pg_catalog.to_jsonb(" + quoteIdentifier(key) + ") as tesl_cursor,pg_catalog.clock_timestamp() as tesl_read_at from " + table + " where \"_tesl_v\"=$2 and ($1::jsonb is null or " + quoteIdentifier(key) + ">" + cursorKey + ") and ($4::jsonb is null or " + quoteIdentifier(key) + "<=" + boundKey + ") order by " + quoteIdentifier(key) + " limit $3"
		readStarted := time.Now()
		rows, err := tx.Query(ctx, sql, cursorArg, d.PreviousGeneration, limit, boundArg)
		if err != nil {
			return chunk, err
		}
		chunk.exhausted = bound == nil
		if bound != nil {
			chunk.next = json.RawMessage(bound)
		}
		chunk.items, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (pgRowBackfillItem, error) {
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
				migrated, err := storage.transform.Run(source, ctx)
				if err != nil {
					return nil, err
				}
				if migrated.Tag != RowChangeKeep && migrated.Tag != RowChangeDelete {
					return nil, &pgRowRejectedError{entity: entity.identity, key: append(json.RawMessage(nil), keyJSON...)}
				}
				// The typed result is captured here after the read transaction has ended.
				return func(a *pgRowTransactionAdmission) (pgRowBackfillStatement, error) {
					if a == nil || a.plan != plan || a.entity != entity {
						return pgRowBackfillStatement{}, fmt.Errorf("backfill commit belongs to another admitted window")
					}
					if migrated.Tag == RowChangeDelete {
						return pgPrepareBackfillDelete(a, originalKey, xmin, xid8, readAt, readStarted, d.PreviousGeneration)
					}
					write, err := pgMaterializePhysicalWrite(a, storage, migrated.KeepValue, encoded)
					if err != nil {
						return pgRowBackfillStatement{}, err
					}
					return pgPrepareBackfillRow(a, write, originalKey, xmin, xid8, readAt, readStarted, d.PreviousGeneration)
				}, nil
			}
			return item, nil
		})
		return chunk, err
	}
	compiledRowBackfills[r] = binding
	return nil
}

func pgLiteralString(value string) string { return "'" + strings.ReplaceAll(value, "'", "''") + "'" }

// Delete only the exact tuple that was decoded. A concurrent old-writer update
// causes a skipped CAS and a later rescan, just like conversion. SQL constraints,
// the Worker lease, ABI latch, and progress update share the same transaction.
func pgPrepareBackfillDelete(a *pgRowTransactionAdmission, key any, xmin, xid8 string, readAt, readStarted time.Time, previous int) (pgRowBackfillStatement, error) {
	if err := a.check(true); err != nil {
		return pgRowBackfillStatement{}, err
	}
	if a.backfill == nil || a.backfill.leaseToken <= 0 {
		return pgRowBackfillStatement{}, fmt.Errorf("backfill deletion requires a live fenced worker lease")
	}
	if time.Since(readStarted) > 30*time.Second {
		return pgRowBackfillStatement{}, fmt.Errorf("backfill source snapshot exceeded bounded age")
	}
	sql := "delete from " + pgx.Identifier{a.plan.namespace, a.entity.table}.Sanitize() + " where " + pgBackfillPredicate("", pgPhysicalPrimary(a.entity), func(i int) string { return "$" + strconv.Itoa(i) })
	return pgRowBackfillStatement{sql: sql, args: []any{key, key, xmin, xid8, readAt, previous}}, nil
}

// The worker holds its current lease row through this entire transaction. The
// tuple guard and full transaction-id bound exclude both old-writer races and
// xmin reuse after wraparound. A skipped CAS is not a materializing write.
func pgPrepareBackfillRow(a *pgRowTransactionAdmission, row pgPhysicalWrite, originalKey any, xmin, xid8 string, readAt, readStarted time.Time, previous int) (pgRowBackfillStatement, error) {
	if err := a.check(true); err != nil {
		return pgRowBackfillStatement{}, err
	}
	if a.backfill == nil || a.backfill.leaseToken <= 0 {
		return pgRowBackfillStatement{}, fmt.Errorf("backfill write requires a live fenced worker lease")
	}
	if time.Since(readStarted) > 30*time.Second {
		return pgRowBackfillStatement{}, fmt.Errorf("backfill source snapshot exceeded bounded age")
	}
	assignments := make([]string, len(row.columns))
	args := append([]any(nil), row.values...)
	for i, column := range row.columns {
		assignments[i] = quoteIdentifier(column) + "=$" + strconv.Itoa(i+1)
	}
	base := len(args)
	args = append(args, originalKey, row.primary, xmin, xid8, readAt, previous)
	p := func(offset int) string { return "$" + strconv.Itoa(base+offset) }
	sql := "update " + pgx.Identifier{a.plan.namespace, a.entity.table}.Sanitize() + " set " + strings.Join(assignments, ",") + " where " + pgBackfillPredicate("", pgPhysicalPrimary(a.entity), p)
	return pgRowBackfillStatement{sql: sql, args: args, columns: row.columns}, nil
}

// Shared by individual and bulk publication: neither path may weaken a tuple,
// generation, full transaction-ID or age precondition independently.
func pgBackfillPredicate(prefix, primary string, argument func(int) string) string {
	key := prefix + quoteIdentifier(primary)
	return key + "=" + argument(1) + " and " + key + " is not distinct from " + argument(2) +
		" and " + prefix + "xmin=" + argument(3) + "::xid and " + prefix + "\"_tesl_v\"=" + argument(6) +
		" and pg_catalog.pg_current_xact_id()::text::numeric-" + argument(4) + "::numeric between 0 and 2147483647" +
		" and pg_catalog.clock_timestamp() between " + argument(5) + "::timestamptz and " + argument(5) + "::timestamptz+interval '30 seconds'"
}
