package teslrt

import (
	"bytes"
	"context"
	"fmt"
	"reflect"

	"github.com/jackc/pgx/v5"
)

// Installer-only proposals can cover future retained edges. Their hashes name
// the exact predecessor they require, but do not install that predecessor or
// admit any version. Existing protected activation rechecks the installed chain.
func pgStageRowQueueHistory(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, expected *PgMigrationControlState) error {
	type edge struct {
		window  *pgRowBaseline
		digests []string
	}
	var edges []edge
	for version := 2; version <= b.history.CurrentVersion; version++ {
		window, err := pgRowExecutionWindow(b, version)
		if err != nil {
			return err
		}
		if window.target.queueRemoval != nil {
			if err := pgStageRowQueueRemoval(ctx, conn, window, roles, expected); err != nil {
				return err
			}
			continue
		}
		if len(window.target.queueConversions) == 0 {
			continue
		}
		digests, err := pgCompiledRowQueueInstallSources(window)
		if err != nil {
			return err
		}
		edges = append(edges, edge{window, digests})
	}
	for _, edge := range edges {
		for start := 0; start < len(edge.digests); start += pgRowQueueStagingBatchLimit {
			end := min(start+pgRowQueueStagingBatchLimit, len(edge.digests))
			batch, stop := context.WithTimeout(ctx, pgLeaseTimeout())
			err := pgStageRetainedQueueBatch(batch, conn, edge.window, roles, edge.digests[start:end], end == len(edge.digests), expected)
			stop()
			if err != nil {
				return fmt.Errorf("queue staging V%d: %w", edge.window.target.version, err)
			}
			migrationBoundary("queue-catchup-after-staging-batch")
		}
	}
	return nil
}

func pgStageRetainedQueueBatch(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles, digests []string, complete bool, expected *PgMigrationControlState) error {
	if len(digests) == 0 || len(digests) > pgRowQueueStagingBatchLimit || b == nil || b.target == nil {
		return fmt.Errorf("retained queue staging requires a bounded compiler-owned edge")
	}
	window, err := pgRowExecutionWindow(b, b.target.version)
	if err != nil {
		return err
	}
	b = window
	observer, err := pgCompiledRowBaseline(b.database)
	if err != nil {
		return err
	}
	plan := window.target
	previous, err := pgCompiledRowPredecessorPlan(b.database, plan.version)
	if err != nil {
		return err
	}
	if len(plan.queueConversions) == 0 || len(plan.windows) != 0 || len(plan.retirements) != 0 || !reflect.DeepEqual(previous.entities, plan.entities) {
		return fmt.Errorf("retained queue staging requires unchanged entity storage")
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
	ready := true
	state, _, err := pgReadRowBaselineState(ctx, tx, observer, roles, false, &ready)
	if err != nil {
		return err
	}
	if err := pgCheckDeploymentIdentity(state, expected); err != nil {
		return err
	}
	// Completed earlier edges are immutable observation. A latest repair cannot
	// be smuggled into a retired edge by reinstalling a longer history.
	if state.Current > plan.version || state.MinVersion >= plan.version && plan.version < b.history.CurrentVersion {
		return nil
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	var current, minimum int
	if err := tx.QueryRow(ctx, "select current,min_version from "+ns+"tesl_schema_state where id=1 for update").Scan(&current, &minimum); err != nil {
		return err
	}
	if current != state.Current || minimum != state.MinVersion {
		return fmt.Errorf("retained queue staging admission changed; retry installation")
	}
	priorHash := previous.hash
	physical, err := pgCompiledRowPhysicalPlan(b.database, previous.version)
	if err != nil {
		return err
	}
	expansion := physical.hash
	if previous.version == 1 {
		expansion = b.catalogHash
	}
	if previous.version <= max(1, current) {
		// A completed predecessor may have been produced by a compatible older
		// compiler. Bind its actual immutable descriptor, never rewrite its ABI.
		var installed string
		if err := tx.QueryRow(ctx, "select contract_hash from "+ns+"tesl_row_physical where version=$1", previous.version).Scan(&installed); err != nil {
			return err
		}
		if previous.version > 1 {
			expansion = installed
		}
		if plan.requiresContractVersion == 0 {
			priorHash = installed
		} else if pgRowHasStep(state, previous.version, "contracted") {
			if err := tx.QueryRow(ctx, "select settled_hash from "+ns+"tesl_row_contracts where version=$1", previous.version).Scan(&priorHash); err != nil {
				return err
			}
		}
	}
	for _, digest := range digests {
		lineage, err := pgQueueConversionCandidateLineage(digest)
		if err != nil {
			return err
		}
		root := lineage[len(lineage)-1]
		matched := false
		for _, conversion := range plan.queueConversions {
			if conversion.digest == root.spec.digest && conversion.queue == root.queue && conversion.job == root.job && bytes.Equal(mustQueueContractBytes(conversion.oldContract), pgQueueConversionPayloadContract(root, false)) && bytes.Equal(mustQueueContractBytes(conversion.newContract), pgQueueConversionPayloadContract(root, true)) {
				matched = true
			}
		}
		if !matched || root.family != b.history.Family || root.fromVersion != previous.version || root.toVersion != plan.version || !root.conversion.list(17) || root.conversion.children[1].value != b.history.SourceCompilerABI || root.conversion.children[2].value != b.history.StoredValueCompatibility || root.conversion.children[13].value != previous.schemaSnapshotHash || root.conversion.children[14].value != plan.schemaSnapshotHash || root.conversion.children[15].value != previous.storageSnapshotHash || root.conversion.children[16].value != plan.storageSnapshotHash {
			return fmt.Errorf("retained queue source differs from exact compiled physical edge")
		}
		if minimum >= plan.version {
			var matches bool
			if err := tx.QueryRow(ctx, "select exists(select 1 from "+ns+"tesl_row_queue_conversion_staging where source_digest=$1 and source_document=$2 and database_uuid::text=$3 and fence_ns=$4)", digest, mustQueueConversionDocument(lineage[0]), state.DatabaseUUID, state.FenceNamespace).Scan(&matches); err != nil {
				return err
			}
			if !matches {
				return fmt.Errorf("retired queue installation cannot append a new repair revision")
			}
			continue
		}
		if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
			return err
		}
		if err := pgRecordRowQueueLineage(ctx, tx, b.history.Namespace, state, lineage, b.queues[previous.version-1].inventoryHash, expansion, pgQueueConversionPayloadContract(root, false)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "reset role"); err != nil {
			return err
		}
	}
	if complete && current < plan.version {
		if current == previous.version && minimum == current && state.CompatFloor == current {
			// The adjacent case retains the original installed-source admission
			// and exact catalog recheck. Future edges remain inactive proposals.
			if err := tx.Commit(ctx); err != nil {
				return err
			}
			return pgStageRowQueueTarget(ctx, conn, b.history.Namespace, roles, plan.contract, plan.hash)
		}
		var roots int
		if err := tx.QueryRow(ctx, "select count(*) from "+ns+"tesl_row_queue_conversion_staging where from_version=$1 and revision=0", previous.version).Scan(&roots); err != nil {
			return err
		}
		if roots != len(plan.queueConversions) {
			return fmt.Errorf("retained queue target does not cover its complete staged sources")
		}
		if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
			return err
		}
		if err := pgRecordRowQueueTarget(ctx, tx, b.history.Namespace, state, plan, priorHash, b.history.SourceCompilerABI, b.history.StoredValueCompatibility); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// The finite deployment command uses the same protected operations as the
// worker/Contract commands. It lends one boot-locked session to each step; no
// intermediate application registration or request identity is manufactured.
func pgExecuteRowCatchup(ctx context.Context, conn *pgx.Conn, config *pgx.ConnConfig, b *pgRowBaseline, roles PgMigrationControlRoles) (result PgMigrationControlState, resultErr error) {
	return pgExecuteRowCatchupFor(ctx, conn, config, b, roles, nil)
}

func pgExecuteRowCatchupFor(ctx context.Context, conn *pgx.Conn, config *pgx.ConnConfig, b *pgRowBaseline, roles PgMigrationControlRoles, expected *PgMigrationControlState) (result PgMigrationControlState, resultErr error) {
	if b == nil || b.target == nil || b.target.version != b.history.CurrentVersion {
		return result, fmt.Errorf("schema catch-up requires the complete current compiled row history")
	}
	windows := make(map[int]*pgRowBaseline)
	for version := 1; version <= b.history.CurrentVersion; version++ {
		window, err := pgRowExecutionWindow(b, version)
		if err != nil {
			return result, err
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
			if err == nil {
				err = pgCheckDeploymentIdentity(state, expected)
			}
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
				if pgRowQueueEdge(plan) {
					retireThrough = max(retireThrough, version)
				}
				if version < b.history.CurrentVersion {
					if !pgRowQueueEdge(plan) {
						if _, err := pgRowContractFor(b.database, version); err != nil {
							return fmt.Errorf("schema catch-up requires reviewed Contract V%d: %w", version, err)
						}
					}
					retireThrough = max(retireThrough, version)
				}
			}
			if pgRowQueueEdge(plan) && (version > state.Current || state.MinVersion < version) {
				if err := pgCheckQueueCatchupStaging(ctx, conn, window, state); err != nil {
					return err
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
			queueEdge := pgRowQueueEdge(window.target)
			if !queueEdge || state.MinVersion < state.Current {
				if err := pgCompleteCatchupIndexes(ctx, config, window, roles, state); err != nil {
					return err
				}
			} else if err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
				return pgRequireRowContractIndexesComplete(ctx, tx, b.history.Namespace)
			}); err != nil {
				return err
			}
			if queueEdge {
				if state.MinVersion < state.Current {
					if window.target.queueRemoval != nil {
						return fmt.Errorf("RemoveEmpty V%d lacks its atomic retirement receipt", state.Current)
					}
					if err := pgCatchupQueueConversion(ctx, conn, window, roles); err != nil {
						return err
					}
					state, err = pgExecuteRowQueueContractOn(ctx, conn, window, roles, state.Current)
					if err != nil {
						return fmt.Errorf("queue catch-up V%d: %w; inspect --schema status, deploy the checked QueueRepair/discard policy or drain claimants, then rerun installation and catch-up", window.target.version, err)
					}
					migrationBoundary("queue-catchup-after-retirement")
				}
			}
			if state.Current == b.history.CurrentVersion {
				result = state
				return nil
			}
			if !pgRowEpochPreserving(window.target) && !queueEdge {
				state, err = pgExecuteRowContractOn(ctx, conn, config, window, roles, state.Current, true)
				if err != nil {
					return fmt.Errorf("schema catch-up Contract V%d: %w", window.target.version, err)
				}
			}
			next := windows[state.Current+1]
			if !pgRowEpochPreserving(next.target) && next.target.queueRemoval == nil && state.MinVersion < state.Current {
				if _, err := pgExecuteRowEpoch(ctx, conn, window, roles, state.Current, false, false); err != nil {
					return err
				}
			}
			step, stop := context.WithTimeout(ctx, pgLeaseTimeout())
			if next.target.queueRemoval != nil {
				state, err = pgExecuteRowQueueRemoval(step, conn, next, roles, expected)
			} else if len(next.target.queueConversions) > 0 {
				err = pgPublishRowQueueTarget(step, conn, b.history.Namespace, roles, b.queues[next.target.version-1].version, next.target.contract, next.target.hash)
				if err == nil {
					state, err = observe()
				}
			} else {
				state, err = pgExecuteRowForward(step, conn, next, roles)
			}
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

func pgCompleteCatchupIndexes(ctx context.Context, config *pgx.ConnConfig, b *pgRowBaseline, roles PgMigrationControlRoles, state PgMigrationControlState) error {
	// Complete all durable jobs, not just request-readiness indexes, before
	// retiring either kind of window. Each actor retains its normal job fences.
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
	return pgRunIndexWorkerSource(ctx, ddl, config, pgIndexWorkerSource{PgCompiledMigrationHistory: b.history, row: b, untilValid: true}, roles, state, nil, settings)
}

func pgCheckQueueCatchupStaging(parent context.Context, conn *pgx.Conn, b *pgRowBaseline, state PgMigrationControlState) error {
	ctx, cancel := context.WithTimeout(parent, pgLeaseTimeout())
	defer cancel()
	var staged bool
	if err := conn.QueryRow(ctx, "select exists(select 1 from "+quoteIdentifier(b.history.Namespace)+".tesl_row_queue_target_staging where version=$1 and contract_hash=$2 and contract=$3 and database_uuid::text=$4 and fence_ns=$5 and compiler_abi=$6)", b.target.version, b.target.hash, mustQueueContractBytes(b.target.contract), state.DatabaseUUID, state.FenceNamespace, b.history.SourceCompilerABI).Scan(&staged); err != nil {
		return err
	}
	if !staged {
		return fmt.Errorf("queue catch-up V%d lacks exact staged authority; run this binary's --schema install with Installer credentials before --schema catch-up with Worker credentials", b.target.version)
	}
	digests, err := pgCompiledRowQueueInstallSources(b)
	if err != nil {
		return err
	}
	for _, digest := range digests {
		var present bool
		if err := conn.QueryRow(ctx, "select exists(select 1 from "+quoteIdentifier(b.history.Namespace)+".tesl_row_queue_conversion_staging where source_digest=$1 and database_uuid::text=$2 and fence_ns=$3)", digest, state.DatabaseUUID, state.FenceNamespace).Scan(&present); err != nil {
			return err
		}
		if !present {
			return fmt.Errorf("queue catch-up V%d lacks its compiled repair lineage; rerun --schema install with Installer credentials", b.target.version)
		}
	}
	rows, err := conn.Query(ctx, "select source_digest from "+quoteIdentifier(b.history.Namespace)+".tesl_row_queue_conversion_staging where to_version=$1", b.target.version)
	if err != nil {
		return err
	}
	stagedDigests, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	compiledQueueConversionExecutables.RLock()
	defer compiledQueueConversionExecutables.RUnlock()
	for _, digest := range stagedDigests {
		if compiledQueueConversionExecutables.byDigest[digest] == nil {
			return fmt.Errorf("queue catch-up V%d has a staged repair not linked in this binary; include the retained QueueRepair declarations before deploying", b.target.version)
		}
	}
	return nil
}

func pgCatchupQueueConversion(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles) error {
	for {
		batch, err := pgRunRowQueueConversionTurn(ctx, conn, b.history.Namespace, roles, 256)
		if err != nil {
			return fmt.Errorf("queue catch-up V%d: %w", b.target.version, err)
		}
		migrationBoundary("queue-catchup-after-turn")
		if !batch.NoEligible {
			continue
		}
		// Lack of selectable work is not finality: quarantine, active claims and
		// unchanged old payloads remain possible. The protected queue Contract
		// independently proves completion and performs audited restamping.
		return nil
	}
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
		return &pgMigrationDrainError{fmt.Sprintf("schema catch-up must retire V%d through V%d; stop those application/worker instances, wait 30 seconds after their last heartbeat, then rerun --schema catch-up", from, through-1)}
	}
	return nil
}
