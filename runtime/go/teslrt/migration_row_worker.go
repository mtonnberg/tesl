package teslrt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

var errRowWindowFinal = errors.New("row window is final")

func pgRowLeaseName(entity string, generation, shard int) string {
	return fmt.Sprintf("row:%s:%d:%d", entity, generation, shard)
}

// Takeover never signals an unverified arbitrary pid. The expired lease row is
// locked while all same-role backends carrying its exact runtime holder tag are
// terminated and observed gone; renewal/takeover waits for this transaction.
func pgClaimRowLease(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, name, holder string) (int64, error) {
	var token int64
	var err error
	for {
		err = pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
			if _, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false); err != nil {
				return err
			}
			migrationBoundary("row-worker-before-takeover")
			var raw []byte
			if err := tx.QueryRow(ctx, "select "+pgx.Identifier{b.history.Namespace, "tesl_row_takeover_lease"}.Sanitize()+"($1)", name).Scan(&raw); err != nil {
				return err
			}
			var observed struct {
				Holder  *string `json:"holder"`
				Busy    bool    `json:"busy"`
				Expired bool    `json:"expired"`
			}
			if err := json.Unmarshal(raw, &observed); err != nil {
				return err
			}
			previous, expired := observed.Holder, observed.Expired
			if observed.Busy || previous != nil && !expired {
				return nil
			}
			if previous != nil && expired {
				if *previous == holder {
					return fmt.Errorf("expired worker cannot silently reacquire its old holder identity")
				}
				for {
					var remaining int
					if err := tx.QueryRow(ctx, "select count(*) from pg_catalog.pg_stat_activity where datname=pg_catalog.current_database() and usename=$1 and application_name=$2 and pid<>pg_catalog.pg_backend_pid()", roles.Worker, *previous).Scan(&remaining); err != nil {
						return err
					}
					if remaining == 0 {
						break
					}
					if _, err := tx.Exec(ctx, "select pg_catalog.pg_terminate_backend(pid) from pg_catalog.pg_stat_activity where datname=pg_catalog.current_database() and usename=$1 and application_name=$2 and pid<>pg_catalog.pg_backend_pid()", roles.Worker, *previous); err != nil {
						return err
					}
					if err := pgIndexWait(ctx, 10*time.Millisecond); err != nil {
						return err
					}
				}
			}
			return tx.QueryRow(ctx, "select "+pgx.Identifier{b.history.Namespace, "tesl_claim_row_shard"}.Sanitize()+"($1,$2,60000)", name, holder).Scan(&token)
		})
		var server *pgconn.PgError
		if !errors.As(err, &server) || server.Code != "40001" || ctx.Err() != nil || conn.IsClosed() {
			break
		}
		// A renewal may commit after the verified snapshot but before takeover
		// locks its row. Retry only this rolled-back claim, never row callbacks.
		if err = pgIndexWait(ctx, 10*time.Millisecond); err != nil {
			break
		}
	}

	if err != nil && ctx.Err() == nil && !conn.IsClosed() {
		// Retirement may win after prepare but before this claim. Only a fresh,
		// fully verified retirement receipt can turn that race into a quiet stop.
		final := false
		checkErr := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
			state, _, readErr := pgReadRowBaselineState(ctx, tx, b, roles, false)
			if readErr != nil {
				return readErr
			}
			final = pgRowHasStep(state, b.target.version, "retired")
			return nil
		})
		if checkErr == nil && final {
			return 0, errRowWindowFinal
		}
	}
	return token, err
}

// One process can own a bounded full-key-range shard. The persisted shard format
// also represents disjoint ranges; histogram-based splitting and parallel shard
// scheduling are a separate extension to this first complete lifecycle runner.
func pgPrepareRowWork(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, plan *pgRowPhysicalPlan) error {
	ctx, cancel := context.WithTimeout(ctx, pgLeaseTimeout())
	defer cancel()
	for {
		err := pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
			state, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false)
			if err != nil {
				return err
			}
			for _, row := range state.Versions {
				if row.Version == plan.version && row.Step == "retired" {
					return errRowWindowFinal
				}
			}
			if len(plan.windows) == 0 && state.Current >= plan.version {
				return errRowWindowFinal
			}
			if state.Current < plan.version {
				return fmt.Errorf("backfill precedes physical expansion")
			}
			migrationBoundary("row-worker-before-prepare-shards")
			for _, window := range plan.windows {
				if _, err := tx.Exec(ctx, "select "+pgx.Identifier{plan.namespace, "tesl_register_row_shard"}.Sanitize()+"($1,$2,$3,$4,null,null,$5)", plan.version, window.entity, int16(window.targetGeneration), int16(0), pgRowLeaseName(window.entity, window.targetGeneration, 0)); err != nil {
					return err
				}
			}
			return nil
		})

		var server *pgconn.PgError
		if !errors.As(err, &server) || server.Code != "40001" || ctx.Err() != nil || conn.IsClosed() {
			return err
		}
		// An existing shard can receive committed progress after this complete
		// snapshot and before INSERT ON CONFLICT. Only the rolled-back internal
		// registration is retried; no row conversion or application body ran.
		if err := pgIndexWait(ctx, 10*time.Millisecond); err != nil {
			return err
		}
	}
}
func pgWithRowLeaseRenewal(service context.Context, coordinator *pgx.Conn, plan *pgRowPhysicalPlan, lease pgRowLeaseAdmission, run func(context.Context) error) (resultErr error) {
	ctx, cancel := context.WithCancel(service)
	defer cancel()
	done := make(chan error, 1)
	stopRenewal := make(chan struct{})
	go func() {
		timer := time.NewTicker(5 * time.Second)
		defer timer.Stop()
		for {
			select {
			case <-stopRenewal:
				done <- nil
				return
			case <-ctx.Done():
				done <- nil
				return
			case <-timer.C:
				select {
				case <-stopRenewal:
					done <- nil
					return
				default:
				}
				query, stop := context.WithTimeout(ctx, 35*time.Second)
				_, err := coordinator.Exec(query, "select "+pgx.Identifier{plan.namespace, "tesl_renew_row_shard"}.Sanitize()+"($1,$2,$3,60000)", lease.leaseName, lease.leaseToken, lease.holder)
				stop()
				if err != nil {
					if ctx.Err() != nil {
						done <- nil
						return
					}
					cancel()
					done <- err
					return
				}
			}
		}
	}()
	defer func() {
		// Normal batch completion stops new renewals but drains an in-flight
		// bounded query. Canceling that query could close the reusable Worker
		// coordinator connection before its lease release/next claim.
		close(stopRenewal)
		resultErr = errors.Join(resultErr, <-done)
		cancel()
	}()
	return run(ctx)
}

// Ordinary workers release after one bounded batch; finality keeps the same
// renewal scope across the complete rescan, including fast consecutive batches.
func pgRunRowBackfillLease(service context.Context, coordinator, batch *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, plan *pgRowPhysicalPlan, entity *pgRowPhysicalEntity, lease pgRowLeaseAdmission) error {
	return pgWithRowLeaseRenewal(service, coordinator, plan, lease, func(ctx context.Context) error {
		_, err := pgRowBackfillBatch(ctx, batch, b, plan, entity, roles, lease)
		return err
	})
}

func pgRunRowWorker(service context.Context, config *pgx.ConnConfig, b *pgRowBaseline, roles PgMigrationControlRoles) (resultErr error) {
	defer func() {
		if service.Err() != nil {
			resultErr = nil
		}
	}()
	if config == nil || b == nil {
		return fmt.Errorf("row worker lacks compiled physical configuration")
	}
	if b.history.CurrentVersion == 1 {
		<-service.Done()
		return nil
	}
	if b.target == nil {
		return fmt.Errorf("row worker lacks compiled physical target")
	}
	for service.Err() == nil {
		tag := "tesl-exec:" + UUIDv7()
		settings := config.Copy()
		settings.RuntimeParams["application_name"] = tag
		query, stop := context.WithTimeout(service, 10*time.Second)
		coordinator, err := pgx.ConnectConfig(query, settings)
		stop()
		if err != nil {
			return err
		}
		query, stop = context.WithTimeout(service, 10*time.Second)
		batch, err := pgx.ConnectConfig(query, settings)
		stop()
		if err != nil {
			_ = coordinator.Close(context.Background())
			return err
		}
		runErr := func() error {
			defer func() {
				cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				_ = batch.Close(cleanup)
				_ = coordinator.Close(cleanup)
			}()
			for service.Err() == nil {
				query, stop := context.WithTimeout(service, 10*time.Second)
				err := pgPrepareRowWork(query, coordinator, b, roles, b.target)
				stop()
				if err != nil {
					return err
				}
				migrationBoundary("row-worker-after-prepare")
				for _, window := range b.target.windows {
					entity := b.target.entity(window.entity)
					name := pgRowLeaseName(window.entity, window.targetGeneration, 0)
					query, stop := context.WithTimeout(service, 10*time.Second)
					token, err := pgClaimRowLease(query, coordinator, b, roles, name, tag)
					stop()
					if err != nil {
						return err
					}
					if token == 0 {
						continue
					}
					lease := pgRowLeaseAdmission{leaseName: name, leaseToken: token, holder: tag}
					err = pgRunRowBackfillLease(service, coordinator, batch, b, roles, b.target, entity, lease)
					cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					_, releaseErr := coordinator.Exec(cleanup, "select "+pgx.Identifier{b.history.Namespace, "tesl_release_row_shard"}.Sanitize()+"($1,$2,$3)", name, token, tag)
					cancel()
					if err != nil || releaseErr != nil {
						return errors.Join(err, releaseErr)
					}
				}
				if err := pgIndexWait(service, 50*time.Millisecond); err != nil {
					return err
				}
			}
			return nil
		}()
		if service.Err() != nil {
			return nil
		}
		if errors.Is(runErr, errRowWindowFinal) {
			<-service.Done()
			return nil
		}
		if runErr != nil {
			return runErr
		}
	}
	return nil
}
