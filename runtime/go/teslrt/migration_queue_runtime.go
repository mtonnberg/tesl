package teslrt

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Private format-4 binding. No production opener publishes this yet: its
// installation and upgrade protocol must pass the generated-app gate first.
// A checked source declaration alone is not permission to use durable jobs.
type pgQueueRuntime struct {
	database *Database
	history  PgCompiledMigrationHistory
}

type pgQueueClient struct {
	db      *PostgresDB
	binding *pgQueueBinding
	backend *pgQueueBackend
}

// Prepare an isolated pool whose every physical connection verifies login,
// database identity, the complete catalog and immutable source inventory. No
// caller can bind the result before the first verified connection succeeds.
// Production openers still refuse format4; this constructor is private.
func pgOpenQueueCandidateRuntime(ctx context.Context, database *Database, config *pgxpool.Config, admission *pgMigrationAdmission) (*PostgresDB, error) {
	if database == nil || config == nil || admission == nil {
		return nil, fmt.Errorf("queue: missing admitted database binding")
	}
	database.mutex.RLock()
	closed := database.applicationPreflightClosed && database.migrationFacilitiesClosed
	history := database.migrationHistory
	database.mutex.RUnlock()
	if !closed || history == nil || history.Namespace != database.Config.Schema || history.CurrentVersion != admission.version {
		return nil, fmt.Errorf("queue: incomplete or mismatched application registration")
	}
	// Replacing an existing validation hook could silently weaken another
	// protocol's guard. Callers provide a fresh pool configuration instead.
	if config.AfterConnect != nil {
		return nil, fmt.Errorf("queue: pool configuration already has a connection verifier")
	}
	protocol := *admission
	db := &PostgresDB{schema: history.Namespace, migration: &protocol, queueRuntime: &pgQueueRuntime{database: database, history: *history}}
	configured := config.Copy()
	configured.ConnConfig.OnNotification = nil
	configured.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted, AccessMode: pgx.ReadOnly})
		if err != nil {
			return err
		}
		defer func() {
			cleanup, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
			defer cancel()
			_ = tx.Rollback(cleanup)
		}()
		if err := pgVerifyQueueCandidateConnection(ctx, tx, db, db.queueRuntime); err != nil {
			return err
		}
		return tx.Commit(ctx)
	}
	pool, err := pgxpool.NewWithConfig(ctx, configured)
	if err != nil {
		return nil, err
	}
	db.pool = pool
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return db, nil
}

// Resolve once at each operation boundary. A lease goroutine retains the
// returned client, never resolving a different process-global database later.
func (backend *pgQueueBackend) protectedQueue() *pgQueueClient {
	db := backend.connection()
	runtime := db.queueRuntime
	if runtime == nil {
		return nil
	}
	backend.codecsMutex.RLock()
	binding, closed := backend.queueSchema, backend.queueCodecsClosed
	backend.codecsMutex.RUnlock()
	if runtime.database != backend.database || db.migration == nil || binding == nil || !closed ||
		binding.history != runtime.history || binding.version != db.migration.version ||
		binding.history.Namespace != db.schema || backend.maxAttempts < 1 || backend.maxAttempts > 2147483647 || len(binding.codecs) != len(binding.contract.Payloads) {
		panic("queue: protected database has no matching closed queue binding")
	}
	return &pgQueueClient{db: db, binding: binding, backend: backend}
}

func (client *pgQueueClient) sql(function string, parameters string) string {
	return "select " + pgx.Identifier{client.db.schema, "tesl_queue_" + function}.Sanitize() + "(" + parameters + ")"
}
func (client *pgQueueClient) args(rest ...any) []any {
	return append([]any{client.binding.version, client.binding.contract.Queue}, rest...)
}
func (client *pgQueueClient) boolean(function, parameters string, args []any) bool {
	rows := PgWriteQuery(client.db, client.sql(function, parameters), args, pgx.RowTo[bool])
	if len(rows) != 1 {
		panic("queue: protected operation returned no ownership result")
	}
	return rows[0]
}
func (client *pgQueueClient) enqueue(payload any) string {
	legacyName, encoded := client.backend.encodePayload(payload)
	var identity string
	for job, codec := range client.binding.codecs {
		if codec.LegacyTypeName == legacyName {
			identity = job
			break
		}
	}
	if identity == "" {
		panic("queue: encoded payload has no checked job identity")
	}
	id := UUIDv7()
	rows := PgWriteQuery(client.db, client.sql("enqueue", "$1,$2,$3,$4,$5::jsonb"),
		client.args(identity, id, jsonbText(encoded)), pgx.RowTo[string])
	if len(rows) != 1 || rows[0] != id {
		panic("queue: protected enqueue returned another identity")
	}
	return id
}

type pgQueueRuntimeClaim struct {
	id, job, payload  string
	version, attempts int32
	token             string
	sequence          int64
}

func pgScanQueueRuntimeClaim(row pgx.CollectableRow) (pgQueueRuntimeClaim, error) {
	var result pgQueueRuntimeClaim
	err := row.Scan(&result.id, &result.job, &result.payload, &result.version, &result.attempts, &result.token, &result.sequence)
	if err == nil {
		sequence, valid := queueClaimSequence(result.token)
		if !valid || sequence != result.sequence || result.version < 1 || result.attempts < 0 {
			err = fmt.Errorf("queue: invalid protected attempt metadata")
		}
	}
	return result, err
}
func (client *pgQueueClient) dequeue(status string) (string, any, int, string, bool) {
	for {
		// Cast only JSONB for decoding; no current-job type is asserted at SQL scan.
		statement := "select job_id,job_type,payload::text,source_version,attempts,token,attempt_seq from " +
			pgx.Identifier{client.db.schema, "tesl_queue_claim"}.Sanitize() + "($1,$2,$3,$4,$5)"
		rows := PgWriteQuery(client.db, statement, client.args(status, instanceID(), queueVisibilityTimeout().Milliseconds()), pgScanQueueRuntimeClaim)
		if len(rows) == 0 {
			return "", nil, 0, "", false
		}
		if len(rows) != 1 {
			panic("queue: protected claim returned multiple jobs")
		}
		claimed := rows[0]
		migrationBoundary("queue-claim")
		codec, exists := client.binding.codecs[claimed.job]
		if !exists {
			panic("queue: claimed payload has no current checked codec")
		}
		payload, err := client.backend.decodePayload(codec.LegacyTypeName, claimed.payload)
		if err != nil {
			if client.boolean("quarantine", "$1,$2,$3,$4,$5", client.args(claimed.id, claimed.token, claimed.sequence)) {
				fmt.Fprintf(os.Stderr, "tesl: queue %s: job %s (job_type %s) cannot be decoded and was quarantined in the dead letter: %v\n", client.backend.name, claimed.id, claimed.job, err)
			}
			continue
		}
		return claimed.id, payload, int(claimed.attempts), claimed.token, true
	}
}
func (client *pgQueueClient) complete(id, token string) bool {
	migrationBoundary("queue-completion-begins")
	sequence, valid := queueClaimSequence(token)
	if !valid {
		return false
	}
	return client.boolean("complete", "$1,$2,$3,$4,$5", client.args(id, token, sequence))
}
func (client *pgQueueClient) fail(id string, attempts int, token string) bool {
	sequence, valid := queueClaimSequence(token)
	if !valid {
		return false
	}
	return client.boolean("fail", "$1,$2,$3,$4,$5,$6,$7", client.args(id, token, sequence, client.backend.maxAttempts, client.backend.protectedRetryDelayMillis(attempts)))
}

// Saturate at the largest positive Go duration before multiplying. This matches
// the runtime's duration representation, including arbitrarily large declared
// retry counts/delays, without wrapping a backoff into an immediate retry.
const pgQueueMaximumMillis int64 = (1<<63 - 1) / int64(time.Millisecond)

func (backend *pgQueueBackend) protectedRetryDelayMillis(previousFailures int) int64 {
	initial := int64(backend.initialDelay)
	if initial <= 0 {
		return 0
	}
	if backend.backoff != "fixed" && backend.backoff != "linear" && backend.backoff != "exponential" {
		return 0
	}
	if initial > pgQueueMaximumMillis/1000 {
		return pgQueueMaximumMillis
	}
	initial *= 1000
	multiplier := int64(1)
	switch backend.backoff {
	case "fixed":
	case "linear":
		multiplier = int64(max(previousFailures, 0))
		if multiplier < 1<<63-1 {
			multiplier++
		}
	case "exponential":
		shift := min(max(previousFailures, 0), 63)
		if shift >= 63 {
			return pgQueueMaximumMillis
		}
		multiplier = int64(1) << shift
	default:
		return 0
	}
	if multiplier > pgQueueMaximumMillis/initial {
		return pgQueueMaximumMillis
	}
	return initial * multiplier
}
func (client *pgQueueClient) renew(ctx context.Context, id, token string, lease time.Duration) (bool, error) {
	sequence, valid := queueClaimSequence(token)
	if !valid {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(ctx, pgLeaseTimeout())
	defer cancel()
	owned, err := pgMigrationStatement(ctx, client.db, true, func(executor pgExecutor) (bool, error) {
		var result bool
		err := executor.QueryRow(ctx, client.sql("renew", "$1,$2,$3,$4,$5,$6"), client.args(id, token, sequence, lease.Milliseconds())...).Scan(&result)
		return result, err
	})
	if err == nil && owned {
		migrationBoundary("queue-renewal")
	}
	return owned, err
}
func (client *pgQueueClient) count(status string) int {
	rows := PgQuery(client.db, client.sql("count", "$1,$2,$3"), client.args(status), pgx.RowTo[int64])
	if len(rows) != 1 {
		panic("queue: protected count returned no result")
	}
	return int(rows[0])
}
func (client *pgQueueClient) deadJobs(queue *Queue) []DeadJob {
	return PgQuery(client.db, "select * from "+pgx.Identifier{client.db.schema, "tesl_queue_dead_jobs"}.Sanitize()+"($1,$2)", client.args(), func(row pgx.CollectableRow) (DeadJob, error) {
		var id, job, reason string
		var version int32
		var attempts int
		if err := row.Scan(&id, &job, &version, &attempts, &reason); err != nil {
			return DeadJob{}, err
		}
		return deadJobFromMetadata(queue, id, &job, &version, attempts, reason)
	})
}
func (client *pgQueueClient) requeue(id string) bool {
	return client.boolean("requeue", "$1,$2,$3", client.args(id))
}
