package teslrt

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

func pgMigrationRoles(config PostgresConfig, login string) (PgMigrationControlRoles, error) {
	owner := config.ControlOwner
	if owner == "" {
		owner = "tesl_control"
	}
	topology := config.MigrationTopology
	if topology == "" {
		topology = "Embedded"
		if _, deployed := os.LookupEnv("TESL_DEPLOYED"); deployed {
			topology = "Worker"
		}
	}
	roles := PgMigrationControlRoles{Owner: owner, Worker: login}
	switch topology {
	case "Embedded":
		if config.RequestRole != "" || config.WorkerRole != "" {
			return roles, fmt.Errorf("requestRole and workerRole require Worker migration topology")
		}
	case "Worker":
		roles.Request, roles.Worker = config.RequestRole, config.WorkerRole
		if roles.Request == "" {
			roles.Request = "tesl_app"
		}
		if roles.Worker == "" {
			roles.Worker = "tesl_schema"
		}
	default:
		return roles, fmt.Errorf("unknown migration topology %q", topology)
	}
	return roles, nil
}

func pgMigrationDDLConfig(config PostgresConfig) (*pgx.ConnConfig, error) {
	dsn := config.DDLConnection
	if dsn == "" {
		dsn = postgresDSN(config)
	}
	parsed, err := pgx.ParseConfig(dsn)
	if err != nil {
		// DSNs can contain credentials. The parser's error includes its input.
		return nil, fmt.Errorf("invalid migration DDL connection configuration")
	}
	return parsed, nil
}

func pgVerifyRequestGrants(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, catalog []PgMigrationCatalogTable) error {
	if roles.Request == "" {
		return nil
	}
	var namespaceOK bool
	if err := tx.QueryRow(ctx, `select pg_catalog.has_schema_privilege($1,$2,'USAGE')
 and not pg_catalog.has_schema_privilege($1,$2,'CREATE')`, roles.Request, namespace).Scan(&namespaceOK); err != nil {
		return err
	}
	if !namespaceOK {
		return fmt.Errorf("migration request role requires namespace USAGE without CREATE")
	}
	for _, table := range catalog {
		var valid bool
		if err := tx.QueryRow(ctx, `select
 pg_catalog.has_table_privilege($1,c.oid,'SELECT') and pg_catalog.has_table_privilege($1,c.oid,'INSERT')
 and pg_catalog.has_table_privilege($1,c.oid,'UPDATE') and pg_catalog.has_table_privilege($1,c.oid,'DELETE')
 and not pg_catalog.has_table_privilege($1,c.oid,'TRUNCATE,REFERENCES,TRIGGER')
 and not pg_catalog.has_any_column_privilege($1,c.oid,'REFERENCES')
 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname=$2 and c.relname=$3`, roles.Request, namespace, table.Name).Scan(&valid); err != nil {
			return err
		}
		if !valid {
			return fmt.Errorf("migration request privileges for %s.%s differ from the DML-only grant profile", namespace, table.Name)
		}
	}
	return nil
}

// Request startup observes fresh snapshots without acquiring the schema boot
// lock or creating comparison objects. A pending worker can keep progressing;
// the request pool is published only after its own revision is fully expanded.
func pgWaitForMigrationReadiness(ctx context.Context, conn *pgx.Conn, history PgCompiledMigrationHistory, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	var result PgMigrationControlState
	if roles.Request == "" {
		return result, fmt.Errorf("migration readiness requires Worker topology")
	}
	for {
		ready := false
		err := pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
			if err := pgControlRoles(ctx, tx, roles, false); err != nil {
				return err
			}
			var currentUser, sessionUser string
			if err := tx.QueryRow(ctx, "select current_user,session_user").Scan(&currentUser, &sessionUser); err != nil {
				return err
			}
			if currentUser != roles.Request || sessionUser != roles.Request {
				return fmt.Errorf("migration request startup requires the configured request identity")
			}
			state, err := pgInspectControlReadOnly(ctx, tx, history.Namespace, roles)
			if err != nil {
				return err
			}
			if result.Present && (result.DatabaseUUID != state.DatabaseUUID || result.FenceNamespace != state.FenceNamespace) {
				return fmt.Errorf("migration installation identity changed while waiting for the schema worker")
			}
			result = state
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
			catalog, err := pgExpansionRecordedCatalog(plan, intents)
			if err != nil {
				return err
			}
			report, err := pgInspectMigrationCatalogReadOnlyInTx(ctx, tx, history.Namespace, roles.Worker, catalog)
			if err != nil {
				return err
			}
			for _, issues := range [][]PgMigrationCatalogIssue{report.Missing, report.Drift} {
				if len(issues) != 0 {
					return fmt.Errorf("migration catalog %s.%s: %s", issues[0].Table, issues[0].Object, issues[0].Reason)
				}
			}
			if err := pgVerifyRequestGrants(ctx, tx, history.Namespace, roles, catalog); err != nil {
				return err
			}
			if history.CurrentVersion < state.MinVersion {
				return fmt.Errorf("migration request revision V%d is retired", history.CurrentVersion)
			}
			ready = state.Current >= history.CurrentVersion && state.Current != 0
			return nil
		})
		if err != nil {
			return PgMigrationControlState{}, err
		}
		if ready {
			return result, nil
		}
		migrationBoundary("request-readiness-pending")
		timer := time.NewTimer(250 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return PgMigrationControlState{}, fmt.Errorf("waiting for schema worker to expand V%d: %w", history.CurrentVersion, ctx.Err())
		case <-timer.C:
		}
	}
}
