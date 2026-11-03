package teslrt

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

// UpgradePgCompiledMigrationControl performs the explicit, metadata-only 2 -> 3
// bridge. All existing binaries must first be replaced with bridge readers that
// understand both formats. Heartbeats cannot establish that absent old binaries
// will never restart, so that deployment prerequisite is not inferred from them.
// No boot path calls this function. New installations use the current format.
//
// The source history must cover every installed revision, and format 2 must have
// no unfinished expansion. This one transactional substep needs no resumable
// partial markers: a crash leaves exact format 2 or exact format 3. Existing
// lifecycle rows, ABI provenance, UUID and fence allocation are never rewritten.
func UpgradePgCompiledMigrationControl(ctx context.Context, conn *pgx.Conn, history PgCompiledMigrationHistory,
	roles PgMigrationControlRoles, targetFormat int) (PgMigrationControlState, error) {
	var observed, result PgMigrationControlState
	if targetFormat != 3 {
		return result, fmt.Errorf("explicit migration control upgrade supports only format 2 to 3")
	}
	if _, err := history.ExpansionPlan(history.CurrentVersion); err != nil {
		return result, err
	}
	// Do not hold the global installer lock while waiting for the family boot
	// lock: existing expanders take boot first and then the shared installer lock.
	err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles, true); err != nil {
			return err
		}
		var err error
		observed, err = pgInspectControl(ctx, tx, history.Namespace, roles)
		return err
	})
	if err != nil {
		return result, err
	}
	err = pgMigrationSessionLock(ctx, conn, observed.FenceNamespace, 2147483647, true, func() error {
		return pgControlTransaction(ctx, conn, true, func(tx pgx.Tx) error {
			if err := pgControlRoles(ctx, tx, roles, true); err != nil {
				return err
			}
			state, err := pgInspectControl(ctx, tx, history.Namespace, roles)
			if err != nil {
				return err
			}
			if state.DatabaseUUID != observed.DatabaseUUID || state.FenceNamespace != observed.FenceNamespace {
				return fmt.Errorf("migration installation identity changed while acquiring the upgrade locks")
			}
			plan, err := history.ExpansionPlan(state.InitialVersion)
			if err != nil {
				return err
			}
			intents, err := pgReadExpansionIntents(ctx, tx, history.Namespace)
			if err != nil {
				return err
			}
			if err := pgVerifyExpansionHistory(state, plan, intents); err != nil {
				return err
			}
			if state.Format == targetFormat {
				result = state
				return nil // An acknowledged or ambiguous prior commit is idempotent.
			}
			if state.Format != 2 || state.Current == 0 || state.InstallingVersion != 0 || plan.CurrentVersion < state.Current || len(intents) != state.Current-state.InitialVersion+1 {
				return fmt.Errorf("control format upgrade requires completed additive history covered by this binary; finish the existing expansion first")
			}
			catalog, err := pgExpansionRecordedCatalog(plan, intents)
			if err != nil {
				return err
			}
			if err := pgVerifyExpansionCatalog(ctx, tx, history.Namespace, roles.Worker, catalog); err != nil {
				return err
			}
			if err := pgVerifyRequestGrants(ctx, tx, history.Namespace, roles, catalog); err != nil {
				return err
			}
			migrationBoundary("control-upgrade-before-objects")
			if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
				return err
			}
			readers := quoteIdentifier(roles.Worker)
			if roles.Request != "" {
				readers += "," + quoteIdentifier(roles.Request)
			}
			for _, spec := range pgMigrationIndexTables {
				qualified := pgx.Identifier{history.Namespace, spec.name}.Sanitize()
				if _, err := tx.Exec(ctx, "create table "+qualified+" ("+spec.columns+"); grant select on "+qualified+" to "+readers); err != nil {
					return err
				}
			}
			for _, fn := range pgMigrationIndexFunctions(history.Namespace) {
				if _, err := tx.Exec(ctx, pgControlFunctionSQL(history.Namespace, roles.Owner, fn)); err != nil {
					return err
				}
				qualified := pgx.Identifier{history.Namespace, fn.name}.Sanitize() + "(" + pgControlArgumentTypes(fn) + ")"
				grantees := pgControlFunctionRoles(roles, fn)
				for i := range grantees {
					grantees[i] = quoteIdentifier(grantees[i])
				}
				if _, err := tx.Exec(ctx, "revoke all on function "+qualified+" from public; grant execute on function "+qualified+" to "+strings.Join(grantees, ",")); err != nil {
					return err
				}
			}
			migrationBoundary("control-upgrade-after-objects")
			if _, err := tx.Exec(ctx, "update "+quoteIdentifier(history.Namespace)+".tesl_schema_meta set format_version=3 where id=1 and format_version=2"); err != nil {
				return err
			}
			result, err = pgInspectControl(ctx, tx, history.Namespace, roles)
			if err != nil {
				return err
			}
			if result.DatabaseUUID != observed.DatabaseUUID || result.FenceNamespace != observed.FenceNamespace || result.Format != targetFormat {
				return fmt.Errorf("control upgrade changed its installation identity or failed final format verification")
			}
			migrationBoundary("control-upgrade-before-commit")
			if err := tx.Commit(ctx); err != nil {
				return err
			}
			migrationBoundary("control-upgrade-after-commit")
			return nil
		})
	})
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return result, nil
}
