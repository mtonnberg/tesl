package teslrt

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func pgRowContractFor(database *Database, version int) (*pgRowContract, error) {
	plan, err := pgCompiledRowPhysicalPlan(database, version)
	if err != nil {
		return nil, err
	}
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	c := compiledRowContracts[plan.compiled][version]
	if c == nil || c.compiled != plan.compiled || c.window != plan || c.settled.compiled != plan.compiled {
		return nil, fmt.Errorf("row Contract requires exact compiler-bound window and settled plan")
	}
	return c, nil
}

// A try-lock never queues an exclusive waiter ahead of new short requests.
// Arbitrary application transaction bodies are never replayed by contraction.
func pgRowCompatibilityDrain(ctx context.Context, conn *pgx.Conn, fence, version int, run func() error) (result error) {
	migrationBoundary("row-contract-before-compatibility-barrier")
	for {
		var acquired bool
		if err := conn.QueryRow(ctx, "select pg_catalog.pg_try_advisory_lock($1::integer,$2::integer)", -fence, version).Scan(&acquired); err != nil {
			cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = conn.Close(cleanup)
			return err
		}
		if acquired {
			break
		}
		migrationBoundary("row-contract-compatibility-busy")
		if err := pgIndexWait(ctx, 25*time.Millisecond); err != nil {
			return err
		}
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var released bool
		err := conn.QueryRow(cleanup, "select pg_catalog.pg_advisory_unlock($1::integer,$2::integer)", -fence, version).Scan(&released)
		if err != nil || !released {
			if err == nil {
				err = fmt.Errorf("compatibility lock lost")
			}
			result = errors.Join(result, err)
			_ = conn.Close(cleanup)
		}
	}()
	return run()
}
func pgRowRetiringFences(ctx context.Context, conn *pgx.Conn, fence, from, to int, run func() error) error {
	if from >= to {
		return run()
	}
	return pgMigrationSessionLock(ctx, conn, fence, from, true, func() error { return pgRowRetiringFences(ctx, conn, fence, from+1, to, run) })
}
func pgRowContractState(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, c *pgRowContract) (PgMigrationControlState, error) {
	var state PgMigrationControlState
	err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		var err error
		state, _, err = pgReadRowBaselineState(ctx, tx, b, roles, false)
		if err != nil {
			return err
		}
		return nil
	})
	return state, err
}
func pgRowHasStep(state PgMigrationControlState, version int, step string) bool {
	for _, r := range state.Versions {
		if r.Version == version && r.Step == step {
			return true
		}
	}
	return false
}

func pgExecuteRowContract(ctx context.Context, config *pgx.ConnConfig, b *pgRowBaseline, roles PgMigrationControlRoles, version int) (result PgMigrationControlState, resultErr error) {
	c, err := pgRowContractFor(b.database, version)
	if err != nil {
		return result, err
	}
	if version != b.history.CurrentVersion || c.window != b.target {
		return result, fmt.Errorf("row Contract execution requires current compiled window")
	}
	settings := config.Copy()
	settings.RuntimeParams["application_name"] = "tesl-exec:" + UUIDv7()
	conn, err := pgx.ConnectConfig(ctx, settings)
	if err != nil {
		return result, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		resultErr = errors.Join(resultErr, conn.Close(cleanup))
	}()
	var current, session string
	if err = conn.QueryRow(ctx, "select current_user,session_user").Scan(&current, &session); err != nil {
		return result, err
	}
	if current != roles.Worker || session != roles.Worker {
		return result, fmt.Errorf("row Contract requires exact Worker login")
	}
	state, err := pgRowContractState(ctx, conn, b, roles, c)
	if err != nil {
		return result, err
	}
	if state.Current != version {
		return result, fmt.Errorf("row Contract requires expanded current window")
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	err = pgMigrationSessionLock(ctx, conn, state.FenceNamespace, 2147483647, true, func() error {
		state, err = pgRowContractState(ctx, conn, b, roles, c)
		if err != nil {
			return err
		}
		if pgRowHasStep(state, version, "contracted") {
			result = state
			return nil
		}
		document, err := pgRowBaselineHex(c.contract)
		if err != nil {
			return err
		}
		settled, err := pgRowBaselineHex(c.settled.contract)
		if err != nil {
			return err
		}
		if err = pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
			var prior string
			if err := tx.QueryRow(ctx, "select coalesce((select contract_hash from "+ns+"tesl_row_contracts where version<$1 order by version desc limit 1),'')", version).Scan(&prior); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "select "+ns+"tesl_register_row_contract($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)", version, prior, document, c.hash, c.window.hash, settled, c.settled.hash, len(c.operations), c.preparationCount, b.history.SourceCompilerABI)
			return err
		}); err != nil {
			return err
		}
		migrationBoundary("row-contract-after-intent")
		if !pgRowHasStep(state, version, "retired") {
			if err = pgPrepareRowWork(ctx, conn, b, roles, c.window); err != nil {
				return err
			}
			if err = pgRowRetiringFences(ctx, conn, state.FenceNamespace, state.MinVersion, version, func() error {
				if err := pgRowFinalPass(ctx, conn, settings, b, roles, c); err != nil {
					return err
				}
				migrationBoundary("row-contract-before-retirement")
				// Fence before opening the repeatable-read snapshot: a first
				// materialization that commits while we wait must be visible.
				return pgMigrationSessionLock(ctx, conn, state.FenceNamespace, -version, true, func() error {
					migrationBoundary("row-contract-after-abi")
					return pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
						entities := make([]string, 0, len(c.finalGenerations))
						for entity := range c.finalGenerations {
							entities = append(entities, entity)
						}
						slices.Sort(entities)
						generations := make([]int16, len(entities))
						for i, e := range entities {
							generations[i] = int16(c.finalGenerations[e])
							var remaining bool
							if err := tx.QueryRow(ctx, "select exists(select 1 from "+pgx.Identifier{c.window.namespace, c.window.entity(e).table}.Sanitize()+" where _tesl_v<$1)", generations[i]).Scan(&remaining); err != nil {
								return err
							}
							if remaining {
								return fmt.Errorf("final pass still has old-generation rows")
							}
						}
						_, err := tx.Exec(ctx, "select "+ns+"tesl_retire_row_window($1,$2,$3,$4,$5,$6)", version, c.hash, pgRowRetirementHash(c), entities, generations, b.history.SourceCompilerABI)
						return err
					})
				})
			}); err != nil {
				return err
			}
			migrationBoundary("row-contract-after-retirement")
		}
		if err = pgRowContractOperations(ctx, conn, b, roles, c, 0, c.preparationCount); err != nil {
			return err
		}
		if err = pgRowCompatibilityDrain(ctx, conn, state.FenceNamespace, version, func() error {
			return pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
				if _, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false); err != nil {
					return err
				}
				_, err := tx.Exec(ctx, "select "+ns+"tesl_begin_row_contract($1,$2)", version, c.hash)
				return err
			})
		}); err != nil {
			return err
		}
		migrationBoundary("row-contract-after-floor")
		if err = pgRowContractOperations(ctx, conn, b, roles, c, c.preparationCount, len(c.operations)); err != nil {
			return err
		}
		if err = pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
			if _, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "select "+ns+"tesl_finish_row_contract($1,$2)", version, c.hash)
			return err
		}); err != nil {
			return err
		}
		result, err = pgRowContractState(ctx, conn, b, roles, c)
		return err
	})
	return result, err
}

func pgRowFinalPass(ctx context.Context, coordinator *pgx.Conn, settings *pgx.ConnConfig, b *pgRowBaseline, roles PgMigrationControlRoles, c *pgRowContract) (result error) {
	batch, err := pgx.ConnectConfig(ctx, settings)
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		result = errors.Join(result, batch.Close(cleanup))
	}()
	renewal, err := pgx.ConnectConfig(ctx, settings)
	if err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		result = errors.Join(result, renewal.Close(cleanup))
	}()
	for _, window := range c.window.windows {
		name := pgRowLeaseName(window.entity, window.targetGeneration, 0)
		holder := settings.RuntimeParams["application_name"]
		var token int64
		for token == 0 {
			token, err = pgClaimRowLease(ctx, coordinator, b, roles, name, holder)
			if err != nil {
				return err
			}
			if token == 0 {
				if err = pgIndexWait(ctx, 25*time.Millisecond); err != nil {
					return err
				}
			}
		}
		lease := pgRowLeaseAdmission{leaseName: name, leaseToken: token, holder: holder}
		passErr := pgWithRowLeaseRenewal(ctx, renewal, c.window, lease, func(ctx context.Context) error {
			// Retirement must rescan the whole keyspace after old writers have drained.
			if _, err := coordinator.Exec(ctx, "select "+pgx.Identifier{c.window.namespace, "tesl_record_row_progress"}.Sanitize()+"($1,$2,$3,null,0,false)", name, token, holder); err != nil {
				return err
			}
			for {
				if _, err := pgRowBackfillBatch(ctx, batch, b, c.window, c.window.entity(window.entity), roles, lease); err != nil {
					return err
				}
				migrationBoundary("row-finality-after-batch")
				var done bool
				if err := coordinator.QueryRow(ctx, "select state='provisional' from "+pgx.Identifier{c.window.namespace, "tesl_schema_backfill_shards"}.Sanitize()+" where lease_name=$1", name).Scan(&done); err != nil {
					return err
				}
				if done {
					return nil
				}
			}
		})
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_, releaseErr := coordinator.Exec(cleanup, "select "+pgx.Identifier{c.window.namespace, "tesl_release_row_shard"}.Sanitize()+"($1,$2,$3)", name, token, holder)
		cancel()
		if passErr != nil || releaseErr != nil {
			return errors.Join(passErr, releaseErr)
		}
	}
	return nil
}

func pgRowContractOperations(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, c *pgRowContract, from, to int) error {
	for i := from; i < to; i++ {
		op := c.operations[i]
		entity := c.window.entity(op.children[1].value)
		if entity == nil {
			return fmt.Errorf("row Contract operation references missing entity")
		}
		table := pgx.Identifier{c.window.namespace, entity.table}.Sanitize()
		for {
			lockBusy := false
			err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
				mode := "ACCESS EXCLUSIVE"
				if op.children[0].value == "validate-not-null-check" {
					mode = "SHARE UPDATE EXCLUSIVE"
				}
				// No queued exclusive lock: release this transaction and back off
				// if a long reader is active. Verify the exact proof only AFTER
				// this lock, closing catalog-to-DDL replacement races.
				if _, err := tx.Exec(ctx, "lock table "+table+" in "+mode+" mode nowait"); err != nil {
					var server *pgconn.PgError
					lockBusy = errors.As(err, &server) && server.Code == "55P03"
					return err
				}
				if _, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false); err != nil {
					return err
				}
				contracts, err := pgReadRowContracts(ctx, tx, b)
				if err != nil {
					return err
				}
				persisted := contracts[c.window.version]
				if persisted == nil || persisted.hash != c.hash {
					return fmt.Errorf("row Contract execution lost exact intent")
				}
				if persisted.completed > i {
					return nil
				}
				if persisted.completed != i {
					return fmt.Errorf("row Contract receipt prefix differs")
				}
				var sql string
				switch op.children[0].value {
				case "add-not-null-check":
					proof := pgRowNotNullProofNode(op.children[3])
					sql = "alter table " + table + " add constraint " + quoteIdentifier(proof.name) + " check (" + quoteIdentifier(proof.physical) + " is not null) not valid"
				case "validate-not-null-check":
					proof := pgRowNotNullProofNode(op.children[2])
					sql = "alter table " + table + " validate constraint " + quoteIdentifier(proof.name)
				case "drop-not-null-check":
					proof := pgRowNotNullProofNode(op.children[2])
					sql = "alter table " + table + " drop constraint " + quoteIdentifier(proof.name)
				case "relax-retired-nullability":
					sql = "alter table " + table + " alter column " + quoteIdentifier(op.children[2].children[0].value) + " drop not null"
				case "drop-column":
					sql = "alter table " + table + " drop column " + quoteIdentifier(op.children[2].children[0].value)
				case "drop-index":
					sql = "drop index " + pgx.Identifier{c.window.namespace, op.children[2].children[0].value}.Sanitize()
				case "drop-invalidation":
					spec := pgRowInvalidationFor(c.window.namespace, entity, c.window.window(entity.identity))
					sql = "drop trigger " + quoteIdentifier(spec.name) + " on " + table + "; drop function " + pgx.Identifier{c.window.namespace, spec.name}.Sanitize() + "()"
				case "set-not-null":
					sql = "alter table " + table + " alter column " + quoteIdentifier(op.children[2].children[0].value) + " set not null"
				case "set-insert-generation":
					sql = "alter table " + table + " alter column _tesl_v set default " + op.children[3].value
				default:
					return fmt.Errorf("unsupported exact Contract operation")
				}
				if _, err := tx.Exec(ctx, sql); err != nil {
					return err
				}
				migrationBoundary("row-contract-after-" + op.children[0].value)
				migrationBoundary("row-contract-after-ddl")
				if _, err := tx.Exec(ctx, "select "+pgx.Identifier{c.window.namespace, "tesl_record_row_contract_object"}.Sanitize()+"($1,$2,$3)", c.window.version, i, pgMigrationObjectHash(c.hash, i)); err != nil {
					return err
				}
				if _, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false); err != nil {
					return err
				}
				return nil
			})
			if lockBusy && ctx.Err() == nil {
				migrationBoundary("row-contract-ddl-lock-busy")
				if err := pgIndexWait(ctx, 25*time.Millisecond); err != nil {
					return err
				}
				continue
			}
			if err != nil {
				return err
			}
			break
		}
		migrationBoundary("row-contract-after-receipt")
	}
	return nil
}
