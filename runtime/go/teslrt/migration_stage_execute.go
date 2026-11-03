package teslrt

import (
	"context"
	"fmt"
	"github.com/jackc/pgx/v5"
	"slices"
)

func pgExecuteStageContract(ctx context.Context, conn *pgx.Conn, settings *pgx.ConnConfig, b *pgRowBaseline, roles PgMigrationControlRoles, c *pgRowContract, requireDrained bool) (PgMigrationControlState, error) {
	var state PgMigrationControlState
	if c == nil || c.compiled == nil || c.window != b.target || len(c.window.stageGuards) == 0 {
		return state, fmt.Errorf("promotion requires exact compiler-owned reviewed Contract")
	}
	doc, err := pgRowBaselineHex(c.contract)
	if err != nil {
		return state, err
	}
	settled, err := pgRowBaselineHex(c.settled.contract)
	if err != nil {
		return state, err
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	if err := pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
		var err error
		state, _, err = pgReadRowIndexExecutionState(ctx, tx, b, roles)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "select "+ns+"tesl_register_stage_contract($1,$2,$3,$4,$5,$6)", c.window.version, doc, c.hash, settled, c.settled.hash, b.history.SourceCompilerABI)
		return err
	}); err != nil {
		return state, err
	}
	var alreadyEnforced int
	if err := conn.QueryRow(ctx, "select count(*) from "+ns+"tesl_schema_stage_promotions where version=$1 and contract_hash=$2 and state='enforced'", c.window.version, c.hash).Scan(&alreadyEnforced); err != nil {
		return state, err
	}
	if alreadyEnforced == len(c.window.stageGuards) {
		return state, nil
	}
	migrationBoundary("stage-contract-after-intent")
	// The existing epoch transition drains both writer and representation domains
	// and verifies its exact immutable source prefix. Its commit precedes job
	// registration, so no DDL actor can see the target while old writers remain.
	if _, err := pgExecuteRowEpoch(ctx, conn, b, roles, c.window.version, !requireDrained, false); err != nil {
		return state, err
	}
	migrationBoundary("stage-contract-after-floor")
	if err := pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, "select "+ns+"tesl_stage_handoff($1,$2)", c.window.version, c.hash)
		return err
	}); err != nil {
		return state, err
	}
	migrationBoundary("stage-contract-after-handoff")
	if err := pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		var err error
		state, _, err = pgReadRowIndexExecutionState(ctx, tx, b, roles)
		return err
	}); err != nil {
		return state, err
	}
	ddl, err := pgx.ConnectConfig(ctx, settings.Copy())
	if err != nil {
		return state, err
	}
	timings, err := pgIndexWorkerConfiguration()
	if err != nil {
		_ = ddl.Close(ctx)
		return state, err
	}
	if err := pgRunIndexWorkerSource(ctx, ddl, settings, pgIndexWorkerSource{PgCompiledMigrationHistory: b.history, row: b, untilValid: true}, roles, state, nil, timings); err != nil {
		return state, err
	}
	if err := pgFinishStageEnforcement(ctx, conn, b, roles); err != nil {
		return state, err
	}
	var enforced int
	if err := conn.QueryRow(ctx, "select count(*) from "+ns+"tesl_schema_stage_promotions where version=$1 and contract_hash=$2 and state='enforced'", c.window.version, c.hash).Scan(&enforced); err != nil {
		return state, err
	}
	if enforced != len(c.window.stageGuards) {
		return state, fmt.Errorf("stage Contract awaits exact usable target catalogs and durable enforcement receipts")
	}
	err = pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		var err error
		state, _, err = pgReadRowIndexExecutionState(ctx, tx, b, roles)
		return err
	})
	return state, err
}

func pgFinishStageEnforcement(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles) error {
	if b == nil || b.target == nil {
		return nil
	}
	changed := false
	err := pgRowControlWrite(ctx, conn, func(tx pgx.Tx) error {
		authorities, err := pgStageIndexAuthorities(ctx, tx, b.history.Namespace)
		if err != nil {
			return err
		}
		ns := quoteIdentifier(b.history.Namespace) + "."
		keys := make([]string, 0, len(authorities))
		for key := range authorities {
			keys = append(keys, key)
		}
		slices.SortFunc(keys, func(a, b string) int {
			x, y := authorities[a].guard.preparation, authorities[b].guard.preparation
			if x.table < y.table {
				return -1
			}
			if x.table > y.table {
				return 1
			}
			if x.id < y.id {
				return -1
			}
			if x.id > y.id {
				return 1
			}
			return 0
		})
		for _, job := range keys {
			a := authorities[job]
			if a.state == "enforced" || a.version > b.target.version {
				continue
			}
			var ready bool
			if err := tx.QueryRow(ctx, "select "+ns+"tesl_prepare_stage_enforcement($1)", a.guard.preparation.id).Scan(&ready); err != nil {
				return err
			}
			if !ready {
				continue
			}
			migrationBoundary("stage-before-enforcement")
			if _, err := tx.Exec(ctx, "drop trigger "+quoteIdentifier(pgStageGuardName(a.guard.preparation.id))+" on "+pgx.Identifier{b.history.Namespace, a.guard.preparation.table}.Sanitize()); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, "select "+ns+"tesl_finish_stage_enforcement($1)", a.guard.preparation.id); err != nil {
				return err
			}
			changed = true
			migrationBoundary("stage-after-enforcement-statement")
		}
		return nil
	})
	if err == nil && changed {
		migrationBoundary("stage-after-enforcement-commit")
	}
	return err
}
