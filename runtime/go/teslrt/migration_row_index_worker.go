package teslrt

import (
	"context"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
	"slices"
	"strings"
	"time"
)

func pgReadRowIndexExecutionState(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, roles PgMigrationControlRoles) (PgMigrationControlState, int, error) {
	ready := true
	return pgReadRowBaselineState(ctx, tx, b, roles, true, &ready)
}

func pgRowIndexSnapshot(ctx context.Context, conn *pgx.Conn, source pgIndexWorkerSource, roles PgMigrationControlRoles, expected PgMigrationControlState) (snapshot pgIndexWorkerSnapshot, err error) {
	err = pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		if source.row == nil {
			return pgIndexRefuse("row index snapshot lacks exact source")
		}
		if err := pgControlRoles(ctx, tx, roles, false); err != nil {
			return pgIndexInspectionFailure(err)
		}
		snapshot.ready = true
		var err error
		snapshot.state, _, err = pgReadRowBaselineState(ctx, tx, source.row, roles, true, &snapshot.ready)
		if err != nil {
			return pgIndexInspectionFailure(err)
		}
		state := snapshot.state
		if state.Format != 5 || state.DatabaseUUID != expected.DatabaseUUID || state.FenceNamespace != expected.FenceNamespace || state.FenceDomain != expected.FenceDomain || state.Current < source.executionVersion() || state.MinVersion > source.executionVersion() {
			return pgIndexRefuse("row index installation identity or admission changed")
		}
		var floor int
		if err := tx.QueryRow(ctx, "select "+pgx.Identifier{source.Namespace, "tesl_admit"}.Sanitize()+"($1)", source.executionVersion()).Scan(&floor); err != nil {
			return pgIndexInspectionFailure(err)
		}
		intents, err := pgReadExpansionIntents(ctx, tx, source.Namespace)
		if err != nil {
			return err
		}
		forward, err := pgReadRowForwardManifest(ctx, tx, source.row)
		if err != nil {
			return pgIndexInspectionFailure(err)
		}
		snapshot.jobs, err = pgReadRowIndexJobs(ctx, tx, source.row, forward, intents, true)
		return err
	})
	if err == nil && slices.ContainsFunc(snapshot.jobs, func(j pgMigrationIndexJob) bool { return j.stagePromotion && j.State == "valid" }) {
		err = pgFinishStageEnforcement(ctx, conn, source.row, roles)
	}
	return snapshot, err
}

// Worker owns entity DDL. SQL fences immutable registration identities; the
// checked source and full semantic pre/post observation remain in this atomic
// production path. No standalone SQL-only compiler-proof claim is made.
func pgRegisterRowIndex(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, roles PgMigrationControlRoles, ordinal int, index pgRowConcurrentIndex) error {
	if b.target == nil || b.target.compiled == nil {
		return fmt.Errorf("row index registration lacks checked target")
	}
	previous, err := pgCompiledRowPredecessorPlan(b.database, b.target.version)
	if err != nil {
		return err
	}
	operations, err := pgRowForwardOperations(previous, b.target)
	if err != nil {
		return err
	}
	if ordinal < 0 || ordinal >= len(operations) || operations[ordinal].index == nil || operations[ordinal].index.entity != index.entity || operations[ordinal].index.table != index.table || !pgPhysicalIndexEqual(operations[ordinal].index.index, index.index) {
		return fmt.Errorf("row index registration differs from checked source operation")
	}
	if _, _, err := pgReadRowIndexExecutionState(ctx, tx, b, roles); err != nil {
		return err
	}
	migrationBoundary("row-index-before-register")
	_, err = tx.Exec(ctx, "select "+pgx.Identifier{b.history.Namespace, "tesl_register_row_index"}.Sanitize()+"($1,$2,$3,$4,$5,$6,$7,$8)", pgMigrationObjectHash(b.target.hash, ordinal), b.target.version, ordinal, index.table, index.index.Name, index.index.Columns, index.index.Unique, b.target.hash)
	if err != nil {
		return err
	}
	if err := pgRegisterStagePreparation(ctx, tx, b, index, ordinal); err != nil {
		return err
	}
	migrationBoundary("row-index-after-register")
	_, _, err = pgReadRowIndexExecutionState(ctx, tx, b, roles)
	return err
}

func pgRowIndexFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	functions := pgMigrationIndexFunctions(namespace)
	for i, fn := range functions {
		guard := ` if not exists(select 1 from ` + ns + `tesl_schema_meta where id=1 and format_version=5 and initial_version=1) then raise exception 'tesl: row index requires format5'; end if;
`
		if fn.name == "tesl_register_index" {
			functions[i].name = "tesl_register_row_index"
			functions[i].arguments += ", physical_hash text"
			guard += ` if v is null or v<2 or physical_hash is null or uniq is distinct from false or
 not exists(select 1 from ` + ns + `tesl_row_physical p join ` + ns + `tesl_schema_expansions x on x.version=p.version
 where p.version=v and p.contract_hash=physical_hash and p.epoch_preserving and x.artefact_hash=p.contract_hash and x.source_abi=p.compiler_abi and x.operation_count=p.operation_count and n>=0 and n<p.operation_count) then
 raise exception 'tesl: row index differs from exact additive physical intent'; end if;
`
		}
		if fn.name == "tesl_claim_index" || fn.name == "tesl_lock_expired_index_holder" {
			fn.body = strings.Replace(fn.body, " select source_abi into creator from "+ns+"tesl_schema_expansions where version=job.version;", ` if job.is_unique then
 select c.compiler_abi into creator from `+ns+`tesl_schema_stage_promotions p join `+ns+`tesl_schema_stage_contracts c on c.version=p.version and c.contract_hash=p.contract_hash
 where p.job_id=job.id and p.version=job.version and p.ordinal=job.ordinal;
 else
 select source_abi into creator from `+ns+`tesl_schema_expansions where version=job.version;
 end if;`, 1)
		}
		functions[i].body = strings.Replace(fn.body, "\nbegin\n", "\nbegin\n"+guard, 1)
	}
	return functions
}

// Index build admission precedes readiness publication. Row conversion starts
// only after the index observer proves this application's write readiness.
func pgRunRowIndexServices(ctx context.Context, conn *pgx.Conn, config *pgx.ConnConfig, b *pgRowBaseline, roles PgMigrationControlRoles, state PgMigrationControlState, onReady func(PgMigrationControlState) error) error {
	indexes, err := pgRowHasConcurrentIndexes(b)
	if err != nil {
		return err
	}
	if !indexes {
		// Preserve the ordinary row worker lifecycle when there is no checked
		// index work. In particular original V1 needs no physical companion or
		// perpetual index-actor writer fence.
		if err := onReady(state); err != nil {
			return err
		}
		closeCtx, stop := context.WithTimeout(context.Background(), 5*time.Second)
		err := conn.Close(closeCtx)
		stop()
		if err != nil {
			return err
		}
		return pgRunRowWorker(ctx, config, b, roles)
	}
	settings, err := pgIndexWorkerConfiguration()
	if err != nil {
		return err
	}
	service, cancel := context.WithCancel(ctx)
	defer cancel()
	var rowDone chan error
	ready := func(current PgMigrationControlState) error {
		if err := onReady(current); err != nil {
			return err
		}
		if b.target != nil && len(b.target.windows) > 0 {
			rowDone = make(chan error, 1)
			go func() { err := pgRunRowWorker(service, config, b, roles); rowDone <- err; cancel() }()
		}
		return nil
	}
	err = pgRunIndexWorkerSource(service, conn, config, pgIndexWorkerSource{PgCompiledMigrationHistory: b.history, row: b}, roles, state, ready, settings)
	cancel()
	if rowDone != nil {
		err = errors.Join(err, <-rowDone)
	}
	return err
}

func pgRowHasConcurrentIndexes(b *pgRowBaseline) (bool, error) {
	if b == nil || b.database == nil {
		return false, fmt.Errorf("row index service lacks checked database owner")
	}
	verified, err := pgCompiledRowBaseline(b.database)
	if err != nil {
		return false, err
	}
	if verified.history != b.history || verified.inventoryHash != b.inventoryHash || verified.catalogHash != b.catalogHash || verified.target != b.target || verified.physical != b.physical {
		return false, fmt.Errorf("row index service source identity differs")
	}
	for version := 2; version <= b.history.CurrentVersion; version++ {
		previous, err := pgCompiledRowPredecessorPlan(b.database, version)
		if err != nil {
			return false, err
		}
		current, err := pgCompiledRowPhysicalPlan(b.database, version)
		if err != nil {
			return false, err
		}
		operations, err := pgRowForwardOperations(previous, current)
		if err != nil {
			return false, err
		}
		for _, operation := range operations {
			if operation.index != nil {
				return true, nil
			}
		}
	}
	return false, nil
}
