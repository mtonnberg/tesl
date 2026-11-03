package teslrt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// These errors distinguish drainable protocol blockers from source, catalog or
// data failures. Deployment may wait for a drain; it never forces retirement or
// retries arbitrary application callbacks after an unclassified error.
type pgMigrationDrainError struct{ message string }

func (e *pgMigrationDrainError) Error() string { return e.message }

type pgQueueContractBlockedError struct{}

func (*pgQueueContractBlockedError) Error() string {
	return "queue Contract is blocked by old payloads, claims or conversion attempts; complete the checked repairs first"
}

func pgCheckDeploymentIdentity(actual PgMigrationControlState, expected *PgMigrationControlState) error {
	if expected != nil && (actual.DatabaseUUID != expected.DatabaseUUID || actual.FenceNamespace != expected.FenceNamespace || actual.FenceDomain != expected.FenceDomain || actual.InitialVersion != expected.InitialVersion || actual.Format != expected.Format) {
		return fmt.Errorf("schema deployment installation identity changed; refuse to execute a different database or origin")
	}
	return nil
}

func pgDeploymentTimeout() (time.Duration, error) {
	text := os.Getenv("TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS")
	if text == "" {
		return 10 * time.Minute, nil
	}
	seconds, err := strconv.Atoi(text)
	if err != nil || seconds < 1 || seconds > 86400 {
		return 0, fmt.Errorf("TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS must be an integer from 1 through 86400")
	}
	return time.Duration(seconds) * time.Second, nil
}

func pgDeploymentConnections(config PostgresConfig, roles PgMigrationControlRoles) (*pgx.ConnConfig, *pgx.ConnConfig, error) {
	if roles.Request == "" {
		return nil, nil, fmt.Errorf("combined schema setup requires Worker migration topology")
	}
	dsn := os.Getenv("TESL_SCHEMA_INSTALLER_DSN")
	if dsn == "" {
		return nil, nil, fmt.Errorf("combined schema setup requires TESL_SCHEMA_INSTALLER_DSN for its separate Installer connection")
	}
	installer, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, nil, fmt.Errorf("invalid TESL_SCHEMA_INSTALLER_DSN connection configuration")
	}
	worker, err := pgMigrationDDLConfig(config)
	if err != nil {
		return nil, nil, err
	}
	if worker.User != roles.Worker || installer.User == roles.Worker || installer.User == roles.Request {
		return nil, nil, fmt.Errorf("combined schema setup requires the configured Worker login in ddlConnection and a distinct Installer login in TESL_SCHEMA_INSTALLER_DSN")
	}
	installer.RuntimeParams["application_name"] = "tesl-exec:" + UUIDv7()
	worker.RuntimeParams["application_name"] = "tesl-exec:" + UUIDv7()
	return installer, worker, nil
}

type pgPreparedRowWorker struct {
	connection *pgx.Conn
	config     *pgx.ConnConfig
	installed  PgMigrationControlState
}

func pgCloseSchemaConnection(conn *pgx.Conn) error {
	cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return conn.Close(cleanup)
}

// Installer state is confined to this startup frame. Only the independently
// authenticated Worker connection/configuration and installed identity escape.
func pgPrepareRowWorker(ctx context.Context, b *pgRowBaseline, roles PgMigrationControlRoles) (prepared *pgPreparedRowWorker, resultErr error) {
	installerConfig, workerConfig, err := pgDeploymentConnections(b.database.Config, roles)
	if err != nil {
		return nil, err
	}
	startup, stop := context.WithTimeout(ctx, pgLeaseTimeout())
	defer stop()
	worker, err := pgx.ConnectConfig(startup, workerConfig)
	if err != nil {
		return nil, fmt.Errorf("schema setup cannot connect its Worker; check ddlConnection and credentials")
	}
	defer func() {
		if resultErr != nil {
			resultErr = errors.Join(resultErr, pgCloseSchemaConnection(worker))
		}
	}()
	// Check Worker isolation before the Installer can mutate anything. The
	// existing role policy still refuses leaked non-administrative Owner grants.
	if err := pgControlTransaction(startup, worker, false, func(tx pgx.Tx) error {
		if err := pgControlRoles(startup, tx, roles, false); err != nil {
			return err
		}
		var exact bool
		if err := tx.QueryRow(startup, "select current_user=$1 and session_user=$1", roles.Worker).Scan(&exact); err != nil {
			return err
		}
		if !exact {
			return fmt.Errorf("schema setup requires exact Worker session identity")
		}
		return nil
	}); err != nil {
		return nil, err
	}
	installer, err := pgx.ConnectConfig(startup, installerConfig)
	if err != nil {
		return nil, fmt.Errorf("schema setup cannot connect its Installer; check TESL_SCHEMA_INSTALLER_DSN and credentials")
	}
	defer func() { resultErr = errors.Join(resultErr, pgCloseSchemaConnection(installer)) }()
	// The live backend tag/PID must be visible in the Worker's own database.
	// This permits different connection endpoints without mistaking equal
	// database names on different clusters for the same installation.
	var installerPID int
	if err := installer.QueryRow(startup, "select pg_catalog.pg_backend_pid()").Scan(&installerPID); err != nil {
		return nil, err
	}
	var sameDatabase bool
	if err := worker.QueryRow(startup, `select exists(select 1 from pg_catalog.pg_stat_activity
 where pid=$1 and application_name=$2 and datname=pg_catalog.current_database())`, installerPID, installerConfig.RuntimeParams["application_name"]).Scan(&sameDatabase); err != nil {
		return nil, err
	}
	if !sameDatabase {
		return nil, fmt.Errorf("schema setup Installer and Worker must use dedicated sessions to the same PostgreSQL database")
	}
	installed, err := InstallPgCompiledRowBaseline(startup, installer, b.database, roles)
	if err != nil {
		return nil, fmt.Errorf("schema setup installation: %w", err)
	}
	stop()
	if err := pgStageRowQueueHistory(ctx, installer, b, roles, &installed); err != nil {
		return nil, fmt.Errorf("schema setup staging: %w", err)
	}
	if err := pgCloseSchemaConnection(installer); err != nil {
		return nil, err
	}
	// Avoid accidental reuse and inheritance by child processes. This is not
	// secure erasure of the original environment or a process-isolation boundary.
	if err := os.Unsetenv("TESL_SCHEMA_INSTALLER_DSN"); err != nil {
		return nil, fmt.Errorf("cannot remove the consumed Installer connection from the process environment")
	}
	return &pgPreparedRowWorker{worker, workerConfig, installed}, nil
}

func pgRunRowDeployment(parent context.Context, command pgSchemaCommand, out io.Writer, b *pgRowBaseline, roles PgMigrationControlRoles) (resultErr error) {
	budget, err := pgDeploymentTimeout()
	if err != nil {
		return err
	}
	terminalContract := b.target != nil && (len(b.target.windows) > 0 || len(b.target.retirements) > 0)
	if terminalContract {
		if _, err := pgRowContractFor(b.database, b.history.CurrentVersion); err != nil {
			return fmt.Errorf("schema deploy requires a reviewed final row Contract; generate it with tesl migrate contract --version %d app.tesl --manifest-json and rebuild: %w", b.history.CurrentVersion, err)
		}
	}
	ctx, cancel := context.WithTimeout(parent, budget)
	defer cancel()
	prepared, err := pgPrepareRowWorker(ctx, b, roles)
	if err != nil {
		return err
	}
	worker, workerConfig, installed := prepared.connection, prepared.config, prepared.installed
	defer func() { resultErr = errors.Join(resultErr, pgCloseSchemaConnection(worker)) }()
	migrationBoundary("schema-deploy-after-installer-close")
	var state PgMigrationControlState
	for {
		err = pgMigrationSessionLock(ctx, worker, installed.FenceNamespace, 2147483647, true, func() error {
			var err error
			state, err = pgExecuteRowCatchupFor(ctx, worker, workerConfig, b, roles, &installed)
			if err != nil {
				return err
			}
			if terminalContract {
				state, err = pgExecuteRowContractOn(ctx, worker, workerConfig, b, roles, b.history.CurrentVersion, true)
				if err != nil {
					return err
				}
			}
			return pgCheckDeploymentIdentity(state, &installed)
		})
		if err == nil {
			break
		}
		if ctx.Err() != nil {
			return fmt.Errorf("schema deployment stopped: %w", errors.Join(err, ctx.Err()))
		}
		wait, inspectErr := pgDeploymentCanWait(ctx, worker, b.history.Namespace, err)
		if inspectErr != nil || !wait {
			return fmt.Errorf("schema deployment blocked: %w", errors.Join(err, inspectErr))
		}
		if waitErr := pgIndexWait(ctx, time.Second); waitErr != nil {
			return fmt.Errorf("schema deployment stopped while waiting for drain: %w", errors.Join(err, waitErr))
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := pgCloseSchemaConnection(worker); err != nil {
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
			DatabaseUUID   string `json:"databaseUuid"`
		}{1, "schema-deployed", b.history.Database, b.history.CurrentVersion, state.Current, state.MinVersion, state.DatabaseUUID})
	}
	_, err = fmt.Fprintf(out, "%s: schema deployed at V%d; minimum V%d.\n", b.history.Database, state.Current, state.MinVersion)
	return err
}

func pgDeploymentCanWait(ctx context.Context, conn *pgx.Conn, namespace string, err error) (bool, error) {
	var drain *pgMigrationDrainError
	if errors.As(err, &drain) {
		return true, nil
	}
	var server *pgconn.PgError
	if errors.As(err, &server) && server.Code == "P0001" && server.Message == "tesl: retiring queue attempts are still leased; stop old workers and retry after their leases expire" {
		return true, nil
	}
	var blocked *pgQueueContractBlockedError
	if !errors.As(err, &blocked) {
		return false, nil
	}
	migrationBoundary("schema-deploy-before-queue-status")
	query, stop := context.WithTimeout(ctx, pgLeaseTimeout())
	defer stop()
	var raw []byte
	if err := conn.QueryRow(query, "select "+pgx.Identifier{namespace, "tesl_row_queue_status"}.Sanitize()+"()").Scan(&raw); err != nil {
		return false, err
	}
	return pgQueueStatusCanWait(raw)
}

// This is only consulted after a typed queue Contract refusal. The status is a
// later snapshot: a claim can expire (leaving convertible old payloads), or a
// peer can finish the work (leaving no blockers), before this lookup. Retrying
// re-enters checked catch-up and Contract; it does not bypass either operation.
func pgQueueStatusCanWait(raw []byte) (bool, error) {
	if err := pgMigrationCheckJSON(string(raw)); err != nil {
		return false, fmt.Errorf("invalid queue status: %w", err)
	}
	var status map[string]json.RawMessage
	if err := json.Unmarshal(raw, &status); err != nil {
		return false, err
	}
	var blockers []map[string]json.RawMessage
	if err := json.Unmarshal(status["blockers"], &blockers); err != nil {
		return false, err
	}
	if blockers == nil {
		return false, errors.New("queue status requires an explicit blockers array")
	}
	for _, blocker := range blockers {
		var code string
		var count int64
		if err := json.Unmarshal(blocker["code"], &code); err != nil {
			return false, err
		}
		if err := json.Unmarshal(blocker["count"], &count); err != nil {
			return false, err
		}
		if code == "" || count <= 0 {
			return false, errors.New("queue status contains a malformed blocker")
		}
		switch code {
		case "QUEUE_RETIRING_CLAIMS", "QUEUE_CONVERSION_ATTEMPTS", "RECENT_RETIRING_INSTANCES", "QUEUE_OLD_PAYLOADS":
			// All blockers must be known and progress-capable. Terminal or new
			// codes must not be hidden by a transient blocker in either order.
		default:
			return false, nil
		}
	}
	return true, nil
}
