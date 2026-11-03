package teslrt

import (
	"context"
	"crypto/sha256"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func pgHasRowCompanion(database *Database) bool {
	history, ok := database.CompiledMigrationHistory()
	if !ok {
		return false
	}
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	return compiledRowHistories[history.Family] != nil
}

func pgWaitForRowBaseline(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	for {
		var state PgMigrationControlState
		indexReady := true
		err := pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
			if err := pgControlRoles(ctx, tx, roles, false); err != nil {
				return err
			}
			var user, session string
			if err := tx.QueryRow(ctx, "select current_user,session_user").Scan(&user, &session); err != nil {
				return err
			}
			if user != roles.Request || session != roles.Request {
				return fmt.Errorf("row request readiness requires exact Request login")
			}
			var err error
			state, _, err = pgReadRowBaselineState(ctx, tx, b, roles, false, &indexReady)
			if err != nil {
				return err
			}
			return pgRequireRowFacilitiesOn(ctx, tx, b.database, b.history.Namespace, roles)
		})
		if err != nil {
			return PgMigrationControlState{}, err
		}
		if state.Current >= b.history.CurrentVersion && indexReady {
			return state, nil
		}
		if !indexReady {
			migrationBoundary("row-index-readiness-pending")
		}
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return PgMigrationControlState{}, ctx.Err()
		case <-timer.C:
		}
	}
}

func openRowPostgres(database *Database) (*PostgresDB, func()) {
	baseline, err := pgCompiledRowBaseline(database)
	if err != nil {
		panic(err)
	}
	config := database.Config
	dsn := postgresDSN(config)
	poolConfig := postgresPoolConfig(config, dsn)
	roles, err := pgMigrationRoles(config, poolConfig.ConnConfig.User)
	if err != nil {
		panic(err)
	}
	key := fmt.Sprintf("row-v5\x00%x\x00%d", sha256.Sum256([]byte(config.Schema+"\x00"+baseline.history.Database+"\x00"+baseline.history.Family+"\x00"+dsn+"\x00"+baseline.history.HistoryJSON+"\x00"+roles.Owner+"\x00"+roles.Worker+"\x00"+roles.Request+"\x00"+config.DDLConnection)), poolConfig.MaxConns)
	created := &postgresInitialization{done: make(chan struct{})}
	actual, loaded := postgresConnectOnce.LoadOrStore(key, created)
	initialization, ok := actual.(*postgresInitialization)
	if !ok {
		panic("database: invalid row initialization")
	}
	if loaded {
		<-initialization.done
	}
	// The initial scope owns the embedded executor before publication.
	var release func()
	if !loaded {
		release = initializeRowPostgres(key, initialization, poolConfig, config, baseline, roles)
	}
	if initialization.failure != nil {
		panic(initialization.failure)
	}
	if initialization.db == nil {
		panic("database: row initialization did not publish a pool")
	}
	if loaded && initialization.db.embedded != nil {
		release, err = initialization.db.embedded.acquire()
		if err != nil {
			panic(pgFailure("database: Embedded row migration service refused", err))
		}
	}
	if roles.Request != "" {
		// Any required-extension failure releases a lifetime acquired above.
		defer func() {
			if failure := recover(); failure != nil {
				if release != nil {
					release()
				}
				panic(failure)
			}
		}()
		if pgHasArtifactCaches(database) {
			pgCheckArtifactCacheConnection(initialization.db)
		}
		if pgHasEmail(database) {
			pgRequireEmail(initialization.db)
		}
		if pgHasBroadcast(database) {
			if err := pgRequireBroadcast(initialization.db); err != nil {
				panic(pgFailure("database: SSE storage refused", err))
			}
		}
	}
	return initialization.db, release
}

func initializeRowPostgres(key string, initialization *postgresInitialization, poolConfig *pgxpool.Config, config PostgresConfig, b *pgRowBaseline, roles PgMigrationControlRoles) (release func()) {
	defer close(initialization.done)
	var pool *pgxpool.Pool
	var db *PostgresDB
	defer func() {
		if failure := recover(); failure != nil {
			if release != nil {
				release()
				release = nil
			}
			if db != nil {
				db.closeRowPool()
			} else if pool != nil {
				pool.Close()
			}
			initialization.failure = failure
			postgresConnectOnce.CompareAndDelete(key, initialization)
		}
	}()
	serviceContext := context.Background()
	stopService := func() {}
	if roles.Request == "" {
		serviceContext, stopService = pgEmbeddedContext()
	}
	transferred := false
	defer func() {
		if !transferred {
			stopService()
		}
	}()
	ctx, cancel := context.WithTimeout(serviceContext, pgLeaseTimeout())
	defer cancel()
	startup := poolConfig.ConnConfig.Copy()
	if roles.Request == "" {
		var err error
		startup, err = pgMigrationDDLConfig(config)
		if err != nil {
			panic(err)
		}
	}
	conn, err := pgx.ConnectConfig(ctx, startup)
	if err != nil {
		panic(pgFailure("database: cannot connect row baseline", err))
	}
	defer func() {
		if conn != nil {
			cleanup, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
			defer cancel()
			_ = conn.Close(cleanup)
		}
	}()
	var state PgMigrationControlState
	if roles.Request == "" {
		state, err = pgExecuteRowBaseline(ctx, conn, b, roles)
	} else {
		state, err = pgWaitForRowBaseline(ctx, conn, b, roles)
	}
	if err != nil {
		panic(pgFailure("database: row baseline startup refused", err))
	}
	principal := roles.Worker
	if roles.Request != "" {
		principal = roles.Request
	}
	db = &PostgresDB{schema: b.history.Namespace, migration: &pgMigrationAdmission{version: b.history.CurrentVersion, fenceNamespace: state.FenceNamespace, databaseUUID: state.DatabaseUUID, worker: principal, roles: roles, controlFormat: pgRowControlFormat, rowBaseline: b}}
	db.migration.rowObservation = &pgRowObservationCache{owner: db.migration}
	if len(b.queues[len(b.queues)-1].version.Contracts) > 0 || pgHasBroadcast(b.database) {
		if roles.Request == "" {
			panic(pgMigrationQueueStorageError(b.database.Name))
		}
		db.queueRuntime = &pgQueueRuntime{database: b.database, history: b.history}
	}
	if roles.Request == "" {
		indexes, err := pgRowHasConcurrentIndexes(b)
		if err != nil {
			panic(err)
		}
		if indexes {
			settings, err := pgIndexWorkerConfiguration()
			if err != nil {
				panic(err)
			}
			cancel()
			transferred = true
			owned := conn
			conn = nil
			db.embedded, release, err = pgStartEmbeddedRowIndexService(serviceContext, stopService, owned, startup, b, roles, state, settings)
			if err != nil {
				panic(pgFailure("database: Embedded row migration service refused", err))
			}
		}
	}
	// Index readiness may outlive the short DDL startup budget. Pool admission
	// and heartbeat registration receive a fresh, bounded context.
	poolContext, stopPool := context.WithTimeout(serviceContext, pgLeaseTimeout())
	defer stopPool()
	poolConfig.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error { return pgVerifyMigrationConnection(ctx, conn, db) }
	pool, err = pgxpool.NewWithConfig(poolContext, poolConfig)
	if err != nil {
		panic(pgFailure("database: cannot open row pool", err))
	}
	db.pool = pool
	if err := pool.Ping(poolContext); err != nil {
		panic(pgFailure("database: row pool admission refused", err))
	}
	migrationBoundary("row-startup-before-heartbeat")
	var verifiedRequest *pgx.Conn
	if roles.Request != "" {
		// pgWaitForRowBaseline checked the complete catalog, immutable owner
		// and exact Request login on this dedicated connection. Transfer its
		// ownership instead of opening and fully checking a third connection.
		// Inline's DDL connection is never transferred to a request monitor.
		verifiedRequest, conn = conn, nil
	}
	db.rowHeartbeat, err = pgStartRowHeartbeat(poolContext, db, poolConfig.ConnConfig, verifiedRequest)
	if err != nil {
		panic(pgFailure("database: row instance registration refused", err))
	}
	migrationBoundary("row-startup-after-heartbeat")
	initialization.db = db
	return release
}
