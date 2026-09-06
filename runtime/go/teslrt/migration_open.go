package teslrt

import (
	"context"
	"crypto/sha256"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func pgMigrationRoles(config PostgresConfig, worker string) PgMigrationControlRoles {
	owner := config.ControlOwner
	if owner == "" {
		owner = "tesl_control"
	}
	return PgMigrationControlRoles{Owner: owner, Worker: worker}
}

// Versioned connections have a separate initialization identity, even when two
// compiled revisions are embedded in one process. They never use legacy entity
// bootstrap or its name-based adoption of existing objects.
func openVersionedPostgres(config PostgresConfig, history PgCompiledMigrationHistory) *PostgresDB {
	if config.Schema != history.Namespace {
		panic("database: migration namespace disagrees with connection")
	}
	dsn := postgresDSN(config)
	poolConfig := postgresPoolConfig(config, dsn)
	roles := pgMigrationRoles(config, poolConfig.ConnConfig.User)
	digest := sha256.Sum256([]byte(history.HistoryJSON))
	key := fmt.Sprintf("versioned\x00%s\x00%s\x00%d\x00%s\x00%s\x00%d\x00%s\x00%x", config.Schema, dsn, poolConfig.MaxConns,
		roles.Owner, history.Database, history.CurrentVersion, history.SourceCompilerABI, digest)
	created := &postgresInitialization{done: make(chan struct{})}
	actual, loaded := postgresConnectOnce.LoadOrStore(key, created)
	initialization, ok := actual.(*postgresInitialization)
	if !ok {
		panic("database: unexpected connection initialization")
	}
	if !loaded {
		initializeVersionedPostgres(key, initialization, poolConfig, history, roles)
	} else {
		<-initialization.done
	}
	if initialization.failure != nil {
		panic(initialization.failure)
	}
	if initialization.db == nil {
		panic("database: versioned initialization completed without a pool")
	}
	return initialization.db
}

func initializeVersionedPostgres(key string, initialization *postgresInitialization, config *pgxpool.Config,
	history PgCompiledMigrationHistory, roles PgMigrationControlRoles) {
	defer close(initialization.done)
	var pool *pgxpool.Pool
	defer func() {
		if failure := recover(); failure != nil {
			if pool != nil {
				pool.Close()
			}
			initialization.failure = failure
			postgresConnectOnce.CompareAndDelete(key, initialization)
		}
	}()
	if _, err := history.ExpansionPlan(1); err != nil {
		panic("database: invalid compiled migration history: " + err.Error())
	}
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	// The boot connection is dedicated. It cannot re-enter a pool carrying the
	// session boot lock, and no request pool is published until execution succeeds.
	conn, err := pgx.ConnectConfig(ctx, config.ConnConfig.Copy())
	if err != nil {
		panic(pgFailure("database: cannot connect migration executor", err))
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), pgLeaseTimeout())
		defer stop()
		_ = conn.Close(cleanup)
	}()
	state, executeErr := ExecutePgMigrationExpansion(ctx, conn, history, roles)
	closeCtx, stopClose := context.WithTimeout(context.Background(), pgLeaseTimeout())
	closeErr := conn.Close(closeCtx)
	stopClose()
	if executeErr != nil {
		panic(pgFailure("database: migration startup refused", executeErr))
	}
	if closeErr != nil {
		panic(pgFailure("database: cannot close migration executor", closeErr))
	}
	db := &PostgresDB{schema: history.Namespace, migration: &pgMigrationAdmission{version: history.CurrentVersion,
		fenceNamespace: state.FenceNamespace, databaseUUID: state.DatabaseUUID, worker: roles.Worker}}
	config.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error { return pgVerifyMigrationConnection(ctx, conn, db) }
	pool, err = pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		panic(pgFailure("database: cannot open versioned pool", err))
	}
	db.pool = pool
	if err := pool.Ping(ctx); err != nil {
		panic(pgFailure("database: versioned connection refused", err))
	}
	initialization.db = db
}

// A replacement/reconnected database may have the same DSN and version numbers
// but a different UUID or fence allocation. Check each physical connection before
// it joins the pool, and dedicated listeners before they read or deliver data.
func pgVerifyMigrationConnection(ctx context.Context, conn *pgx.Conn, db *PostgresDB) error {
	if db.migration == nil {
		return nil
	}
	var uuid, domain, currentUser, sessionUser string
	var fence, format, protocol int
	err := conn.QueryRow(ctx, "select database_uuid::text,fence_ns,format_version,fence_domain,retirement_protocol_floor,current_user,session_user from "+
		pgx.Identifier{db.schema, "tesl_schema_meta"}.Sanitize()+" where id=1").Scan(&uuid, &fence, &format, &domain, &protocol, &currentUser, &sessionUser)
	if err != nil {
		return err
	}
	expected := db.migration
	if uuid != expected.databaseUUID || fence != expected.fenceNamespace || format != pgMigrationControlFormat || domain != "tesl-1" || protocol != 1 ||
		currentUser != expected.worker || sessionUser != expected.worker {
		return fmt.Errorf("migration connection identity, protocol or worker login changed")
	}
	_, err = pgMigrationStatementOn(ctx, db, conn, false, func(pgExecutor) (struct{}, error) { return struct{}{}, nil })
	return err
}
