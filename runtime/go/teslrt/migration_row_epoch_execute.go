package teslrt

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

type pgRowEpochPreview struct {
	Version         int                         `json:"version"`
	Kind            string                      `json:"kind"`
	Database        string                      `json:"database"`
	FromVersion     int                         `json:"fromVersion"`
	ThroughVersion  int                         `json:"throughVersion"`
	Forced          bool                        `json:"forced"`
	DryRun          bool                        `json:"dryRun"`
	RetirementHash  string                      `json:"retirementHash"`
	RecentInstances []PgMigrationInstanceStatus `json:"recentInstances"`
	MinVersion      int                         `json:"minVersion"`
	CompatFloor     int                         `json:"compatFloor"`
}

// Acquire the complete pair of retiring lock domains or release every key.
// Never queue a writer while waiting for another version's long transaction.
func pgRowEpochDrain(ctx context.Context, conn *pgx.Conn, fence, from, through int, run func() error) (result error) {
	migrationBoundary("row-epoch-before-compatibility-barrier")
	type key struct{ domain, version int }
	for {
		acquired := []key{}
		release := func() error {
			cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			for i := len(acquired) - 1; i >= 0; i-- {
				var ok bool
				err := conn.QueryRow(cleanup, "select pg_catalog.pg_advisory_unlock($1::integer,$2::integer)", acquired[i].domain, acquired[i].version).Scan(&ok)
				if err != nil || !ok {
					_ = conn.Close(cleanup)
					if err != nil {
						return err
					}
					return fmt.Errorf("epoch retirement lock lost")
				}
			}
			return nil
		}
		busy := false
		for version := from; version < through && !busy; version++ {
			for _, domain := range []int{fence, -fence} {
				var ok bool
				if err := conn.QueryRow(ctx, "select pg_catalog.pg_try_advisory_lock($1::integer,$2::integer)", domain, version).Scan(&ok); err != nil {
					cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					_ = conn.Close(cleanup)
					return err
				}
				if !ok {
					busy = true
					break
				}
				acquired = append(acquired, key{domain, version})
			}
		}
		if !busy {
			defer func() { result = errors.Join(result, release()) }()
			return run()
		}
		if err := release(); err != nil {
			return err
		}
		migrationBoundary("row-epoch-compatibility-busy")
		if err := pgIndexWait(ctx, 25*time.Millisecond); err != nil {
			return err
		}
	}
}

func pgExecuteRowEpoch(parent context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, through int, force, dryRun bool) (result pgRowEpochPreview, resultErr error) {
	ctx, cancel := context.WithTimeout(parent, pgLeaseTimeout())
	defer cancel()
	result = pgRowEpochPreview{Version: 1, Kind: "schema-epoch-preview", Database: b.history.Database, ThroughVersion: through, Forced: force, DryRun: dryRun, RecentInstances: []PgMigrationInstanceStatus{}}
	if through != b.history.CurrentVersion || b.target == nil || b.target.version != through {
		return result, fmt.Errorf("close epoch requires the current compiled additive version")
	}
	plans := map[int]*pgRowPhysicalPlan{}
	for version := 1; version <= through; version++ {
		plan, err := pgCompiledRowPhysicalPlan(b.database, version)
		if err != nil {
			return result, err
		}
		if plan == nil || len(plan.windows) != 0 || plan.requiresContractVersion != 0 || plan.settled {
			return result, fmt.Errorf("close epoch requires purely additive compiled history")
		}
		plans[version] = plan
	}
	var user, session string
	if err := conn.QueryRow(ctx, "select current_user,session_user").Scan(&user, &session); err != nil {
		return result, err
	}
	if user != roles.Worker || session != roles.Worker {
		return result, fmt.Errorf("close epoch requires exact Worker login")
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	observe := func(tx pgx.Tx) (PgMigrationControlState, error) {
		state, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false)
		if err != nil {
			return state, err
		}
		if state.Current != through || state.InstallingVersion != 0 || state.MinVersion != state.CompatFloor {
			return state, fmt.Errorf("close epoch requires a fully expanded additive admission state")
		}
		result.FromVersion = state.MinVersion
		result.MinVersion = state.MinVersion
		result.CompatFloor = state.CompatFloor
		result.RecentInstances = []PgMigrationInstanceStatus{}
		rows, err := tx.Query(ctx, "select instance,version,protocol_level,last_seen,compat_floor_seen from "+ns+"tesl_schema_instances where version>=$1 and version<$2 and last_seen>pg_catalog.clock_timestamp()-interval '30 seconds' order by version,instance", state.MinVersion, through)
		if err != nil {
			return state, err
		}
		defer rows.Close()
		for rows.Next() {
			var i PgMigrationInstanceStatus
			if err := rows.Scan(&i.Instance, &i.Version, &i.Protocol, &i.LastSeen, &i.CompatFloorSeen); err != nil {
				return state, err
			}
			result.RecentInstances = append(result.RecentInstances, i)
		}
		return state, rows.Err()
	}
	var initial PgMigrationControlState
	if err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error { var err error; initial, err = observe(tx); return err }); err != nil {
		return result, err
	}
	if initial.MinVersion == through {
		result.Kind = "schema-epoch-closed"
		return result, nil
	}
	document, digest, err := pgRowEpochDocument(b, initial, initial.MinVersion, through, force, plans)
	if err != nil {
		return result, err
	}
	result.RetirementHash = digest
	if dryRun {
		return result, nil
	}
	if len(result.RecentInstances) > 0 && !force {
		return result, fmt.Errorf("close epoch has recent retiring instances; stop them and wait or use --force")
	}
	err = pgMigrationSessionLock(ctx, conn, initial.FenceNamespace, 2147483647, true, func() error {
		return pgRowEpochDrain(ctx, conn, initial.FenceNamespace, initial.MinVersion, through, func() error {
			return pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
				state, err := observe(tx)
				if err != nil {
					return err
				}
				if state.DatabaseUUID != initial.DatabaseUUID || state.FenceNamespace != initial.FenceNamespace || state.MinVersion != initial.MinVersion {
					return fmt.Errorf("close epoch admission changed before publication")
				}
				raw, err := pgRowBaselineHex(document)
				if err != nil {
					return err
				}
				hashes := make([]string, through)
				for version := 1; version <= through; version++ {
					hashes[version-1] = plans[version].hash
				}
				migrationBoundary("row-epoch-before-publication")
				if _, err := tx.Exec(ctx, "select "+ns+"tesl_close_row_epoch($1,$2,$3,$4,$5,$6,$7,$8,$9)", initial.MinVersion, through, state.DatabaseUUID, state.FenceNamespace, hashes, raw, digest, b.history.SourceCompilerABI, force); err != nil {
					return err
				}
				migrationBoundary("row-epoch-after-publication")
				final, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false)
				if err != nil {
					return err
				}
				result.MinVersion = final.MinVersion
				result.CompatFloor = final.CompatFloor
				return nil
			})
		})
	})
	if err == nil {
		result.Kind = "schema-epoch-closed"
		migrationBoundary("row-epoch-after-commit")
	}
	return result, err
}
