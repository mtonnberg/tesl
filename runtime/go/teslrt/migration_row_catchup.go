package teslrt

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// The finite deployment command uses the same protected operations as the
// worker/Contract commands. It lends one boot-locked session to each step; no
// intermediate application registration or request identity is manufactured.
func pgExecuteRowCatchup(ctx context.Context, conn *pgx.Conn, config *pgx.ConnConfig, b *pgRowBaseline, roles PgMigrationControlRoles) (result PgMigrationControlState, resultErr error) {
	if b == nil || b.target == nil || b.target.version != b.history.CurrentVersion {
		return result, fmt.Errorf("schema catch-up requires the complete current compiled row history")
	}
	windows := make(map[int]*pgRowBaseline)
	for version := 1; version <= b.history.CurrentVersion; version++ {
		window, err := pgRowExecutionWindow(b, version)
		if err != nil {
			return result, err
		}
		if len(window.target.queueConversions) != 0 {
			return result, fmt.Errorf("schema catch-up V%d requires queue conversion coordination, which is not yet supported by row catch-up", version)
		}
		windows[version] = window
	}
	observe := func() (state PgMigrationControlState, err error) {
		query, cancel := context.WithTimeout(ctx, pgLeaseTimeout())
		defer cancel()
		err = pgControlTransaction(query, conn, false, func(tx pgx.Tx) error {
			if err := pgControlRoles(query, tx, roles, false); err != nil {
				return err
			}
			var worker bool
			if err := tx.QueryRow(query, "select current_user=$1 and session_user=$1", roles.Worker).Scan(&worker); err != nil {
				return err
			}
			if !worker {
				return fmt.Errorf("schema catch-up requires exact Worker login")
			}
			ready := true
			state, _, err = pgReadRowBaselineState(query, tx, b, roles, true, &ready)
			return err
		})
		return state, err
	}
	initial, err := observe()
	if err != nil {
		return result, err
	}
	resultErr = pgMigrationSessionLock(ctx, conn, initial.FenceNamespace, 2147483647, true, func() error {
		state, err := observe()
		if err != nil {
			return err
		}
		if state.DatabaseUUID != initial.DatabaseUUID || state.FenceNamespace != initial.FenceNamespace {
			return fmt.Errorf("schema catch-up installation changed while waiting for boot lock")
		}
		// Preflight all remaining typed operations and reviewed finality before
		// publishing any missing prefix. A blocked deployment remains resumable.
		retireThrough := state.MinVersion
		for version := max(2, state.Current); version <= b.history.CurrentVersion; version++ {
			window := windows[version]
			plan := window.target
			previous, err := pgCompiledRowPredecessorPlan(b.database, version)
			if err != nil {
				return err
			}
			if _, err := pgRowForwardOperations(previous, plan); err != nil {
				return err
			}
			for _, conversion := range plan.windows {
				if _, err := pgRowBackfillBindingFor(b.database, plan, plan.entity(conversion.entity)); err != nil {
					return fmt.Errorf("schema catch-up V%d: %w", version, err)
				}
			}
			if !pgRowEpochPreserving(plan) {
				retireThrough = max(retireThrough, version-1)
				if version < b.history.CurrentVersion {
					if _, err := pgRowContractFor(b.database, version); err != nil {
						return fmt.Errorf("schema catch-up requires reviewed Contract V%d: %w", version, err)
					}
					retireThrough = max(retireThrough, version)
				}
			}
		}
		query, cancel := context.WithTimeout(ctx, pgLeaseTimeout())
		err = pgRowCatchupRequiresDrained(query, conn, b.history.Namespace, state.MinVersion, retireThrough)
		cancel()
		if err != nil {
			return err
		}
		origin, stop := context.WithTimeout(ctx, pgLeaseTimeout())
		state, err = pgExecuteRowOrigin(origin, conn, b, roles)
		stop()
		if err != nil {
			return err
		}
		for state.Current <= b.history.CurrentVersion {
			window := windows[state.Current]
			// Complete all durable jobs, not just request-readiness indexes.
			settings, err := pgIndexWorkerConfiguration()
			if err != nil {
				return err
			}
			connect, stop := context.WithTimeout(ctx, pgLeaseTimeout())
			ddl, err := pgx.ConnectConfig(connect, config)
			stop()
			if err != nil {
				return err
			}
			err = pgRunIndexWorkerSource(ctx, ddl, config, pgIndexWorkerSource{PgCompiledMigrationHistory: b.history, row: window, untilValid: true}, roles, state, nil, settings)
			if err != nil {
				return err
			}
			if state.Current == b.history.CurrentVersion {
				result = state
				return nil
			}
			if !pgRowEpochPreserving(window.target) {
				state, err = pgExecuteRowContractOn(ctx, conn, config, window, roles, state.Current, true)
				if err != nil {
					return fmt.Errorf("schema catch-up Contract V%d: %w", window.target.version, err)
				}
			}
			next := windows[state.Current+1]
			if !pgRowEpochPreserving(next.target) && state.MinVersion < state.Current {
				if _, err := pgExecuteRowEpoch(ctx, conn, window, roles, state.Current, false, false); err != nil {
					return err
				}
			}
			step, stop := context.WithTimeout(ctx, pgLeaseTimeout())
			state, err = pgExecuteRowForward(step, conn, next, roles)
			stop()
			if err != nil {
				return fmt.Errorf("schema catch-up expansion V%d: %w", next.target.version, err)
			}
			migrationBoundary("row-catchup-after-step")
		}
		return fmt.Errorf("schema catch-up database is newer than this binary")
	})
	return result, resultErr
}

// Heartbeats are an additional deployment guard, not a substitute for the
// transaction fences held by Contract/epoch retirement. Recheck under those
// fences before retiring any admitted version; catch-up never implies force.
func pgRowCatchupRequiresDrained(ctx context.Context, conn *pgx.Conn, namespace string, from, through int) error {
	var recent bool
	if err := conn.QueryRow(ctx, "select exists(select 1 from "+pgx.Identifier{namespace, "tesl_schema_instances"}.Sanitize()+" where version >= $1 and version < $2 and last_seen > pg_catalog.clock_timestamp()-interval '30 seconds')", from, through).Scan(&recent); err != nil {
		return err
	}
	if recent {
		return fmt.Errorf("schema catch-up must retire V%d through V%d; stop those application/worker instances, wait 30 seconds after their last heartbeat, then rerun --schema catch-up", from, through-1)
	}
	return nil
}
