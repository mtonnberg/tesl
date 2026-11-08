package teslrt

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

const pgRowBulkUpdateMaxBytes = 8 << 20

// Bound retained encoded arguments as well as row/parameter counts. Unknown
// driver-specific carriers use the original path rather than speculative encoding.
func pgRowBulkUpdateBytes(previous any, row pgPhysicalWrite) (int, bool) {
	size := 0
	add := func(value any) bool {
		amount := 64 // Scalar wire representation plus conservative per-value overhead.
		switch value := value.(type) {
		case string:
			if len(value) > pgRowBulkUpdateMaxBytes {
				return false
			}
			amount += len(value)
		case []byte:
			if len(value) > pgRowBulkUpdateMaxBytes {
				return false
			}
			amount += len(value)
		case json.RawMessage:
			if len(value) > pgRowBulkUpdateMaxBytes {
				return false
			}
			amount += len(value)
		case pgtype.Numeric:
			// Generated Int/Int32 parameters use exponent zero. Bit length is
			// a conservative bound on coefficient bytes/decimal digits without
			// allocating another large decimal representation merely to size it.
			if value.Exp != 0 {
				return false
			}
			if value.Int != nil {
				bits := value.Int.BitLen()
				if bits > pgRowBulkUpdateMaxBytes {
					return false
				}
				amount += bits
			}
		case nil, bool, int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64, float32, float64, time.Time:
		default:
			return false
		}
		if amount > pgRowBulkUpdateMaxBytes-size {
			return false
		}
		size += amount
		return true
	}
	if !add(previous) || !add(row.primary) {
		return 0, false
	}
	for _, value := range row.values {
		if !add(value) {
			return 0, false
		}
	}
	return size, true
}

// Only the verified settled projection qualifies. Active migration windows,
// future-generation observations, staged guards, secondary uniqueness and debug
// capture retain the ordered per-row path. This does not cache SQL admission.
func pgCanBulkRowUpdate(a *pgRowTransactionAdmission, capture []func(PgPlan) PgPlan) bool {
	if a == nil || a.check(true) != nil || a.plan == a.window ||
		len(capture) != 0 || len(a.currentGenerations) != 0 ||
		len(a.plan.stageGuards) != 0 || len(a.window.stageGuards) != 0 ||
		slices.ContainsFunc(a.entity.indexes, func(index PgMigrationCatalogIndex) bool { return index.Unique }) {
		return false
	}
	primary := a.entity.column(pgPhysicalPrimary(a.entity))
	if primary == nil {
		return false
	}
	switch primary.catalog.Type {
	case "text", "int4", "int8", "numeric", "bool":
		return true
	default:
		return false
	}
}

// The cursor has already locked and decoded these rows. Materialization still
// uses the checked codecs for every original and updated value. One preceding
// single-row write preserves the first-write boundary; all groups, writer state
// and processing checks remain in its admitted transaction and roll back together.
func pgUpdateMaterializedPhysicalRows(ctx context.Context, a *pgRowTransactionAdmission, before, rows []pgPhysicalWrite) (bool, error) {
	if err := a.check(true); err != nil {
		return false, err
	}
	if !pgCanBulkRowUpdate(a, nil) || len(rows) < 2 || len(rows) > 128 || len(before) != len(rows) {
		return false, nil
	}
	key := pgPhysicalPrimary(a.entity)
	primary := a.entity.column(key)
	if primary == nil {
		return false, nil
	}
	columns := rows[0].columns
	if len(columns) == 0 || (len(columns)+2)*len(rows) > 65535 {
		return false, nil
	}
	var types, aliases, assignments []string
	for index, name := range columns {
		typ := "pg_catalog.int2"
		if name != "_tesl_v" {
			column := a.entity.column(name)
			if column == nil {
				return false, nil
			}
			typ = pgMigrationTypeSQL(column.catalog.Type)
			if typ == "" {
				return false, nil
			}
		}
		alias := "c" + strconv.Itoa(index)
		types = append(types, typ)
		aliases = append(aliases, alias)
		if name != key {
			assignments = append(assignments, quoteIdentifier(name)+"=i."+alias)
		}
	}
	if len(assignments) == 0 {
		return false, nil
	}
	keyType := pgMigrationTypeSQL(primary.catalog.Type)
	types = append(types, keyType, keyType)
	aliases = append(aliases, "old_key", "new_key")
	var values []string
	var args []any
	bytes := 0
	for index, row := range rows {
		if !slices.Equal(row.columns, columns) || len(row.values) != len(columns) {
			return false, nil
		}
		size, supported := pgRowBulkUpdateBytes(before[index].primary, row)
		if !supported || size > pgRowBulkUpdateMaxBytes-bytes {
			return false, nil
		}
		bytes += size
		parameters := make([]string, len(types))
		for i, typ := range types {
			parameters[i] = "$" + strconv.Itoa(len(args)+i+1) + "::" + typ
		}
		args = append(args, row.values...)
		args = append(args, before[index].primary, row.primary)
		values = append(values, "("+strings.Join(parameters, ",")+")")
	}
	// PostgreSQL's own key equality controls duplicates and identity. A duplicate
	// source key produces no DML and falls back; an identity/count mismatch fails
	// the operation, whose outer admission rolls back even a caller-owned txn.
	query := "with input(" + strings.Join(aliases, ",") + ") as materialized (values " + strings.Join(values, ",") + ")," +
		" compatible as (select pg_catalog.count(*)=pg_catalog.count(distinct old_key) as ok from input)," +
		" changed as (update " + pgx.Identifier{a.plan.namespace, a.entity.table}.Sanitize() + " t set " + strings.Join(assignments, ",") +
		" from input i where (select ok from compatible) and t." + quoteIdentifier(key) + "=i.old_key and t." + quoteIdentifier(key) +
		" is not distinct from i.new_key returning 1) select (select ok from compatible),pg_catalog.count(*) from changed"
	used := false
	err := a.withWriter(ctx, func(tx pgx.Tx) error {
		var compatible bool
		var written int
		if err := tx.QueryRow(ctx, query, args...).Scan(&compatible, &written); err != nil {
			return err
		}
		if !compatible && written == 0 {
			return nil
		}
		if !compatible || written != len(rows) {
			return fmt.Errorf("migration bulk row update changed its primary key or lost its locked row")
		}
		used = true
		migrationBoundary("row-rmw-after-bulk")
		migrationBoundary("row-target-after-dml")
		return a.latchProcessing(ctx)
	})
	return used, err
}
