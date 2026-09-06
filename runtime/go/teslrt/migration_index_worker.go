package teslrt

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type pgIndexWorkerSettings struct {
	lease, renew, poll, query, cleanup time.Duration
}

func pgIndexWorkerConfiguration() (pgIndexWorkerSettings, error) {
	settings := pgIndexWorkerSettings{lease: 30 * time.Second, renew: 5 * time.Second,
		poll: 5 * time.Second, query: 10 * time.Second, cleanup: 5 * time.Second}
	for name, target := range map[string]*time.Duration{"TESL_LEASE_TTL_S": &settings.lease, "TESL_SCHEMA_POLL_S": &settings.poll} {
		if text := os.Getenv(name); text != "" {
			seconds, err := strconv.Atoi(text)
			if err != nil || seconds < 1 || seconds > 600 {
				return settings, fmt.Errorf("%s must be an integer from 1 through 600", name)
			}
			*target = time.Duration(seconds) * time.Second
		}
	}
	settings.renew = min(settings.renew, settings.lease/3)
	settings.query = min(settings.query, settings.lease/3)
	return settings, nil
}

type pgIndexWorkerRefusal struct{ cause error }

func (e *pgIndexWorkerRefusal) Error() string { return e.cause.Error() }
func (e *pgIndexWorkerRefusal) Unwrap() error { return e.cause }

var errPgIndexLeaseLost = errors.New("migration index ownership was lost")
var errPgIndexSessionLost = errors.New("migration index executor session was lost")

func pgIndexRefuse(format string, args ...any) error {
	return &pgIndexWorkerRefusal{fmt.Errorf(format, args...)}
}

func pgIndexInspectionFailure(err error) error {
	if pgIndexCanReconnect(err) {
		return err
	}
	return &pgIndexWorkerRefusal{err}
}

// A reconnect is recovery only for lost transport/coordination. A changed
// schema, role, identity, source contract or admission decision is a refusal.
func pgIndexCanReconnect(err error) bool {
	var refusal *pgIndexWorkerRefusal
	if errors.As(err, &refusal) {
		return false
	}
	if errors.Is(err, errPgIndexLeaseLost) || errors.Is(err, errPgIndexSessionLost) || errors.Is(err, context.DeadlineExceeded) ||
		errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, net.ErrClosed) {
		return true
	}
	var server *pgconn.PgError
	if errors.As(err, &server) {
		return strings.HasPrefix(server.Code, "08") || server.Code == "57P01" || server.Code == "57P02" || server.Code == "57P03" ||
			server.Code == "40001" || server.Code == "40P01"
	}
	var network net.Error
	return errors.As(err, &network) || pgconn.SafeToRetry(err)
}

// pgRunMigrationIndexWorker takes exclusive ownership of ddl, including closing
// it. Expansion must already be committed and its boot lock released. The caller
// passes its service context, never the short startup/pool lease context.
func pgRunMigrationIndexWorker(ctx context.Context, ddl *pgx.Conn, config *pgx.ConnConfig,
	history PgCompiledMigrationHistory, roles PgMigrationControlRoles, expected PgMigrationControlState,
	onReady func(PgMigrationControlState) error) error {
	settings, err := pgIndexWorkerConfiguration()
	if err != nil {
		return err
	}
	return pgRunMigrationIndexWorkerWithSettings(ctx, ddl, config, history, roles, expected, onReady, settings)
}

func pgRunMigrationIndexWorkerWithSettings(ctx context.Context, ddl *pgx.Conn, config *pgx.ConnConfig,
	history PgCompiledMigrationHistory, roles PgMigrationControlRoles, expected PgMigrationControlState,
	onReady func(PgMigrationControlState) error, settings pgIndexWorkerSettings) error {
	if config == nil || ddl == nil || ddl.IsClosed() || ddl.PgConn().TxStatus() != 'I' {
		return pgIndexRefuse("migration index worker requires an exclusively owned idle DDL connection")
	}
	if settings.lease < time.Millisecond || settings.lease > 600*time.Second || settings.renew <= 0 || settings.renew >= settings.lease ||
		settings.poll <= 0 || settings.query <= 0 || settings.cleanup <= 0 {
		return pgIndexRefuse("invalid migration index worker timing")
	}
	if _, err := history.ExpansionPlan(expected.InitialVersion); err != nil {
		return err
	}
	if expected.Format != 3 || expected.DatabaseUUID == "" || expected.Current < history.CurrentVersion || expected.InstallingVersion != 0 {
		return pgIndexRefuse("migration index worker requires completed expansion under control format 3")
	}
	announced := false
	for {
		tag := "tesl-exec:" + UUIDv7()
		generation := config.Copy()
		generation.RuntimeParams["application_name"] = tag
		var coordinator *pgx.Conn
		var roundErr error
		if ddl == nil {
			connect, cancel := context.WithTimeout(ctx, settings.query)
			ddl, roundErr = pgx.ConnectConfig(connect, generation.Copy())
			cancel()
		}
		if roundErr == nil {
			setup, cancel := context.WithTimeout(ctx, settings.query)
			roundErr = pgIndexPrepareSession(setup, ddl, tag, history, roles, expected)
			cancel()
		}
		if roundErr == nil {
			roundErr = pgMigrationSessionLock(ctx, ddl, expected.FenceNamespace, history.CurrentVersion, false, func() error {
				admit, cancel := context.WithTimeout(ctx, settings.query)
				var floor int
				err := ddl.QueryRow(admit, "select "+pgx.Identifier{history.Namespace, "tesl_admit"}.Sanitize()+"($1)", history.CurrentVersion).Scan(&floor)
				cancel()
				if err != nil {
					return err
				}
				migrationBoundary("index-worker-admitted")
				connect, stop := context.WithTimeout(ctx, settings.query)
				coordinator, err = pgx.ConnectConfig(connect, generation.Copy())
				if err == nil {
					err = pgIndexPrepareSession(connect, coordinator, tag, history, roles, expected)
				}
				stop()
				if err != nil {
					return err
				}
				return pgIndexWorkerRound(ctx, ddl, coordinator, tag, history, roles, expected, onReady, &announced, settings)
			})
		}
		// The round joins its DDL actor before returning. No pgx connection is
		// closed or reused while another goroutine owns an operation on it.
		if ddl != nil && ddl.IsClosed() || coordinator != nil && coordinator.IsClosed() {
			roundErr = errors.Join(roundErr, errPgIndexSessionLost)
		}
		closeCtx, closeCancel := context.WithTimeout(context.Background(), settings.cleanup)
		if ddl != nil {
			_ = ddl.Close(closeCtx)
		}
		if coordinator != nil {
			_ = coordinator.Close(closeCtx)
		}
		closeCancel()
		ddl = nil
		cleanupErr := pgIndexRemoveTaggedSessions(generation, history, roles, expected, tag, settings.cleanup)
		if ctx.Err() != nil {
			return cleanupErr
		}
		if !pgIndexCanReconnect(roundErr) {
			return errors.Join(roundErr, cleanupErr)
		}
		// Never reopen a replacement executor until the old tagged backend set
		// is observed empty. A cancellation acknowledgement is not that proof.
		for cleanupErr != nil {
			if err := pgIndexWait(ctx, settings.poll); err != nil {
				return errors.Join(err, cleanupErr)
			}
			cleanupErr = pgIndexRemoveTaggedSessions(generation, history, roles, expected, tag, settings.cleanup)
		}
		if err := pgIndexWait(ctx, settings.poll); err != nil {
			return nil
		}
	}
}

func pgIndexPrepareSession(ctx context.Context, conn *pgx.Conn, tag string, history PgCompiledMigrationHistory,
	roles PgMigrationControlRoles, expected PgMigrationControlState) error {
	var current, session, uuid, domain string
	var format, fence, protocol int
	if err := conn.QueryRow(ctx, "select current_user,session_user,database_uuid::text,format_version,fence_ns,fence_domain,retirement_protocol_floor from "+
		pgx.Identifier{history.Namespace, "tesl_schema_meta"}.Sanitize()+" where id=1").
		Scan(&current, &session, &uuid, &format, &fence, &domain, &protocol); err != nil {
		return err
	}
	if current != roles.Worker || session != roles.Worker || uuid != expected.DatabaseUUID || format != 3 ||
		fence != expected.FenceNamespace || domain != expected.FenceDomain || protocol != 1 {
		return pgIndexRefuse("migration index executor identity, format, fence or worker login differs")
	}
	_, err := conn.Exec(ctx, `select pg_catalog.set_config('application_name',$1,false);
 set search_path=''; set statement_timeout=0; set lock_timeout=0;
 set tcp_keepalives_idle=10; set tcp_keepalives_interval=5; set tcp_keepalives_count=3`, pgx.QueryExecModeSimpleProtocol, tag)
	return err
}

type pgIndexWorkerSnapshot struct {
	state PgMigrationControlState
	jobs  []pgMigrationIndexJob
	ready bool
}

func pgIndexSnapshot(ctx context.Context, conn *pgx.Conn, history PgCompiledMigrationHistory,
	roles PgMigrationControlRoles, expected PgMigrationControlState) (snapshot pgIndexWorkerSnapshot, err error) {
	err = pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles, false); err != nil {
			return pgIndexInspectionFailure(err)
		}
		var err error
		snapshot.state, err = pgInspectControlReadOnly(ctx, tx, history.Namespace, roles)
		if err != nil {
			return err
		}
		state := snapshot.state
		if state.Format != 3 || state.DatabaseUUID != expected.DatabaseUUID || state.FenceNamespace != expected.FenceNamespace ||
			state.FenceDomain != expected.FenceDomain || state.Current < history.CurrentVersion || state.MinVersion > history.CurrentVersion {
			return pgIndexRefuse("migration index executor installation identity or admission changed")
		}
		plan, err := history.ExpansionPlan(state.InitialVersion)
		if err != nil {
			return &pgIndexWorkerRefusal{err}
		}
		intents, err := pgReadExpansionIntents(ctx, tx, history.Namespace)
		if err != nil {
			return err
		}
		if err := pgVerifyExpansionObservation(state, plan, intents); err != nil {
			return &pgIndexWorkerRefusal{err}
		}
		snapshot.jobs, err = pgReadMigrationIndexJobs(ctx, tx, history.Namespace, intents)
		if err != nil {
			return err
		}
		if err := pgVerifyMigrationIndexJobs(plan, intents, snapshot.jobs, true); err != nil {
			return &pgIndexWorkerRefusal{err}
		}
		catalog, err := pgExpansionRecordedCatalog(plan, intents)
		if err != nil {
			return &pgIndexWorkerRefusal{err}
		}
		report, ready, err := pgInspectMigrationCatalogWithIndexJobsInTx(ctx, tx, history.Namespace, roles.Worker, catalog, snapshot.jobs, history.CurrentVersion)
		if err != nil {
			return err
		}
		if len(report.Missing) != 0 || len(report.Drift) != 0 {
			return pgIndexRefuse("migration index catalog differs: %v %v", report.Missing, report.Drift)
		}
		if err := pgVerifyRequestGrants(ctx, tx, history.Namespace, roles, catalog); err != nil {
			return pgIndexInspectionFailure(err)
		}
		snapshot.ready = ready
		return nil
	})
	return snapshot, err
}

func pgIndexWorkerRound(ctx context.Context, ddl, coordinator *pgx.Conn, tag string, history PgCompiledMigrationHistory,
	roles PgMigrationControlRoles, expected PgMigrationControlState, onReady func(PgMigrationControlState) error,
	announced *bool, settings pgIndexWorkerSettings) (resultErr error) {
	poll := time.NewTicker(settings.poll)
	renew := time.NewTicker(settings.renew)
	defer poll.Stop()
	defer renew.Stop()
	var active *pgMigrationIndexJob
	var finished chan error
	var stopJob context.CancelFunc
	defer func() {
		if stopJob != nil {
			stopJob()
		}
		if finished != nil {
			// net.Conn.Close is safe during I/O; pgx.Conn.Close is not. Interrupt
			// the transport, then join its exclusive actor before touching pgx.
			_ = ddl.PgConn().Conn().Close()
			<-finished
		}
	}()
	refresh := func(dispatch bool) error {
		query, cancel := context.WithTimeout(ctx, settings.query)
		defer cancel()
		var ddlAlive bool
		if err := coordinator.QueryRow(query, `select exists(select 1 from pg_catalog.pg_stat_activity
 where pid=$1 and datname=pg_catalog.current_database() and usename=$2 and application_name=$3)`,
			ddl.PgConn().PID(), roles.Worker, tag).Scan(&ddlAlive); err != nil {
			return err
		}
		if !ddlAlive {
			return errPgIndexSessionLost
		}
		snapshot, err := pgIndexSnapshot(query, coordinator, history, roles, expected)
		if err != nil {
			return err
		}
		if _, err := coordinator.Exec(query, "select "+pgx.Identifier{history.Namespace, "tesl_heartbeat"}.Sanitize()+"($1,1,$2)",
			history.CurrentVersion, snapshot.state.CompatFloor); err != nil {
			return err
		}
		if snapshot.ready && !*announced {
			if onReady != nil {
				if err := onReady(snapshot.state); err != nil {
					return &pgIndexWorkerRefusal{err}
				}
			}
			*announced = true
		}
		if active != nil {
			found := false
			for _, live := range snapshot.jobs {
				if live.ID == active.ID {
					found = true
					if live.Holder != tag || live.Token != active.Token {
						return errPgIndexLeaseLost
					}
					active.Attempts = live.Attempts
					active.State = live.State
				}
			}
			if !found {
				return pgIndexRefuse("active index job disappeared")
			}
			return pgIndexPublishProgress(query, coordinator, history, *active, ddl.PgConn().PID(), tag)
		}
		if !dispatch {
			return nil
		}
		for _, job := range snapshot.jobs {
			if job.Version > history.CurrentVersion || job.State == "valid" {
				continue
			}
			if job.Holder != "" && job.Holder != tag && job.ExpiresAt != nil {
				if err := pgIndexReapExpiredHolder(query, coordinator, history, roles, job); err != nil {
					return err
				}
				var survives bool
				if err := coordinator.QueryRow(query, `select exists(select 1 from pg_catalog.pg_stat_activity
 where datname=pg_catalog.current_database() and application_name=$1)`, job.Holder).Scan(&survives); err != nil {
					return err
				}
				if survives {
					continue
				}
			}
			var token int64
			if err := coordinator.QueryRow(query, "select "+pgx.Identifier{history.Namespace, "tesl_claim_index"}.Sanitize()+"($1,$2,$3,$4)",
				job.ID, history.CurrentVersion, history.SourceCompilerABI, settings.lease.Milliseconds()).Scan(&token); err != nil {
				return err
			}
			if token == 0 {
				continue
			}
			job.Token, job.Holder = token, tag
			active = &job
			jobContext, cancelJob := context.WithCancel(ctx)
			stopJob = cancelJob
			finished = make(chan error, 1)
			completion := finished
			go func(job pgMigrationIndexJob) {
				defer cancelJob()
				completion <- pgIndexExecuteJob(jobContext, ddl, tag, history, roles, expected, job, settings)
			}(job)
			return nil
		}
		return nil
	}
	if err := refresh(true); err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-finished:
			finished = nil
			stopJob()
			stopJob = nil
			if err != nil {
				return err
			}
			query, cancel := context.WithTimeout(ctx, settings.query)
			var released bool
			err = coordinator.QueryRow(query, "select "+pgx.Identifier{history.Namespace, "tesl_release_index"}.Sanitize()+"($1,$2)", active.ID, active.Token).Scan(&released)
			cancel()
			if err != nil {
				return err
			}
			if !released {
				return errPgIndexLeaseLost
			}
			active = nil
			if err := refresh(false); err != nil {
				return err
			}
		case <-renew.C:
			if active == nil || active.State == "valid" {
				continue
			}
			query, cancel := context.WithTimeout(ctx, settings.query)
			err := pgIndexRenew(query, coordinator, history.Namespace, active.ID, active.Token, settings.lease)
			if errors.Is(err, errPgIndexLeaseLost) {
				// A successful actor commits valid before returning/unlocking.
				// Its immutable result needs no renewal while that actor joins.
				// Only a fully verified snapshot with this exact holder/token
				// establishes that case; every other false result loses ownership.
				snapshot, inspectErr := pgIndexSnapshot(query, coordinator, history, roles, expected)
				if inspectErr != nil {
					err = inspectErr
				} else {
					for _, live := range snapshot.jobs {
						if live.ID == active.ID && live.State == "valid" && live.Holder == tag && live.Token == active.Token {
							active.State, active.Attempts = live.State, live.Attempts
							err = nil
						}
					}
				}
			}
			cancel()
			if err != nil {
				return err
			}
		case <-poll.C:
			if err := refresh(true); err != nil {
				return err
			}
		}
	}
}

// The protected function retains job/lease row locks in this transaction. A
// holder that renewed before the locks were acquired cannot be signalled; a
// holder that tries to renew afterward waits until the signal transaction ends.
// Signalling is still not proof of death: claim independently refuses every
// surviving backend with the old full tag, and the caller polls until it can
// actually obtain a new token.
func pgIndexReapExpiredHolder(ctx context.Context, conn *pgx.Conn, history PgCompiledMigrationHistory,
	roles PgMigrationControlRoles, job pgMigrationIndexJob) error {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var expired bool
	if err := tx.QueryRow(ctx, "select "+pgx.Identifier{history.Namespace, "tesl_lock_expired_index_holder"}.Sanitize()+"($1,$2,$3,$4,$5)",
		job.ID, job.Holder, job.Token, history.CurrentVersion, history.SourceCompilerABI).Scan(&expired); err != nil {
		return err
	}
	if expired {
		if _, err := tx.Exec(ctx, `select pg_catalog.pg_terminate_backend(pid) from pg_catalog.pg_stat_activity
 where datname=pg_catalog.current_database() and usename=$1 and application_name=$2 and pid<>pg_catalog.pg_backend_pid()`, roles.Worker, job.Holder); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func pgIndexRenew(ctx context.Context, conn *pgx.Conn, namespace, id string, token int64, lease time.Duration) error {
	var owned bool
	if err := conn.QueryRow(ctx, "select "+pgx.Identifier{namespace, "tesl_renew_index"}.Sanitize()+"($1,$2,$3)", id, token, lease.Milliseconds()).Scan(&owned); err != nil {
		return err
	}
	if !owned {
		return errPgIndexLeaseLost
	}
	return nil
}

func pgIndexRecord(ctx context.Context, conn *pgx.Conn, namespace string, job pgMigrationIndexJob, state string, detail *string) error {
	var owned bool
	if err := conn.QueryRow(ctx, "select "+pgx.Identifier{namespace, "tesl_record_index_state"}.Sanitize()+"($1,$2,$3,$4)",
		job.ID, job.Token, state, detail).Scan(&owned); err != nil {
		return err
	}
	if !owned {
		return errPgIndexLeaseLost
	}
	return nil
}

// The one-argument bigint lock domain is disjoint from PostgreSQL's two-int
// schema-version locks. Length framing is fixed UTF-8 bytes, not concatenation;
// collisions only serialize unrelated jobs, never grant authority to one.
func pgMigrationDDLJobKey(uuid, id string) int64 {
	var framed []byte
	for _, value := range []string{uuid, "tesl-ddl-job", id} {
		length := int64(len(value))
		if length > 1<<32-1 {
			panic("migration DDL job identity exceeds its four-byte length frame")
		}
		framed = binary.BigEndian.AppendUint32(framed, uint32(length))
		framed = append(framed, value...)
	}
	digest := sha256.Sum256(framed)
	// #nosec G115 -- PostgreSQL bigint uses the same 64-bit pattern as a signed
	// value. This conversion intentionally preserves every SHA-256 prefix bit;
	// the positive and negative wire vectors pin that lock identity.
	return int64(binary.BigEndian.Uint64(digest[:8]))
}

func pgIndexJobLock(ctx context.Context, conn *pgx.Conn, key int64, run func() error) (resultErr error) {
	if conn == nil || conn.IsClosed() || conn.PgConn().TxStatus() != 'I' {
		return pgIndexRefuse("concurrent index DDL requires an idle session-fenced connection")
	}
	if _, err := conn.Exec(ctx, "select pg_catalog.pg_advisory_lock_shared($1::bigint)", key); err != nil {
		// Acquisition can succeed before the client learns that it was cancelled.
		_ = conn.PgConn().Conn().Close()
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var unlocked bool
		err := conn.QueryRow(cleanup, "select pg_catalog.pg_advisory_unlock_shared($1::bigint)", key).Scan(&unlocked)
		if err != nil || !unlocked {
			if err == nil {
				err = errPgIndexLeaseLost
			}
			_ = conn.PgConn().Conn().Close()
			resultErr = errors.Join(resultErr, err)
		}
	}()
	return run()
}

type pgIndexObservation struct {
	present, valid, active bool
}

// Observe progress before taking a new catalog snapshot. A repeatable-read
// snapshot captured while a build ran must not classify its committed result
// using an old INVALID flag after live progress has already disappeared.
func pgIndexObserve(ctx context.Context, conn *pgx.Conn, namespace, owner string, job pgMigrationIndexJob) (observation pgIndexObservation, err error) {
	tableName := pgx.Identifier{namespace, job.Table}.Sanitize()
	indexName := pgx.Identifier{namespace, job.Index.Name}.Sanitize()
	err = conn.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_stat_progress_create_index
 where datid=(select oid from pg_catalog.pg_database where datname=pg_catalog.current_database())
 and relid=pg_catalog.to_regclass($1))`, tableName).Scan(&observation.active)
	if err != nil {
		return observation, err
	}
	err = pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		actual, err := pgReadMigrationTable(ctx, tx, namespace, job.Table)
		if err != nil {
			return err
		}
		if actual == nil || actual.Owner != owner || actual.Kind != "r" || actual.Partition || actual.Inherits {
			return pgIndexRefuse("index job's owned ordinary table is absent or changed")
		}
		var relation bool
		if err := tx.QueryRow(ctx, "select pg_catalog.to_regclass($1) is not null", indexName).Scan(&relation); err != nil {
			return err
		}
		position := slices.IndexFunc(actual.Indexes, func(index pgCatalogIndex) bool { return index.Name == job.Index.Name })
		if position < 0 {
			if relation {
				return pgIndexRefuse("index job name belongs to a different relation")
			}
			return nil
		}
		metadata, err := pgReadCatalogExpectations(ctx, tx)
		if err != nil {
			return err
		}
		shape, err := metadata.index(job.Index.Name, actual, job.Index.Columns, false, job.Index.Unique, false)
		if err != nil {
			return &pgIndexWorkerRefusal{err}
		}
		index := actual.Indexes[position]
		if !pgEquivalentMigrationIndex(actual, actual, index, shape) {
			return pgIndexRefuse("index job's physical shape differs from its protected descriptor")
		}
		observation.present = true
		observation.valid = index.Valid && index.Ready && index.Live
		return nil
	})
	return observation, err
}

func pgIndexOwnedSnapshot(ctx context.Context, conn *pgx.Conn, tag string, history PgCompiledMigrationHistory,
	roles PgMigrationControlRoles, expected PgMigrationControlState, job pgMigrationIndexJob, settings pgIndexWorkerSettings) error {
	query, cancel := context.WithTimeout(ctx, settings.query)
	defer cancel()
	// This locks the lease row while checking its current token. A plain SELECT
	// could see the old token while a successor's claim was still uncommitted.
	if err := pgIndexRenew(query, conn, history.Namespace, job.ID, job.Token, settings.lease); err != nil {
		return err
	}
	snapshot, err := pgIndexSnapshot(query, conn, history, roles, expected)
	if err != nil {
		return err
	}
	for _, live := range snapshot.jobs {
		if live.ID != job.ID {
			continue
		}
		if live.Holder != tag || live.Token != job.Token || live.State == "valid" || live.State == "terminal" {
			return errPgIndexLeaseLost
		}
		if live.SourceABI != history.SourceCompilerABI || live.Version != job.Version || live.Ordinal != job.Ordinal ||
			live.Table != job.Table || live.Index.Name != job.Index.Name || live.Index.Unique != job.Index.Unique || !slices.Equal(live.Index.Columns, job.Index.Columns) {
			return pgIndexRefuse("index job identity or compiler ABI changed before DDL")
		}
		return nil
	}
	return pgIndexRefuse("owned index job disappeared")
}

func pgIndexExecuteJob(ctx context.Context, conn *pgx.Conn, tag string, history PgCompiledMigrationHistory,
	roles PgMigrationControlRoles, expected PgMigrationControlState, job pgMigrationIndexJob, settings pgIndexWorkerSettings) error {
	return pgIndexJobLock(ctx, conn, pgMigrationDDLJobKey(expected.DatabaseUUID, job.ID), func() error {
		migrationBoundary("index-job-lock")
		if err := pgIndexOwnedSnapshot(ctx, conn, tag, history, roles, expected, job, settings); err != nil {
			return err
		}
		observation, err := pgIndexObserve(ctx, conn, history.Namespace, roles.Worker, job)
		if err != nil {
			return err
		}
		if observation.valid {
			return pgIndexRecord(ctx, conn, history.Namespace, job, "valid", nil)
		}
		if observation.active {
			return nil // Active server work is never interpreted as a dead remnant.
		}
		if observation.present {
			complete, err := pgIndexCleanInvalid(ctx, conn, tag, history, roles, expected, job, settings)
			if err != nil || complete {
				return err
			}
			// Cleanup can defer to active work. Observe again before deciding
			// whether the relation is truly absent and a build may begin.
			observation, err = pgIndexObserve(ctx, conn, history.Namespace, roles.Worker, job)
			if err != nil || observation.active || observation.present {
				return err
			}
		}
		if err := pgIndexOwnedSnapshot(ctx, conn, tag, history, roles, expected, job, settings); err != nil {
			return err
		}
		if err := pgIndexRecord(ctx, conn, history.Namespace, job, "building", nil); err != nil {
			return err
		}
		migrationBoundary("index-before-create")
		if err := pgIndexOwnedSnapshot(ctx, conn, tag, history, roles, expected, job, settings); err != nil {
			return err
		}
		keys := make([]string, len(job.Index.Columns))
		for i, key := range job.Index.Columns {
			keys[i] = quoteIdentifier(key)
		}
		unique := ""
		if job.Index.Unique {
			unique = "unique "
		}
		statement := "create " + unique + "index concurrently " + quoteIdentifier(job.Index.Name) + " on " +
			pgx.Identifier{history.Namespace, job.Table}.Sanitize() + " using btree (" + strings.Join(keys, ",") + ")"
		if _, err := conn.Exec(ctx, statement); err != nil {
			if ctx.Err() != nil || conn.IsClosed() || pgIndexCanReconnect(err) {
				return err // An ambiguous outcome never becomes a failed/complete claim.
			}
			if err := pgIndexRecordFailure(ctx, conn, history.Namespace, job, err); err != nil {
				return err
			}
			_, err := pgIndexCleanInvalid(ctx, conn, tag, history, roles, expected, job, settings)
			return err
		}
		migrationBoundary("index-after-create")
		observation, err = pgIndexObserve(ctx, conn, history.Namespace, roles.Worker, job)
		if err != nil {
			return err
		}
		if !observation.valid {
			return pgIndexRefuse("concurrent index statement finished without its exact valid, ready and live result")
		}
		migrationBoundary("index-before-valid")
		if err := pgIndexRecord(ctx, conn, history.Namespace, job, "valid", nil); err != nil {
			return err
		}
		migrationBoundary("index-after-valid")
		return nil
	})
}

func pgIndexCleanInvalid(ctx context.Context, conn *pgx.Conn, tag string, history PgCompiledMigrationHistory,
	roles PgMigrationControlRoles, expected PgMigrationControlState, job pgMigrationIndexJob, settings pgIndexWorkerSettings) (bool, error) {
	if err := pgIndexOwnedSnapshot(ctx, conn, tag, history, roles, expected, job, settings); err != nil {
		return false, err
	}
	observation, err := pgIndexObserve(ctx, conn, history.Namespace, roles.Worker, job)
	if err != nil {
		return false, err
	}
	if observation.valid {
		return true, pgIndexRecord(ctx, conn, history.Namespace, job, "valid", nil)
	}
	if observation.active || !observation.present {
		return false, nil
	}
	migrationBoundary("index-before-cleanup")
	// The failpoint can model a paused holder. Repeat both the locked token
	// barrier and fresh server observation after it, immediately before DROP.
	if err := pgIndexOwnedSnapshot(ctx, conn, tag, history, roles, expected, job, settings); err != nil {
		return false, err
	}
	observation, err = pgIndexObserve(ctx, conn, history.Namespace, roles.Worker, job)
	if err != nil {
		return false, err
	}
	if observation.valid {
		return true, pgIndexRecord(ctx, conn, history.Namespace, job, "valid", nil)
	}
	if observation.active || !observation.present {
		return false, nil
	}
	if _, err := conn.Exec(ctx, "drop index concurrently "+pgx.Identifier{history.Namespace, job.Index.Name}.Sanitize()); err != nil {
		if ctx.Err() != nil || conn.IsClosed() || pgIndexCanReconnect(err) {
			return false, err
		}
		return false, pgIndexRecordFailure(ctx, conn, history.Namespace, job, err)
	}
	migrationBoundary("index-after-cleanup")
	return false, nil
}

func pgIndexRecordFailure(ctx context.Context, conn *pgx.Conn, namespace string, job pgMigrationIndexJob, failure error) error {
	var server *pgconn.PgError
	if !errors.As(failure, &server) {
		return failure // Only an actual server SQL error establishes a failed attempt.
	}
	detail := server.Code + ": " + server.Message
	if server.Detail != "" {
		detail += "; " + server.Detail
	}
	if len(detail) > 8192 {
		detail = detail[:8192]
		for !utf8.ValidString(detail) {
			detail = detail[:len(detail)-1]
		}
	}
	return pgIndexRecord(ctx, conn, namespace, job, "failed", &detail)
}

func pgIndexPublishProgress(ctx context.Context, conn *pgx.Conn, history PgCompiledMigrationHistory, job pgMigrationIndexJob, pid uint32, tag string) error {
	var blocks, total, tuples int64
	err := conn.QueryRow(ctx, `select blocks_done,blocks_total,tuples_done from pg_catalog.pg_stat_progress_create_index
 where pid=$1 and datid=(select oid from pg_catalog.pg_database where datname=pg_catalog.current_database())`, pid).Scan(&blocks, &total, &tuples)
	if errors.Is(err, pgx.ErrNoRows) {
		blocks, total, tuples = 0, 0, 0
	} else if err != nil {
		return err
	}
	attributes := []Tuple2[string, string]{{Tuple2First: "database", Tuple2Second: history.Database},
		{Tuple2First: "version", Tuple2Second: strconv.Itoa(job.Version)}, {Tuple2First: "entity", Tuple2Second: job.Table},
		{Tuple2First: "index", Tuple2Second: job.Index.Name}, {Tuple2First: "instance", Tuple2Second: tag}}
	for name, value := range map[string]int64{"blocks_done": blocks, "blocks_total": total, "tuples_done": tuples} {
		Gauge("tesl_schema_index_build_progress", float64(value), append(slices.Clone(attributes), Tuple2[string, string]{Tuple2First: "measure", Tuple2Second: name}))
	}
	Gauge("tesl_schema_index_attempts", float64(job.Attempts), attributes)
	return nil
}

// Owned transports have already been closed and their actors joined. A separate
// bounded cleanup connection confirms that no old executor statement or fence
// survives before a replacement generation may claim work. It never signals a
// backend in another database or under another login.
func pgIndexRemoveTaggedSessions(config *pgx.ConnConfig, history PgCompiledMigrationHistory, roles PgMigrationControlRoles,
	expected PgMigrationControlState, tag string, budget time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), budget)
	defer cancel()
	conn, err := pgx.ConnectConfig(ctx, config.Copy())
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close(ctx) }()
	if err := pgIndexPrepareSession(ctx, conn, tag, history, roles, expected); err != nil {
		return err
	}
	for {
		var remaining int
		if err := conn.QueryRow(ctx, `select count(*) from pg_catalog.pg_stat_activity where datname=pg_catalog.current_database()
 and usename=$1 and application_name=$2 and pid<>pg_catalog.pg_backend_pid()`, roles.Worker, tag).Scan(&remaining); err != nil {
			return err
		}
		if remaining == 0 {
			return conn.Close(ctx) // The cleanup backend is the last member of this tag.
		}
		if _, err := conn.Exec(ctx, `select pg_catalog.pg_terminate_backend(pid) from pg_catalog.pg_stat_activity
 where datname=pg_catalog.current_database() and usename=$1 and application_name=$2 and pid<>pg_catalog.pg_backend_pid()`, roles.Worker, tag); err != nil {
			return err
		}
		if err := pgIndexWait(ctx, 10*time.Millisecond); err != nil {
			return fmt.Errorf("old migration executor backends did not disappear: %w", err)
		}
	}
}

func pgIndexWait(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
