package teslrt

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// An opened binary's immutable protocol binding. Cached catalog observations do
// not authorize requests: admission is checked inside every SQL transaction.
type pgMigrationAdmission struct {
	version, fenceNamespace int
	controlFormat           int
	rowBaseline             *pgRowBaseline
	databaseUUID            string
	worker                  string
	roles                   PgMigrationControlRoles
	rowObservation          *pgRowObservationCache
}

type pgMigrationAdmissionError struct{ cause error }

func (err *pgMigrationAdmissionError) Error() string {
	return "migration admission: " + err.cause.Error()
}
func (err *pgMigrationAdmissionError) Unwrap() error { return err.cause }

func pgAdmitMigrationTransaction(ctx context.Context, tx pgx.Tx, db *PostgresDB, write bool) error {
	protocol := db.migration
	if protocol == nil {
		return nil
	}
	if err := db.rowHeartbeat.check(); err != nil {
		return &pgMigrationAdmissionError{cause: err}
	}
	if write {
		// This statement must finish before admission gets a fresh read-committed
		// snapshot. The shared key lasts until commit/rollback, not just until DML.
		if _, err := tx.Exec(ctx, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,$2::integer)", protocol.fenceNamespace, protocol.version); err != nil {
			return err
		}
		migrationBoundary("writer-fence")
	}
	var floor int
	if err := tx.QueryRow(ctx, pgAdmissionSQL(db, write), protocol.version).Scan(&floor); err != nil {
		return &pgMigrationAdmissionError{cause: err}
	}
	return nil
}

func pgAdmissionSQL(db *PostgresDB, write bool) string {
	admit := "tesl_admit"
	if write && db.migration.controlFormat == pgRowControlFormat {
		admit = "tesl_admit_writer"
	}
	return "select " + pgx.Identifier{db.schema, admit}.Sanitize() + "($1::integer)"
}

const pgReadFenceSQL = "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,$2::integer)"

// pgMigrationStatement holds implicit transactions through scanning, final read
// admission and commit. A caller-owned transaction gets the same gates and is
// admitted again by WithTransaction before its eventual commit.
func pgMigrationStatement[T any](ctx context.Context, db *PostgresDB, write bool, run func(pgExecutor) (T, error)) (value T, resultErr error) {
	existing := currentTransactionFor(db)
	var executor pgExecutor = db.pool
	if existing != nil {
		executor = existing
	}
	return pgMigrationStatementOn(ctx, db, executor, write, run)
}

type pgMigrationTransactionStarter interface {
	BeginTx(context.Context, pgx.TxOptions) (pgx.Tx, error)
}

// Dedicated listener connections use the same gates without spending a pool
// lease. The caller owns this connection and must not expose results early.
func pgMigrationStatementOn[T any](ctx context.Context, db *PostgresDB, executor pgExecutor, write bool, run func(pgExecutor) (T, error)) (value T, resultErr error) {
	if db.migration == nil {
		return run(executor)
	}
	tx, existing := executor.(pgx.Tx)
	owned := !existing
	if owned && !write {
		if conn, release := pgMigrationReadConnection(ctx, executor); conn != nil {
			return pgMigrationPipelinedRead(ctx, db, conn, release, run)
		} else if release != nil {
			return value, release()
		}
	}
	if owned {
		starter, ok := executor.(pgMigrationTransactionStarter)
		if !ok {
			return value, fmt.Errorf("migration statement requires a transaction-capable connection")
		}
		var err error
		tx, err = starter.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
		if err != nil {
			return value, err
		}
		defer func() {
			cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
				resultErr = errors.Join(resultErr, fmt.Errorf("rollback migration request: %w", err))
			}
		}()
	}
	if db.migration.controlFormat == pgRowControlFormat {
		// Format 5 readers and writers pin their SQL representation before any
		// operation. This also covers unchanged entities using the ordinary path.
		if write {
			if _, err := tx.Exec(ctx, pgReadFenceSQL, -db.migration.fenceNamespace, db.migration.version); err != nil {
				return value, err
			}
		} else if err := pgMigrationReadFence(ctx, tx, db, false); err != nil {
			return value, err
		}
	}
	if write {
		if err := pgAdmitMigrationTransaction(ctx, tx, db, true); err != nil {
			return value, err
		}
	}
	value, err := run(tx)
	if err != nil {
		return value, err
	}
	if !write {
		migrationBoundary("read-before-admit")
		if err := pgAdmitMigrationTransaction(ctx, tx, db, false); err != nil {
			var empty T
			return empty, err
		}
	}
	if owned {
		if err := tx.Commit(ctx); err != nil {
			var empty T
			return empty, err
		}
	}
	return value, nil
}

// pgMigrationReadConnection leases the physical connection for an implicit
// read. A nil connection with a nil release means the executor is of another
// kind and the unpipelined path applies; a non-nil release then reports the
// lease failure.
func pgMigrationReadConnection(ctx context.Context, executor pgExecutor) (*pgx.Conn, func() error) {
	switch source := executor.(type) {
	case *pgxpool.Pool:
		leased, err := source.Acquire(ctx)
		if err != nil {
			return nil, func() error { return err }
		}
		return leased.Conn(), func() error { leased.Release(); return nil }
	case *pgx.Conn:
		return source, func() error { return nil }
	}
	return nil, nil
}

// pgMigrationReadFence sends the format-5 shared compatibility key and the
// first admission as one pipeline, optionally preceded by BEGIN. The backend
// executes them in order: admission is a separate statement whose snapshot is
// taken only after the lock is granted, and a failing statement makes the
// server skip everything after it. No application SQL is part of this
// pipeline; the caller runs it only after every result here succeeded.
func pgMigrationReadFence(ctx context.Context, sender interface {
	SendBatch(context.Context, *pgx.Batch) pgx.BatchResults
}, db *PostgresDB, begin bool) error {
	protocol := db.migration
	format5 := protocol.controlFormat == pgRowControlFormat
	batch := &pgx.Batch{}
	if begin {
		batch.Queue("begin isolation level read committed")
	}
	if format5 {
		batch.Queue(pgReadFenceSQL, -protocol.fenceNamespace, protocol.version)
		batch.Queue(pgAdmissionSQL(db, false), protocol.version)
	}
	if batch.Len() == 0 {
		return nil
	}
	results := sender.SendBatch(ctx, batch)
	var err error
	if begin {
		_, err = results.Exec()
	}
	if err == nil && format5 {
		if _, err = results.Exec(); err == nil {
			var floor int
			if err = results.QueryRow().Scan(&floor); err != nil {
				err = &pgMigrationAdmissionError{cause: err}
			}
		}
	}
	if closeErr := results.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if format5 {
		// The process-local registration check runs after the lock was granted
		// and before any application SQL, as in the unpipelined order.
		if err := db.rowHeartbeat.check(); err != nil {
			return &pgMigrationAdmissionError{cause: err}
		}
	}
	return nil
}

// pgMigrationPipelinedRead is the implicit read transaction in three round
// trips: {BEGIN, fence, admission}, the caller's statements, {admission,
// COMMIT}. The final admission still follows every statement of run, and a
// refusal makes the server skip COMMIT. Results leave only after COMMIT.
func pgMigrationPipelinedRead[T any](ctx context.Context, db *PostgresDB, conn *pgx.Conn, release func() error, run func(pgExecutor) (T, error)) (value T, resultErr error) {
	tx := &pgPipelinedTx{conn: conn}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			resultErr = errors.Join(resultErr, fmt.Errorf("rollback migration request: %w", err))
		}
		resultErr = errors.Join(resultErr, release())
	}()
	if err := pgMigrationReadFence(ctx, conn, db, true); err != nil {
		return value, err
	}
	value, err := run(tx)
	if err != nil {
		return value, err
	}
	migrationBoundary("read-before-admit")
	var empty T
	if err := db.rowHeartbeat.check(); err != nil {
		return empty, &pgMigrationAdmissionError{cause: err}
	}
	batch := &pgx.Batch{}
	batch.Queue(pgAdmissionSQL(db, false), db.migration.version)
	batch.Queue("commit")
	results := conn.SendBatch(ctx, batch)
	var floor int
	if err = results.QueryRow().Scan(&floor); err != nil {
		err = &pgMigrationAdmissionError{cause: err}
	} else {
		var tag pgconn.CommandTag
		if tag, err = results.Exec(); err == nil {
			tx.closed = true
			if tag.String() == "ROLLBACK" {
				err = pgx.ErrTxCommitRollback
			}
		}
	}
	if closeErr := results.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return empty, err
	}
	return value, nil
}

// pgPipelinedTx is the transaction handle of a pipelined implicit read. Its
// BEGIN was sent by pgMigrationReadFence and its COMMIT by the read itself;
// statements go straight to the leased connection.
type pgPipelinedTx struct {
	conn   *pgx.Conn
	closed bool
}

func (tx *pgPipelinedTx) Begin(context.Context) (pgx.Tx, error) {
	return nil, fmt.Errorf("an implicit migration read cannot start a nested transaction")
}

func (tx *pgPipelinedTx) Commit(ctx context.Context) error {
	if tx.closed {
		return pgx.ErrTxClosed
	}
	tag, err := tx.conn.Exec(ctx, "commit")
	tx.closed = true
	if err != nil {
		if tx.conn.PgConn().TxStatus() != 'I' {
			_ = tx.conn.Close(ctx)
		}
		return err
	}
	if tag.String() == "ROLLBACK" {
		return pgx.ErrTxCommitRollback
	}
	return nil
}

// Rollback also covers a failed BEGIN pipeline: an idle or closed session has
// no transaction to end. A failed rollback closes the connection, so the pool
// never reuses a session in an unknown transaction state.
func (tx *pgPipelinedTx) Rollback(ctx context.Context) error {
	if tx.closed {
		return pgx.ErrTxClosed
	}
	tx.closed = true
	if tx.conn.IsClosed() || tx.conn.PgConn().TxStatus() == 'I' {
		return nil
	}
	if _, err := tx.conn.Exec(ctx, "rollback"); err != nil {
		_ = tx.conn.Close(ctx)
		return err
	}
	return nil
}

func (tx *pgPipelinedTx) CopyFrom(ctx context.Context, table pgx.Identifier, columns []string, source pgx.CopyFromSource) (int64, error) {
	if tx.closed {
		return 0, pgx.ErrTxClosed
	}
	return tx.conn.CopyFrom(ctx, table, columns, source)
}

func (tx *pgPipelinedTx) SendBatch(ctx context.Context, batch *pgx.Batch) pgx.BatchResults {
	return tx.conn.SendBatch(ctx, batch)
}

// The runtime never uses large objects; the zero value refuses by panicking.
func (tx *pgPipelinedTx) LargeObjects() pgx.LargeObjects { return pgx.LargeObjects{} }

func (tx *pgPipelinedTx) Prepare(ctx context.Context, name, sql string) (*pgconn.StatementDescription, error) {
	if tx.closed {
		return nil, pgx.ErrTxClosed
	}
	return tx.conn.Prepare(ctx, name, sql)
}

func (tx *pgPipelinedTx) Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error) {
	if tx.closed {
		return pgconn.CommandTag{}, pgx.ErrTxClosed
	}
	return tx.conn.Exec(ctx, sql, arguments...)
}

func (tx *pgPipelinedTx) Query(ctx context.Context, sql string, arguments ...any) (pgx.Rows, error) {
	if tx.closed {
		return nil, pgx.ErrTxClosed
	}
	return tx.conn.Query(ctx, sql, arguments...)
}

func (tx *pgPipelinedTx) QueryRow(ctx context.Context, sql string, arguments ...any) pgx.Row {
	return tx.conn.QueryRow(ctx, sql, arguments...)
}

func (tx *pgPipelinedTx) Conn() *pgx.Conn { return tx.conn }
