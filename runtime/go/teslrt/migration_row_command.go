package teslrt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/jackc/pgx/v5"
)

// Existing schema verbs dispatch from the actual selected compiled Database;
// there are no row-protocol flags, supplied metadata paths, or upgrade fallback.
func pgRunRowSchemaCommand(serviceContext context.Context, command pgSchemaCommand, out io.Writer, database *Database) (resultErr error) {
	if err := PreflightApplicationDatabases(database); err != nil {
		return err
	}
	b, err := pgCompiledRowBaseline(database)
	if err != nil {
		return err
	}
	config, err := pgx.ParseConfig(postgresDSN(database.Config))
	if err != nil {
		return fmt.Errorf("invalid PostgreSQL schema connection configuration")
	}
	roles, err := pgMigrationRoles(database.Config, config.User)
	if err != nil {
		return err
	}
	if command.verb == "install" {
		if roles.Request != "" {
			if command.worker != roles.Worker || command.request != roles.Request {
				return fmt.Errorf("worker installation roles must match compiled database configuration")
			}
		} else {
			if command.request != "" {
				return fmt.Errorf("--request requires Worker topology")
			}
			roles.Worker = command.worker
		}
	}
	if (command.verb == "worker" || command.verb == "catch-up" || command.verb == "contract" || command.verb == "close-epoch") && roles.Request == "" {
		return fmt.Errorf("schema worker requires Worker migration topology")
	}
	if command.verb == "install" || command.verb == "worker" || command.verb == "catch-up" || command.verb == "contract" || command.verb == "close-epoch" {
		config, err = pgMigrationDDLConfig(database.Config)
		if err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(serviceContext, pgLeaseTimeout())
	defer cancel()
	if command.verb == "catch-up" {
		config.RuntimeParams["application_name"] = "tesl-exec:" + UUIDv7()
	}
	conn, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		return fmt.Errorf("%v", pgFailure("cannot connect row schema command", err))
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
		defer cancel()
		resultErr = errors.Join(resultErr, conn.Close(cleanup))
	}()
	switch command.verb {
	case "catch-up":
		cancel()
		state, err := pgExecuteRowCatchup(serviceContext, conn, config, b, roles)
		if err != nil {
			return err
		}
		if command.json {
			return json.NewEncoder(out).Encode(struct {
				Version        int    `json:"version"`
				Kind           string `json:"kind"`
				Database       string `json:"database"`
				BinaryVersion  int    `json:"binaryVersion"`
				CurrentVersion int    `json:"currentVersion"`
				MinVersion     int    `json:"minVersion"`
			}{1, "schema-caught-up", b.history.Database, b.history.CurrentVersion, state.Current, state.MinVersion})
		}
		_, err = fmt.Fprintf(out, "%s: schema caught up to V%d; minimum V%d.\n", b.history.Database, state.Current, state.MinVersion)
		return err
	case "install":
		if b.target != nil && len(b.target.queueConversions) > 0 {
			if err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
				if err := pgControlRoles(ctx, tx, roles, true); err != nil {
					return err
				}
				state, err := pgInspectRowControl(ctx, tx, b.history.Namespace, roles)
				if err != nil {
					return err
				}
				if (state.Current != b.target.version-1 && state.Current != b.target.version) || (state.Current == b.target.version-1 && (state.MinVersion != state.Current || state.CompatFloor != state.Current)) {
					return fmt.Errorf("queue upgrade installation requires its fully retired adjacent predecessor")
				}
				return nil
			}); err != nil {
				return err
			}
		}
		state, err := InstallPgCompiledRowBaseline(ctx, conn, database, roles)
		if err != nil {
			return err
		}
		if b.target != nil && len(b.target.queueConversions) > 0 {
			digests, err := pgCompiledRowQueueInstallSources(b)
			if err != nil {
				return err
			}
			if state.Current == b.target.version-1 || state.MinVersion < b.target.version {
				for start := 0; start < len(digests); start += pgRowQueueStagingBatchLimit {
					end := min(start+pgRowQueueStagingBatchLimit, len(digests))
					if err := pgStageRowQueueConversionBatch(ctx, conn, b.history.Namespace, roles, digests[start:end]); err != nil {
						return err
					}
				}
			} else if err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
				for _, digest := range digests {
					compiledQueueConversionSources.RLock()
					source := compiledQueueConversionSources.byDigest[digest]
					compiledQueueConversionSources.RUnlock()
					var matches bool
					if err := tx.QueryRow(ctx, "select exists(select 1 from "+quoteIdentifier(b.history.Namespace)+".tesl_row_queue_conversion_staging where source_digest=$1 and source_document=$2 and database_uuid::text=$3 and fence_ns=$4)", digest, mustQueueConversionDocument(source), state.DatabaseUUID, state.FenceNamespace).Scan(&matches); err != nil {
						return err
					}
					if !matches {
						return fmt.Errorf("retired queue installation cannot append a new repair revision")
					}
				}
				return nil
			}); err != nil {
				return err
			}
			if state.Current == b.target.version-1 {
				if err := pgStageRowQueueTarget(ctx, conn, b.history.Namespace, roles, b.target.contract, b.target.hash); err != nil {
					return err
				}
			}
		}
		return pgWriteSchemaInstallation(out, command.json, b.history, state, roles)
	case "worker":
		if b.target != nil && len(b.target.queueConversions) > 0 {
			if b.target.version < 2 || len(b.queues) != b.target.version {
				return fmt.Errorf("queue worker requires a complete consecutive queue-only history")
			}
			var state PgMigrationControlState
			if err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
				if err := pgControlRoles(ctx, tx, roles, false); err != nil {
					return err
				}
				var worker bool
				if err := tx.QueryRow(ctx, "select current_user=$1 and session_user=$1", roles.Worker).Scan(&worker); err != nil {
					return err
				}
				if !worker {
					return fmt.Errorf("queue worker requires exact Worker login")
				}
				var err error
				state, _, err = pgReadRowBaselineState(ctx, tx, b, roles, true)
				return err
			}); err != nil {
				return err
			}
			if state.Current != b.target.version {
				if err := pgPublishRowQueueTarget(ctx, conn, b.history.Namespace, roles, b.queues[b.target.version-1].version, b.target.contract, b.target.hash); err != nil {
					return err
				}
			}
			cancel()
			if command.json {
				if err := json.NewEncoder(out).Encode(struct {
					Kind           string `json:"kind"`
					CurrentVersion int    `json:"currentVersion"`
				}{"schema-worker-ready", b.target.version}); err != nil {
					return err
				}
			} else if _, err := fmt.Fprintf(out, "schema queue worker ready at V%d\n", b.target.version); err != nil {
				return err
			}
			for serviceContext.Err() == nil {
				if _, err := pgRunRowQueueConversionTurn(serviceContext, conn, b.history.Namespace, roles, 256); err != nil {
					if serviceContext.Err() != nil {
						return nil
					}
					return err
				}
				if err := pgIndexWait(serviceContext, 250*time.Millisecond); err != nil {
					return nil
				}
			}
			return nil
		}
		// Connection setup has a bounded startup budget; a history walk uses
		// the service lifetime with a fresh bounded budget for each checked edge.
		cancel()
		state, err := pgExecuteRowBaseline(serviceContext, conn, b, roles)
		if err != nil {
			return err
		}
		return pgRunRowIndexServices(serviceContext, conn, config, b, roles, state, func(state PgMigrationControlState) error {
			if command.json {
				err = json.NewEncoder(out).Encode(struct {
					Version        int    `json:"version"`
					Kind           string `json:"kind"`
					Database       string `json:"database"`
					BinaryVersion  int    `json:"binaryVersion"`
					CurrentVersion int    `json:"currentVersion"`
					DatabaseUUID   string `json:"databaseUuid"`
				}{1, "schema-worker-ready", b.history.Database, b.history.CurrentVersion, state.Current, state.DatabaseUUID})
			} else {
				_, err = fmt.Fprintf(out, "%s: schema worker ready at V%d (binary V%d).\n", b.history.Database, state.Current, b.history.CurrentVersion)
			}
			if err != nil {
				return err
			}
			return nil
		})
	case "close-epoch":
		preview, err := pgExecuteRowEpoch(ctx, conn, b, roles, command.targetVersion, command.force, command.dryRun)
		if err != nil {
			return err
		}
		if command.json {
			return json.NewEncoder(out).Encode(preview)
		}
		_, err = fmt.Fprintf(out, "%s: %s through V%d; minimum V%d; %d recent retiring instances.\n", b.history.Database, preview.Kind, preview.ThroughVersion, preview.MinVersion, len(preview.RecentInstances))
		return err
	case "contract":
		var state PgMigrationControlState
		if b.target != nil && len(b.target.queueConversions) > 0 {
			state, err = pgExecuteRowQueueContract(ctx, conn, b, roles, command.targetVersion)
		} else {
			cancel()
			state, err = pgExecuteRowContract(serviceContext, config, b, roles, command.targetVersion)
		}
		if err != nil {
			return err
		}
		if command.json {
			return json.NewEncoder(out).Encode(struct {
				Version       int    `json:"version"`
				Kind          string `json:"kind"`
				Database      string `json:"database"`
				TargetVersion int    `json:"targetVersion"`
				MinVersion    int    `json:"minVersion"`
				CompatFloor   int    `json:"compatFloor"`
			}{1, "schema-contracted", b.history.Database, command.targetVersion, state.MinVersion, state.CompatFloor})
		}
		_, err = fmt.Fprintf(out, "%s: V%d contracted; minimum V%d.\n", b.history.Database, command.targetVersion, state.MinVersion)
		return err
	case "status":
		status, err := pgRowSchemaStatus(ctx, conn, b, roles)
		if err != nil {
			return err
		}
		if command.json {
			return json.NewEncoder(out).Encode(status)
		}
		if !status.Present {
			_, err = fmt.Fprintf(out, "%s: row generation baseline is not installed.\n", b.history.Database)
		} else {
			_, err = fmt.Fprintf(out, "%s: format 5; database V%d; %d/%d marker-bearing entities.\n", b.history.Database, status.CurrentVersion, pgRowStatusCompleted(status), len(b.entities))
			if err == nil && len(status.Queues) > 0 {
				var queues struct {
					Blockers []struct {
						Code   string `json:"code"`
						Count  int64  `json:"count"`
						Action string `json:"action"`
					} `json:"blockers"`
				}
				if decodeErr := json.Unmarshal(status.Queues, &queues); decodeErr != nil {
					return decodeErr
				}
				for _, blocker := range queues.Blockers {
					if _, err = fmt.Fprintf(out, "%s: %d; %s.\n", blocker.Code, blocker.Count, blocker.Action); err != nil {
						break
					}
				}
			}
		}
		return err
	}
	return fmt.Errorf("unsupported row schema command")
}

func pgRowSchemaStatus(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles) (PgMigrationStatus, error) {
	status := PgMigrationStatus{Version: 1, Kind: "schema-status", Database: b.history.Database, Namespace: b.history.Namespace, BinaryVersion: b.history.CurrentVersion, SourceCompilerABI: b.history.SourceCompilerABI, StoredValueCompatibility: b.history.StoredValueCompatibility, Expansions: []PgMigrationExpansionStatus{}, Instances: []PgMigrationInstanceStatus{}, Indexes: []PgMigrationIndexStatus{}}
	err := pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles, false); err != nil {
			return err
		}
		exists, err := pgControlNamespace(ctx, tx, b.history.Namespace, roles.Owner, roles.Worker)
		if err != nil || !exists {
			return err
		}
		present, err := pgControlTableExists(ctx, tx, b.history.Namespace, "tesl_schema_meta")
		if err != nil || !present {
			return err
		}
		state, _, err := pgReadRowBaselineState(ctx, tx, b, roles, false)
		if err != nil {
			return err
		}
		status.Present, status.DatabaseUUID = true, state.DatabaseUUID
		status.InitialVersion, status.CurrentVersion = state.InitialVersion, state.Current
		status.MinVersion, status.CompatFloor, status.InstallingVersion = state.MinVersion, state.CompatFloor, state.InstallingVersion
		status.FormatVersion, status.ProtocolFloor, status.MaxObservedProtocol, status.FenceNamespace = state.Format, state.RetirementProtocolFloor, state.MaxObservedProtocol, state.FenceNamespace
		if err := tx.QueryRow(ctx, "select "+quoteIdentifier(b.history.Namespace)+".tesl_row_queue_status()").Scan(&status.Queues); err != nil {
			return err
		}
		instances, err := tx.Query(ctx, "select instance,version,protocol_level,last_seen,compat_floor_seen from "+quoteIdentifier(b.history.Namespace)+".tesl_schema_instances where last_seen>pg_catalog.clock_timestamp()-interval '30 seconds' order by version,instance limit 100")
		if err != nil {
			return err
		}
		status.Instances, err = pgx.CollectRows(instances, func(row pgx.CollectableRow) (PgMigrationInstanceStatus, error) {
			var item PgMigrationInstanceStatus
			err := row.Scan(&item.Instance, &item.Version, &item.Protocol, &item.LastSeen, &item.CompatFloorSeen)
			item.LastSeen = item.LastSeen.UTC()
			return item, err
		})
		if err != nil {
			return err
		}
		intents, err := pgReadExpansionIntents(ctx, tx, b.history.Namespace)
		if err != nil {
			return err
		}
		// pgReadRowBaselineState already verified the row-specific index and
		// lease inventory. The legacy verifier interprets row-shard leases as
		// orphan index leases; only project the verified rows here.
		jobs, err := pgReadMigrationIndexJobRows(ctx, tx, b.history.Namespace, intents)
		if err != nil {
			return err
		}
		for _, job := range jobs {
			status.Indexes = append(status.Indexes, PgMigrationIndexStatus{ID: job.ID, Name: job.Index.Name,
				Table: job.Table, Version: job.Version, State: job.State, SourceCompilerABI: job.SourceABI,
				Attempts: job.Attempts, Holder: job.Holder, Token: job.Token, ExpiresAt: job.ExpiresAt, Error: job.Error})
		}
		for version := 1; version <= b.history.CurrentVersion; version++ {
			intent := intents[version]
			if intent == nil {
				continue
			}
			steps := []string{}
			for _, step := range state.Versions {
				if step.Version == version {
					steps = append(steps, step.Step)
				}
			}
			status.Expansions = append(status.Expansions, PgMigrationExpansionStatus{Version: version, SourceCompilerABI: intent.SourceABI, StoredValueCompatibility: intent.StoredValueCompatibility, Completed: len(intent.Objects), Total: intent.OperationCount, Steps: steps})
		}
		return nil
	})
	return status, err
}

func pgRowStatusCompleted(status PgMigrationStatus) int {
	if len(status.Expansions) == 0 {
		return 0
	}
	return status.Expansions[0].Completed
}
