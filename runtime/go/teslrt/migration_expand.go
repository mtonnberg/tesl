package teslrt

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// ExecutePgMigrationExpansion borrows a dedicated idle Worker connection. The
// one-time installer must already have provisioned protected control state. It
// applies only additive table/column operations; populated-table index work and
// transformations refuse before any entity changes. It never calls the legacy
// bootstrap, adopts a lookalike, removes storage or admits application requests.
func ExecutePgMigrationExpansion(ctx context.Context, conn *pgx.Conn, history PgCompiledMigrationHistory, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	var result PgMigrationControlState
	// Validate the complete linked artifact before connecting its metadata to SQL.
	if _, err := history.ExpansionPlan(1); err != nil {
		return result, err
	}
	if conn == nil || conn.IsClosed() || conn.PgConn().TxStatus() != 'I' {
		return result, fmt.Errorf("migration coordination requires an idle, exclusively borrowed connection")
	}
	// A request login deliberately has no TEMP privilege. Refuse the wrong
	// executor identity before inspection attempts its temporary catalog probes,
	// and repeat the identity check after waiting for the boot lock below.
	var currentUser, sessionUser string
	if err := conn.QueryRow(ctx, "select current_user, session_user").Scan(&currentUser, &sessionUser); err != nil {
		return result, err
	}
	if currentUser != roles.Worker || sessionUser != roles.Worker {
		return result, fmt.Errorf("migration expansion requires the configured worker identity")
	}
	state, err := InspectPgMigrationControl(ctx, conn, history.Namespace, roles)
	if err != nil {
		return result, err
	}
	if !state.Present {
		return result, fmt.Errorf("migration control is not installed; run the one-time installer")
	}
	err = pgMigrationSessionLock(ctx, conn, state.FenceNamespace, 2147483647, true, func() error {
		return pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
			// Recheck after the boot-lock wait. This snapshot must follow the
			// previous executor's commit, and may not use cached installation IDs.
			if err := pgControlRoles(ctx, tx, roles, false); err != nil {
				return err
			}
			var currentUser, sessionUser string
			if err := tx.QueryRow(ctx, "select current_user, session_user").Scan(&currentUser, &sessionUser); err != nil {
				return err
			}
			if currentUser != roles.Worker || sessionUser != roles.Worker {
				return fmt.Errorf("migration expansion requires the configured worker identity")
			}
			fresh, err := pgInspectControl(ctx, tx, history.Namespace, roles)
			if err != nil {
				return err
			}
			if fresh.DatabaseUUID != state.DatabaseUUID || fresh.FenceNamespace != state.FenceNamespace {
				return fmt.Errorf("migration installation identity changed while acquiring the boot lock")
			}
			plan, err := history.ExpansionPlan(fresh.InitialVersion)
			if err != nil {
				return err
			}
			intents, err := pgReadExpansionIntents(ctx, tx, plan.Namespace)
			if err != nil {
				return err
			}
			if err := pgVerifyExpansionHistory(fresh, plan, intents); err != nil {
				return err
			}
			for _, step := range plan.Steps {
				if step.Version <= fresh.Current {
					continue
				}
				if !step.EpochPreserving {
					return fmt.Errorf("migration V%d requires an epoch transition; additive execution refuses", step.Version)
				}
				for _, op := range step.Operations {
					if op.Kind == "build-index-concurrently" || op.Kind == "retain-index" {
						return fmt.Errorf("migration V%d index changes require the concurrent-index executor", step.Version)
					}
				}
			}
			catalog, err := pgExpansionRecordedCatalog(plan, intents)
			if err != nil {
				return err
			}
			if err := pgVerifyExpansionCatalog(ctx, tx, plan.Namespace, roles.Worker, catalog); err != nil {
				return err
			}
			if err := pgVerifyRequestGrants(ctx, tx, plan.Namespace, roles, catalog); err != nil {
				return err
			}
			// End the validation snapshot before the short DDL transactions. The
			// session boot lock and shared installer lock remain held throughout.
			if err := tx.Rollback(ctx); err != nil {
				return err
			}
			if err := pgApplyExpansion(ctx, conn, plan, roles, fresh.Current, intents); err != nil {
				return err
			}
			result, err = InspectPgMigrationControl(ctx, conn, plan.Namespace, roles)
			return err
		})
	})
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return result, nil
}

func pgExpansionTransaction(ctx context.Context, conn *pgx.Conn, f func(pgx.Tx) error) (resultErr error) {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			resultErr = errors.Join(resultErr, err)
			_ = conn.Close(cleanup)
		}
	}()
	if err := pgControlSession(ctx, tx); err != nil {
		return err
	}
	if err := f(tx); err != nil {
		return err
	}
	migrationBoundary("expansion-before-commit")
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	migrationBoundary("expansion-after-commit")
	return nil
}

func pgApplyExpansion(ctx context.Context, conn *pgx.Conn, plan PgMigrationExpansionPlan, roles PgMigrationControlRoles, current int, intents map[int]*pgExpansionIntent) error {
	ns := quoteIdentifier(plan.Namespace) + "."
	for _, step := range plan.Steps {
		if step.Version <= current {
			continue
		}
		if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, "select "+ns+"tesl_begin_expansion($1::integer,$2::text,$3::text,$4::text,$5::text,$6::integer,$7::boolean)",
				step.Version, step.SnapshotHash, step.StepHash, plan.SourceCompilerABI, plan.StoredValueCompatibility, len(step.Operations), step.EpochPreserving)
			return err
		}); err != nil {
			return err
		}
		if intents[step.Version] == nil {
			intents[step.Version] = &pgExpansionIntent{Version: step.Version, SnapshotHash: step.SnapshotHash, ArtifactHash: step.StepHash,
				SourceABI: plan.SourceCompilerABI, StoredValueCompatibility: plan.StoredValueCompatibility, OperationCount: len(step.Operations), EpochPreserving: step.EpochPreserving}
		}
		r := intents[step.Version]
		for ordinal := len(r.Objects); ordinal < len(step.Operations); ordinal++ {
			hash, err := step.ObjectHash(ordinal)
			if err != nil {
				return err
			}
			if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
				if err := pgExecuteExpansionOperation(ctx, tx, plan.Namespace, step.Operations[ordinal]); err != nil {
					return err
				}
				if roles.Request != "" && step.Operations[ordinal].Kind == "create-table" {
					if _, err := tx.Exec(ctx, "grant select,insert,update,delete on "+pgx.Identifier{plan.Namespace, step.Operations[ordinal].Table}.Sanitize()+" to "+quoteIdentifier(roles.Request)); err != nil {
						return err
					}
				}
				migrationBoundary("expansion-after-ddl")
				// Verify the uncommitted catalog before recording success. The
				// savepoint used by the observer preserves this transaction's DDL.
				r.Objects = append(r.Objects, hash)
				catalog, err := pgExpansionRecordedCatalog(plan, intents)
				r.Objects = r.Objects[:len(r.Objects)-1]
				if err != nil {
					return err
				}
				if err := pgVerifyExpansionCatalog(ctx, tx, plan.Namespace, roles.Worker, catalog); err != nil {
					return err
				}
				if err := pgVerifyRequestGrants(ctx, tx, plan.Namespace, roles, catalog); err != nil {
					return err
				}
				_, err = tx.Exec(ctx, "select "+ns+"tesl_record_expansion_object($1::integer,$2::integer,$3::text)", step.Version, ordinal, hash)
				return err
			}); err != nil {
				return fmt.Errorf("expand V%d object %d: %w", step.Version, ordinal, err)
			}
			r.Objects = append(r.Objects, hash)
		}
		if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
			if err := pgVerifyExpansionCatalog(ctx, tx, plan.Namespace, roles.Worker, step.Catalog); err != nil {
				return err
			}
			if err := pgVerifyRequestGrants(ctx, tx, plan.Namespace, roles, step.Catalog); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "select "+ns+"tesl_record_expanded($1::integer)", step.Version)
			return err
		}); err != nil {
			return err
		}
	}
	return nil
}

func pgVerifyExpansionCatalog(ctx context.Context, tx pgx.Tx, namespace, owner string, catalog []PgMigrationCatalogTable) error {
	report, err := pgInspectMigrationCatalogInTx(ctx, tx, namespace, owner, catalog)
	if err != nil {
		return err
	}
	for _, issues := range [][]PgMigrationCatalogIssue{report.Missing, report.Drift} {
		if len(issues) > 0 {
			issue := issues[0]
			return fmt.Errorf("migration catalog %s.%s: %s", issue.Table, issue.Object, issue.Reason)
		}
	}
	return nil
}

func pgExecuteExpansionOperation(ctx context.Context, tx pgx.Tx, namespace string, op PgMigrationExpansionOperation) error {
	table := pgx.Identifier{namespace, op.Table}.Sanitize()
	switch op.Kind {
	case "create-table":
		columns := make([]string, len(op.Columns))
		for i, c := range op.Columns {
			column, err := pgMigrationColumnSQL(c)
			if err != nil {
				return err
			}
			columns[i] = column
		}
		if _, err := tx.Exec(ctx, "CREATE TABLE "+table+" ("+strings.Join(columns, ",")+")"); err != nil {
			return err
		}
		for _, index := range op.Indexes {
			unique := ""
			if index.Unique {
				unique = "UNIQUE "
			}
			keys := make([]string, len(index.Columns))
			for i, key := range index.Columns {
				keys[i] = quoteIdentifier(key)
			}
			if _, err := tx.Exec(ctx, "CREATE "+unique+"INDEX "+quoteIdentifier(index.Name)+" ON "+table+" USING btree ("+strings.Join(keys, ",")+")"); err != nil {
				return err
			}
		}
	case "add-column":
		column, err := pgMigrationColumnSQL(*op.Column)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "ALTER TABLE "+table+" ADD COLUMN "+column)
		return err
	case "retain-table": // Retained storage remains readable by older versions.
	default:
		return fmt.Errorf("unsupported additive expansion operation %q", op.Kind)
	}
	return nil
}
