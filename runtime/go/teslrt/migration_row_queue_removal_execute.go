package teslrt

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5"
)

func pgQueueRemovalWindow(b *pgRowBaseline) (*pgRowBaseline, error) {
	if b == nil || b.target == nil || b.target.queueRemoval == nil || b.target.version < 2 {
		return nil, fmt.Errorf("RemoveEmpty requires an exact selected adjacent compiled decision")
	}
	version := b.target.version
	window, err := pgRowExecutionWindow(b, version)
	if err != nil {
		return nil, err
	}
	if len(window.queues) < version || !pgQueueRemovalMatches(window.queues[version-2].version, window.queues[version-1].version, window.target) || window.queues[version-2].version.SourceSealInventory != "complete" || window.queues[version-1].version.SourceSealInventory != "complete" {
		return nil, fmt.Errorf("RemoveEmpty requires complete sealed before/after inventories")
	}
	return window, nil
}

// Installer-only staging: binds the reviewed physical decision and both full
// inventories to this database. Future predecessor hashes come from the checked
// compiled prefix; protected execution rechecks the actually installed source.
// No target inventory, admission or floor is
// published here. The Worker cannot alter these tables or these source bytes.
func pgStageRowQueueRemoval(ctx context.Context, conn *pgx.Conn, input *pgRowBaseline, roles PgMigrationControlRoles, expected *PgMigrationControlState) error {
	b, err := pgQueueRemovalWindow(input)
	if err != nil {
		return err
	}
	version := b.target.version
	previous, err := pgCompiledRowPredecessorPlan(b.database, version)
	if err != nil {
		return err
	}
	observer, err := pgCompiledRowBaseline(b.database)
	if err != nil {
		return err
	}
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return err
	}
	defer pgQueueConversionCandidateRollback(tx)
	if err := pgControlSession(ctx, tx); err != nil {
		return err
	}
	if err := pgControlRoles(ctx, tx, roles, true); err != nil {
		return err
	}
	state, _, err := pgReadRowBaselineState(ctx, tx, observer, roles, false)
	if err != nil {
		return err
	}
	if err := pgCheckDeploymentIdentity(state, expected); err != nil {
		return err
	}
	// Completed history keeps its original executor ABI. Compatible recompiles
	// may observe it; they never replace its receipt or stage another decision.
	if state.Current >= version && state.MinVersion >= version {
		return tx.Commit(ctx)
	}
	if state.Current >= version || state.MinVersion >= version {
		return fmt.Errorf("queue removal staging requires an unexecuted edge or exact completed receipt")
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	var current int
	if err := tx.QueryRow(ctx, "select current from "+ns+"tesl_schema_state where id=1 for update").Scan(&current); err != nil {
		return err
	}
	if current != state.Current {
		return fmt.Errorf("queue removal admission changed during staging")
	}
	prior := previous.hash
	if previous.version <= max(1, state.Current) {
		var installed string
		if err := tx.QueryRow(ctx, "select contract_hash from "+ns+"tesl_row_physical where version=$1", previous.version).Scan(&installed); err != nil {
			return err
		}
		if installed != prior {
			return fmt.Errorf("queue removal predecessor physical descriptor differs")
		}
	}
	old, fresh := b.queues[version-2], b.queues[version-1]
	oldJSON, err := pgQueueRegistrationJSON(old.version.Contracts)
	if err != nil {
		return err
	}
	newJSON, err := pgQueueRegistrationJSON(fresh.version.Contracts)
	if err != nil {
		return err
	}
	prefix := make([][]string, 0, version-1)
	prefixNodes := make([]pgRowCanonical, 0, version-1)
	for older := 1; older < version; older++ {
		plan, err := pgCompiledRowPhysicalPlan(b.database, older)
		if err != nil {
			return err
		}
		member := []string{fmt.Sprint(older), plan.hash, b.queues[older-1].inventoryHash}
		prefix = append(prefix, member)
		prefixNodes = append(prefixNodes, pgRowList(pgRowAtom(member[0]), pgRowAtom(member[1]), pgRowAtom(member[2])))
	}
	_, prefixHash := pgRowBaselineDocument(pgRowList(pgRowAtom("tesl-row-queue-removal-prefix-v1"), pgRowList(prefixNodes...)))
	source, err := json.Marshal(map[string]any{
		"prefix": prefix,
		"old":    json.RawMessage(oldJSON), "new": json.RawMessage(newJSON),
		"oldSchema": old.version.SchemaSnapshotHash, "oldStorage": old.version.StorageSnapshotHash, "oldHash": old.inventoryHash,
		"newSchema": fresh.version.SchemaSnapshotHash, "newStorage": fresh.version.StorageSnapshotHash, "newHash": fresh.inventoryHash, "seal": fresh.version.SourceSealInventory,
	})
	if err != nil {
		return err
	}
	queue := b.target.queueRemoval.queue
	receipt, hash := pgRowBaselineDocument(pgRowList(pgRowAtom("tesl-row-queue-removal-v2"), pgRowAtom(state.DatabaseUUID), pgRowAtom(fmt.Sprint(state.FenceNamespace)), pgRowAtom(fmt.Sprint(version)), pgRowAtom(queue), pgRowAtom(prior), pgRowAtom(b.target.hash), pgRowAtom(old.inventoryHash), pgRowAtom(fresh.inventoryHash), pgRowAtom(prefixHash), pgRowAtom(b.history.SourceCompilerABI)))
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return err
	}
	if err := pgRecordRowQueueTarget(ctx, tx, b.history.Namespace, state, b.target, prior, b.history.SourceCompilerABI, b.history.StoredValueCompatibility); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_row_queue_removal_staging values($5,$1,$2::jsonb,$3,$4) on conflict(version) do nothing", queue, string(source), []byte(receipt), hash, version); err != nil {
		return err
	}
	var matches bool
	if err := tx.QueryRow(ctx, "select queue=$1 and source=$2::jsonb and retirement=$3 and retirement_hash=$4 from "+ns+"tesl_row_queue_removal_staging where version=$5", queue, string(source), []byte(receipt), hash, version).Scan(&matches); err != nil {
		return err
	}
	if !matches {
		return fmt.Errorf("immutable queue removal staging differs from checked source")
	}
	if state.Current >= previous.version {
		if err := tx.QueryRow(ctx, "select "+ns+"tesl_row_queue_removal_source_valid($1)", version).Scan(&matches); err != nil {
			return err
		}
		if !matches {
			return fmt.Errorf("queue removal staging differs from the installed adjacent source")
		}
	}
	migrationBoundary("queue-removal-staged-before-commit")
	return tx.Commit(ctx)
}

func pgExecuteRowQueueRemoval(ctx context.Context, conn *pgx.Conn, input *pgRowBaseline, roles PgMigrationControlRoles, expected *PgMigrationControlState) (result PgMigrationControlState, resultErr error) {
	b, err := pgQueueRemovalWindow(input)
	if err != nil {
		return result, err
	}
	// Fresh-latest deployment still establishes and retains the real original
	// V1 catalog/history; it does not fabricate an empty latest-only baseline.
	initial, err := pgExecuteRowOrigin(ctx, conn, b, roles)
	if err != nil {
		return result, err
	}
	if err := pgCheckDeploymentIdentity(initial, expected); err != nil {
		return result, err
	}
	version := b.target.version
	if initial.Current < version-1 {
		return result, fmt.Errorf("RemoveEmpty V%d requires installed V%d; run finite schema catch-up to execute the checked additive prefix", version, version-1)
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	resultErr = pgMigrationSessionLock(ctx, conn, initial.FenceNamespace, 2147483647, true, func() error {
		run := func() error {
			tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
			if err != nil {
				return err
			}
			defer pgQueueConversionCandidateRollback(tx)
			if err := pgControlSession(ctx, tx); err != nil {
				return err
			}
			ready := true
			state, _, err := pgReadRowBaselineState(ctx, tx, b, roles, true, &ready)
			if err != nil {
				return err
			}
			if state.DatabaseUUID != initial.DatabaseUUID || state.FenceNamespace != initial.FenceNamespace {
				return fmt.Errorf("queue removal installation changed while draining")
			}
			if state.Current < version {
				if err := pgRequireRowContractIndexesComplete(ctx, tx, b.history.Namespace); err != nil {
					return err
				}
			}
			migrationBoundary("queue-removal-before-publication")
			var done bool
			if err := tx.QueryRow(ctx, "select "+ns+"tesl_remove_empty_queue($1,$2,$3,$4,$5)", state.DatabaseUUID, state.FenceNamespace, b.target.hash, b.history.SourceCompilerABI, version).Scan(&done); err != nil {
				return err
			}
			if !done {
				return &pgMigrationDrainError{"RemoveEmpty blocked: retain and resolve removed-queue jobs, surviving claims/quarantines or conversion attempts, then retry; no jobs were discarded"}
			}
			result, _, err = pgReadRowBaselineState(ctx, tx, b, roles, false, &ready)
			if err != nil {
				return err
			}
			migrationBoundary("queue-removal-before-commit")
			if err := tx.Commit(ctx); err != nil {
				return err
			}
			migrationBoundary("queue-removal-after-commit")
			return nil
		}
		if initial.Current >= version {
			return run() // Read-only replay must not fence or rewrite later claims.
		}
		return pgRowEpochDrain(ctx, conn, initial.FenceNamespace, initial.MinVersion, version, run)
	})
	return result, resultErr
}
