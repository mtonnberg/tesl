package teslrt

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// PgMigrationStatus is an observation of protected history, never permission to
// serve, modify storage or retire a version. It does not run the boot executor.
type PgMigrationStatus struct {
	Version             int                          `json:"version"`
	Kind                string                       `json:"kind"`
	Database            string                       `json:"database"`
	Namespace           string                       `json:"namespace"`
	BinaryVersion       int                          `json:"binaryVersion"`
	Present             bool                         `json:"present"`
	DatabaseUUID        string                       `json:"databaseUuid,omitempty"`
	InitialVersion      int                          `json:"initialVersion"`
	CurrentVersion      int                          `json:"currentVersion"`
	MinVersion          int                          `json:"minVersion"`
	CompatFloor         int                          `json:"compatFloor"`
	InstallingVersion   int                          `json:"installingVersion"`
	SourceCompilerABI   string                       `json:"sourceCompilerAbi"`
	FormatVersion       int                          `json:"formatVersion"`
	ProtocolFloor       int                          `json:"protocolFloor"`
	MaxObservedProtocol int                          `json:"maxObservedProtocol"`
	FenceNamespace      int                          `json:"fenceNamespace"`
	HistoryError        string                       `json:"historyError,omitempty"`
	Expansions          []PgMigrationExpansionStatus `json:"expansions"`
	Instances           []PgMigrationInstanceStatus  `json:"instances"`
}

type PgMigrationExpansionStatus struct {
	Version   int      `json:"version"`
	Completed int      `json:"completedObjects"`
	Total     int      `json:"totalObjects"`
	Steps     []string `json:"steps"`
}

type PgMigrationInstanceStatus struct {
	Instance        string    `json:"instance"`
	Version         int       `json:"version"`
	Protocol        int       `json:"protocol"`
	LastSeen        time.Time `json:"lastSeen"`
	CompatFloorSeen int       `json:"compatFloorSeen"`
}

// InspectPgMigrationStatus borrows a dedicated idle connection. All catalog and
// history observations share one repeatable-read snapshot. The comparison probes
// and snapshot are rolled back; this creates no persistent objects or history.
func InspectPgMigrationStatus(ctx context.Context, conn *pgx.Conn, history PgCompiledMigrationHistory, roles PgMigrationControlRoles) (PgMigrationStatus, error) {
	result := PgMigrationStatus{Version: 1, Kind: "schema-status", Database: history.Database,
		Namespace: history.Namespace, BinaryVersion: history.CurrentVersion, SourceCompilerABI: history.SourceCompilerABI,
		Expansions: []PgMigrationExpansionStatus{}, Instances: []PgMigrationInstanceStatus{}}
	if _, err := history.ExpansionPlan(1); err != nil {
		return result, err
	}
	err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles.Owner, roles.Worker, false); err != nil {
			return err
		}
		exists, err := pgControlNamespace(ctx, tx, history.Namespace, roles.Owner, roles.Worker)
		if err != nil || !exists {
			return err
		}
		present, err := pgControlTableExists(ctx, tx, history.Namespace, "tesl_schema_meta")
		if err != nil || !present {
			return err
		}
		state, err := pgInspectControl(ctx, tx, history.Namespace, roles)
		if err != nil {
			return err
		}
		result.Present, result.DatabaseUUID = true, state.DatabaseUUID
		result.InitialVersion, result.CurrentVersion = state.InitialVersion, state.Current
		result.FormatVersion, result.ProtocolFloor, result.MaxObservedProtocol, result.FenceNamespace = state.Format, state.RetirementProtocolFloor, state.MaxObservedProtocol, state.FenceNamespace
		result.MinVersion, result.CompatFloor, result.InstallingVersion = state.MinVersion, state.CompatFloor, state.InstallingVersion
		intents, err := pgReadExpansionIntents(ctx, tx, history.Namespace)
		if err != nil {
			return err
		}
		plan, planErr := history.ExpansionPlan(state.InitialVersion)
		if planErr == nil {
			planErr = pgVerifyExpansionHistory(state, plan, intents)
		}
		if planErr != nil {
			// Status must still explain a source mismatch without attempting repair.
			result.HistoryError = planErr.Error()
		}
		for version, intent := range intents {
			progress := PgMigrationExpansionStatus{Version: version, Completed: len(intent.Objects), Total: intent.OperationCount, Steps: []string{}}
			for _, row := range state.Versions {
				if row.Version == version {
					progress.Steps = append(progress.Steps, row.Step)
				}
			}
			result.Expansions = append(result.Expansions, progress)
		}
		sort.Slice(result.Expansions, func(i, j int) bool { return result.Expansions[i].Version < result.Expansions[j].Version })
		rows, err := tx.Query(ctx, "select instance,version,protocol_level,last_seen,compat_floor_seen from "+
			pgx.Identifier{history.Namespace, "tesl_schema_instances"}.Sanitize()+" order by instance")
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var instance PgMigrationInstanceStatus
			if err := rows.Scan(&instance.Instance, &instance.Version, &instance.Protocol, &instance.LastSeen, &instance.CompatFloorSeen); err != nil {
				return err
			}
			instance.LastSeen = instance.LastSeen.UTC()
			result.Instances = append(result.Instances, instance)
		}
		return rows.Err()
	})
	if err != nil {
		return PgMigrationStatus{}, fmt.Errorf("inspect migration status: %w", err)
	}
	return result, nil
}
