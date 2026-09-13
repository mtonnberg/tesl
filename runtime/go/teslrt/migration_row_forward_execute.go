package teslrt

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

func pgExecuteRowForward(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	var initial, result PgMigrationControlState
	if b.target == nil || b.target.compiled == nil || b.physical == nil {
		return result, fmt.Errorf("row expansion requires exact compiler-linked physical history")
	}
	plan, err := pgCompiledRowPhysicalPlan(b.database, b.target.version)
	if err != nil {
		return result, err
	}
	if plan != b.target {
		return result, fmt.Errorf("row expansion physical owner changed")
	}
	previous, err := pgCompiledRowPredecessorPlan(b.database, plan.version)
	if err != nil {
		return result, err
	}
	operations, err := pgRowForwardOperations(previous, plan)
	if err != nil {
		return result, err
	}
	err = pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles, false); err != nil {
			return err
		}
		var user, session string
		if err := tx.QueryRow(ctx, "select current_user,session_user").Scan(&user, &session); err != nil {
			return err
		}
		if user != roles.Worker || session != roles.Worker {
			return fmt.Errorf("row expansion requires exact Worker login")
		}
		var err error
		initial, _, err = pgReadRowBaselineState(ctx, tx, b, roles, true)
		return err
	})
	if err != nil {
		return result, err
	}
	if initial.Current < plan.version-1 {
		return result, fmt.Errorf("row transformation requires its installed final predecessor")
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	err = pgMigrationSessionLock(ctx, conn, initial.FenceNamespace, 2147483647, true, func() error {
		completed := 0
		err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
			state, _, err := pgReadRowBaselineState(ctx, tx, b, roles, true)
			if err != nil {
				return err
			}
			if state.DatabaseUUID != initial.DatabaseUUID || state.FenceNamespace != initial.FenceNamespace {
				return fmt.Errorf("row identity changed while waiting for expansion lock")
			}
			result = state
			intents, err := pgReadExpansionIntents(ctx, tx, b.history.Namespace)
			if err != nil {
				return err
			}
			if intent := intents[plan.version]; intent != nil {
				completed = len(intent.Objects)
			}
			return nil
		})
		if err != nil || result.Current >= plan.version {
			return err
		}
		contract, err := pgRowBaselineHex(plan.contract)
		if err != nil {
			return err
		}
		if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, "select "+ns+"tesl_register_row_physical($1,$2,$3,$4,$5,$6,$7)", plan.version, previous.hash, contract, plan.hash, b.history.SourceCompilerABI, b.history.StoredValueCompatibility, len(operations))
			return err
		}); err != nil {
			return err
		}
		migrationBoundary("row-forward-after-manifest")
		if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, "select "+ns+"tesl_begin_expansion($1,$2,$2,$3,$4,$5,false)", plan.version, plan.hash, b.history.SourceCompilerABI, b.history.StoredValueCompatibility, len(operations))
			return err
		}); err != nil {
			return err
		}
		migrationBoundary("row-forward-after-intent")
		var forward *pgRowForwardManifest
		if err := pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
			state, err := pgInspectRowControl(ctx, tx, b.history.Namespace, roles)
			if err != nil {
				return err
			}
			intents, err := pgReadExpansionIntents(ctx, tx, b.history.Namespace)
			if err != nil {
				return err
			}
			forward, err = pgReadRowForwardManifest(ctx, tx, b)
			if err != nil {
				return err
			}
			return pgVerifyRowExpansionHistory(state, b, intents, forward, true)
		}); err != nil {
			return err
		}
		if forward == nil || forward.plan.hash != plan.hash {
			return fmt.Errorf("expansion catalog lacks its exact newest manifest")
		}
		for i := completed; i < len(operations); i++ {
			operation := operations[i]
			if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
				if operation.column != nil {
					if err := pgExecuteExpansionOperation(ctx, tx, b.history.Namespace, PgMigrationExpansionOperation{Kind: "add-column", Table: operation.entity.table, Column: &operation.column.catalog}); err != nil {
						return err
					}
				} else {
					if err := pgExecuteRowInvalidation(ctx, tx, b.history.Namespace, roles, pgRowInvalidationFor(b.history.Namespace, operation.entity, operation.window)); err != nil {
						return err
					}
				}
				migrationBoundary("row-forward-after-ddl")
				if err := pgVerifyRowForwardCatalog(ctx, tx, b, roles, len(b.entities), forward, i+1); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, "select "+ns+"tesl_record_expansion_object($1,$2,$3)", plan.version, i, pgMigrationObjectHash(plan.hash, i))
				return err
			}); err != nil {
				return err
			}
			migrationBoundary("row-forward-after-receipt")
		}
		if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
			if _, _, err := pgReadRowBaselineState(ctx, tx, b, roles, true); err != nil {
				return err
			}
			migrationBoundary("row-forward-before-publication")
			_, err := tx.Exec(ctx, "select "+ns+"tesl_record_expanded($1)", plan.version)
			return err
		}); err != nil {
			return err
		}
		return pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
			var err error
			result, _, err = pgReadRowBaselineState(ctx, tx, b, roles, false)
			return err
		})
	})
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return result, nil
}
