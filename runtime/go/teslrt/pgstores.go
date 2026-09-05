package teslrt

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The DURABLE stores: a queue, an email outbox and a cache declared on a Postgres-backed
// database keep their state in that database rather than in process memory, so several
// instances of one program work off one job table, a restart loses no job and no unsent
// mail, and `enqueue` / `Email.send` inside `transaction { … }` commit or roll back with the
// surrounding writes.
//
// WHICH PROGRAMS GET THIS FILE. Only one that declares a Postgres-backed database — the
// emitter gates it with postgres.go, database.go and dbquery.go — so everything that names
// `*Database`, `*PostgresDB` or the driver lives HERE. queue.go, email.go and cache.go ship
// with every program and see only the small package-private interfaces they declare
// (`queueBackend`, `outboxBackend`, `cacheBackend`), which the three stores below implement.
//
// WHEN THE STORE IS USED. A backend is ACTIVE while its database is bound (`with database D`,
// which `main`'s App does for a served program). Off a binding every operation falls through
// to the in-memory store the always-shipped file already has, which is what lets a `test`
// block exercise a durable queue with no server anywhere — the same dispatch dbquery.go
// performs for an entity's rows.
//
// THE TABLES ARE THE RACKET RUNTIME'S in name and meaning (`tesl_jobs`, `tesl_email_outbox`,
// `tesl_cache`; `for update skip locked` claims; `next_attempt_at` backoff), created lazily
// with `if not exists` the first time a store touches them, in the database's schema.
//
// EVERY STATEMENT RUNS THROUGH THE EXECUTOR (PgExec / PgQuery / PgCount), so one issued on a
// goroutine with an open transaction joins it. That is the whole of the atomicity story: an
// `enqueue` in a rolled-back handler leaves no row because the insert WAS the transaction's.
// The table bootstrap is the one exception — it runs on the pool, because a `create table`
// that rolled back with a failing body would leave the once-flag set and the table absent.

// ── Shared plumbing ───────────────────────────────────────────────────────────

// pgStore is what the three backends share: the database whose binding decides whether
// they are active, and the table bootstrap.
type pgStore struct {
	database *Database
}

func (store pgStore) active() bool {
	return store.database.bound() != nil
}

// connection is the bound connection, for a call that has already passed `active()`. The
// binding cannot go away between the two under the runtime's own use (a served program binds
// once, in `main`), so an unbound answer here is a programming error rather than a state.
func (store pgStore) connection() *PostgresDB {
	db := store.database.bound()
	if db == nil {
		panic("database " + store.database.Name + " is not bound — a durable store was used outside `with database`")
	}
	return db
}

// pgTableKey identifies one table on one pool: the bootstrap runs once per key.
type pgTableKey struct {
	db    *PostgresDB
	table string
}

// pgTableOnce is a sync.Once that a PANIC does not complete: a bootstrap the server refused
// (it was down, the lease ran out) is retried by the next call rather than remembered as done
// with no table behind it.
type pgTableOnce struct {
	mutex sync.Mutex
	done  bool
}

var pgTablesReady sync.Map // pgTableKey -> *pgTableOnce

// ensureTable creates `table` (and whatever `statements` adds around it — an index) if it is
// absent, once per pool. Two instances starting together both run `create … if not exists`,
// and PostgreSQL still reports a duplicate from one of them when the race is tight enough
// (the catalog's unique index wins where the `if not exists` check lost), so a duplicate-
// object error is the OTHER instance's success and is tolerated.
func ensureTable(db *PostgresDB, table string, statements func(qualified string) []string) {
	key := pgTableKey{db: db, table: table}
	loaded, _ := pgTablesReady.LoadOrStore(key, &pgTableOnce{})
	once, ok := loaded.(*pgTableOnce)
	if !ok {
		panic("database: table bootstrap registry holds an unexpected value")
	}
	once.mutex.Lock()
	defer once.mutex.Unlock()
	if once.done {
		return
	}
	for _, statement := range statements(db.QualifiedTable(table)) {
		ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
		_, err := db.pool.Exec(ctx, statement)
		cancel()
		if err != nil && !pgDuplicateObject(err) {
			panic("database: cannot create " + table + ": " + err.Error())
		}
	}
	once.done = true
}

// pgDuplicateObject reports the SQLSTATEs a concurrent `create … if not exists` can raise:
// duplicate_table, duplicate_object, duplicate_schema, and the unique_violation on the
// catalog itself that a tight race produces.
func pgDuplicateObject(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	switch pgErr.Code {
	case "42P07", "42710", "42701", "42P06", "23505":
		return true
	}
	return false
}

// instanceID names THIS process in a `locked_by` column: hostname, pid and a random suffix,
// minted once. It is diagnostic — the claim's correctness rests on `skip locked`, not on the
// name — but a stuck job that says which instance took it is a stuck job that can be found.
var (
	instanceIDOnce sync.Once
	instanceIDText string
)

func instanceID() string {
	instanceIDOnce.Do(func() {
		host, err := os.Hostname()
		if err != nil || host == "" {
			host = "unknown-host"
		}
		suffix := make([]byte, 4)
		if _, err := rand.Read(suffix); err != nil {
			panic("database: cannot draw an instance id: " + err.Error())
		}
		instanceIDText = host + ":" + strconv.Itoa(os.Getpid()) + ":" + hex.EncodeToString(suffix)
	})
	return instanceIDText
}

// jsonbText renders a JSON-ready value as the text a `$n::jsonb` parameter takes.
func jsonbText(value any) string {
	return EncodeJSONValue(value)
}

// scanText is the one-column text scanner the stores share.
func scanText(row pgx.CollectableRow) (string, error) {
	var text string
	err := row.Scan(&text)
	return text, err
}

// ── Queue ─────────────────────────────────────────────────────────────────────
//
// tesl_jobs holds every queue of the database, told apart by `queue`. A row is one job:
//
//	status          pending | processing | dead | dead_processing
//	attempts        failed attempts so far
//	next_attempt_at when a pending (or dead) row may be claimed; the backoff lands here
//	seq             the claim order — a bigserial, so a retried job keeps its place in line
//	locked_at/by    who is processing it and since when; what the reclaim reads
//	claim_token     identity of the current processing attempt; every outcome is fenced by it
//	job_type        which codec decodes `payload`
//
// CLAIM is a single statement — `update … where id = (select … for update skip locked limit
// 1) returning …` — so two workers on two instances cannot take the same row: the second
// skips the row the first has locked and takes the next. Before each claim, jobs an instance
// took and never finished (it crashed, or lost the network) are RECLAIMED: a `processing` row
// whose `locked_at` is older than the visibility timeout goes back to `pending`, while a
// `dead_processing` row goes back to `dead`. Attempts stay intact in both cases.

// jobsTable is the table name; the schema is the database's.
const jobsTable = "tesl_jobs"

func jobsTableDDL(qualified string) []string {
	return []string{
		"create table if not exists " + qualified + " (" +
			"id text primary key, " +
			"queue text not null, " +
			"job_type text not null, " +
			"payload jsonb not null, " +
			"status text not null, " +
			"attempts int not null default 0, " +
			"next_attempt_at timestamptz not null default now(), " +
			"seq bigserial, " +
			"locked_at timestamptz, " +
			"locked_by text, " +
			"claim_token text, " +
			"claim_seq bigint not null default 0, " +
			"lease_until timestamptz, " +
			"created_at timestamptz not null default now())",
		"alter table " + qualified + " add column if not exists claim_token text",
		"alter table " + qualified + " add column if not exists claim_seq bigint not null default 0",
		"alter table " + qualified + " add column if not exists lease_until timestamptz",
		"create index if not exists " + quoteIdentifier(jobsTable+"_claim_idx") +
			" on " + qualified + " (queue, status, next_attempt_at, seq)",
	}
}

// queueVisibilityTimeout is the lease length stamped into a new processing
// claim — TESL_QUEUE_VISIBILITY_TIMEOUT_MS, default ten minutes. Healthy handlers
// renew every third of this interval. A reclaimer uses the stored deadline, so
// its own configuration cannot shorten another worker's live lease.
var queueVisibilityTimeout = func() time.Duration {
	return millisDuration(envPositiveInt("TESL_QUEUE_VISIBILITY_TIMEOUT_MS", 600000))
}

// jobCodec is how one job type crosses the JSONB column: `encode` answers what
// EncodeJSONValue renders, `decode` takes what ParseJSON produced.
type jobCodec struct {
	typeName string
	encode   func(any) any
	decode   func(any) (any, error)
}

type pgQueueBackend struct {
	pgStore
	name         string
	maxAttempts  int
	backoff      string
	initialDelay int
	// codecs, in registration order; the emitter registers every job type of the queue
	// before anything is enqueued.
	codecsMutex sync.RWMutex
	codecs      []jobCodec
	// codecByType remembers which codec took a Go type, so the probe below runs once per type.
	codecByType sync.Map     // reflect.Type -> int (index into codecs)
	lastReclaim atomic.Int64 // unix nanoseconds of this process's last stale-job sweep
}

// NewQueueOn is `queue Q = Queue { database: D … }` for a Postgres-backed D: the in-memory
// queue plus the durable backend. `backoff` is "exponential", "fixed", "linear" or "" (no
// delay between retries); `initialDelaySeconds` is the declaration's `initialDelay`.
func NewQueueOn(database *Database, name string, maxAttempts int, backoff string,
	initialDelaySeconds int) *Queue {
	queue := NewQueue(name, maxAttempts)
	if initialDelaySeconds < 0 {
		initialDelaySeconds = 0
	}
	queue.backend = &pgQueueBackend{pgStore: pgStore{database: database}, name: name,
		maxAttempts: queue.maxAttempts, backoff: backoff, initialDelay: initialDelaySeconds}
	// The database's LISTEN loop (shared with pub/sub) rings this queue's doorbell when any
	// instance commits an enqueue.
	pubsubFor(database).registerQueue(queue)
	return queue
}

// RegisterJobCodec teaches a durable queue one job record type: `typeName` is what the row's
// `job_type` column says, `encode` renders a payload of that type as a JSON-ready value and
// `decode` reads one back into the typed Go struct. A queue that carries several job types
// registers each. On a Memory queue there is nothing to register and the call is a no-op.
//
// HOW A PAYLOAD FINDS ITS CODEC. `encode` is opaque here — the emitter writes it as
// `func(v any) any { return encodeT(v.(T)) }` — so the runtime tries the registered encoders
// in order and keeps the first that does not refuse the value with a type assertion; the Go
// type that matched is remembered, so the trial runs once per type per process. A panic that
// is NOT a type assertion (a NaN Float, say) is the encoder's own and propagates.
func RegisterJobCodec(queue *Queue, typeName string, encode func(any) any,
	decode func(any) (any, error)) struct{} {
	backend, durable := queue.backend.(*pgQueueBackend)
	if !durable {
		return struct{}{}
	}
	backend.codecsMutex.Lock()
	defer backend.codecsMutex.Unlock()
	for index, existing := range backend.codecs {
		if existing.typeName == typeName {
			backend.codecs[index] = jobCodec{typeName: typeName, encode: encode, decode: decode}
			return struct{}{}
		}
	}
	backend.codecs = append(backend.codecs, jobCodec{typeName: typeName, encode: encode, decode: decode})
	return struct{}{}
}

// tryEncode runs one encoder, answering `refused` when it rejected the value's TYPE.
func tryEncode(codec jobCodec, payload any) (encoded any, refused bool) {
	defer func() {
		if trap := recover(); trap != nil {
			var assertion *runtime.TypeAssertionError
			if err, isError := trap.(error); isError && errors.As(err, &assertion) {
				refused = true
				return
			}
			panic(trap)
		}
	}()
	return codec.encode(payload), false
}

// encodePayload answers the job type and the JSON-ready value for a payload.
func (backend *pgQueueBackend) encodePayload(payload any) (string, any) {
	backend.codecsMutex.RLock()
	codecs := backend.codecs
	backend.codecsMutex.RUnlock()
	if len(codecs) == 0 {
		panic("enqueue: queue " + backend.name + " has no job codec registered — " +
			"RegisterJobCodec must run for every job type the queue carries")
	}
	goType := reflect.TypeOf(payload)
	if found, known := backend.codecByType.Load(goType); known {
		if index, ok := found.(int); ok && index < len(codecs) {
			return codecs[index].typeName, codecs[index].encode(payload)
		}
	}
	for index, codec := range codecs {
		if encoded, refused := tryEncode(codec, payload); !refused {
			backend.codecByType.Store(goType, index)
			return codec.typeName, encoded
		}
	}
	panic(fmt.Sprintf("enqueue: queue %s has no job codec for a payload of type %T", backend.name, payload))
}

// decodePayload reads a row's payload back through the codec its `job_type` names.
func (backend *pgQueueBackend) decodePayload(typeName, payloadText string) (any, error) {
	backend.codecsMutex.RLock()
	codecs := backend.codecs
	backend.codecsMutex.RUnlock()
	for _, codec := range codecs {
		if codec.typeName == typeName {
			parsed, err := ParseJSON([]byte(payloadText))
			if err != nil {
				return nil, fmt.Errorf("payload is not JSON: %w", err)
			}
			return codec.decode(parsed)
		}
	}
	return nil, fmt.Errorf("no job codec registered for job_type %q", typeName)
}

func (backend *pgQueueBackend) table() (*PostgresDB, string) {
	db := backend.connection()
	ensureTable(db, jobsTable, jobsTableDDL)
	return db, db.QualifiedTable(jobsTable)
}

func (backend *pgQueueBackend) enqueue(payload any) string {
	typeName, encoded := backend.encodePayload(payload)
	db, table := backend.table()
	id := UUIDv7()
	PgExec(db, "insert into "+table+" (id, queue, job_type, payload, status) "+
		"values ($1, $2, $3, $4::jsonb, 'pending')",
		[]any{id, backend.name, typeName, jsonbText(encoded)})
	// Through the same executor, so inside a `transaction { }` the notification is
	// delivered on commit and never for a rollback — workers on every instance wake only
	// when the row is visible to them.
	PgExec(db, "select pg_notify($1, $2)", []any{queueNotifyChannel, backend.name})
	return id
}

// claimedJob is one row as the claim returns it.
type claimedJob struct {
	id         string
	jobType    string
	payload    string
	attempts   int
	claimToken string
}

// A claim created inside a transaction is protected by that transaction's row
// lock until it commits. Remember its exact transaction identity, not merely
// "some transaction is open": a later transaction cannot revive an old lease.
var queueTransactionClaims sync.Map // pgx.Tx -> *sync.Map of opaque claim tokens

func rememberQueueTransactionClaim(token string) {
	if tx := currentTransaction(); tx != nil {
		claims, _ := queueTransactionClaims.LoadOrStore(tx, &sync.Map{})
		claims.(*sync.Map).Store(token, struct{}{}) //nolint:forcetypeassert // private typed registry
	}
}

func queueClaimOwnedByTransaction(token string) bool {
	tx := currentTransaction()
	if tx == nil {
		return false
	}
	claims, found := queueTransactionClaims.Load(tx)
	if !found {
		return false
	}
	_, found = claims.(*sync.Map).Load(token) //nolint:forcetypeassert // private typed registry
	return found
}

func scanClaimedJob(row pgx.CollectableRow) (claimedJob, error) {
	job := claimedJob{}
	var attempts int32
	if err := row.Scan(&job.id, &job.jobType, &job.payload, &attempts, &job.claimToken); err != nil {
		return job, err
	}
	job.attempts = int(attempts)
	return job, nil
}

// queueReclaimInterval bounds how often ONE process sweeps for jobs an instance took and never
// finished. The sweep is an UPDATE over the queue's processing rows; running it before every
// claim put it on the hot path of every job (tesl/queue.rkt swept once a minute from its
// poller thread, and so does this). A variable so the runtime's tests can shrink it.
var queueReclaimInterval = time.Minute

// reclaimStuck releases jobs an instance took and never finished, at most once per
// queueReclaimInterval per process.
func (backend *pgQueueBackend) reclaimStuck(db *PostgresDB, table string) {
	now := time.Now().UnixNano()
	last := backend.lastReclaim.Load()
	if now-last < queueReclaimInterval.Nanoseconds() || !backend.lastReclaim.CompareAndSwap(last, now) {
		return
	}
	PgExec(db, "update "+table+" set status = case when status = 'dead_processing' then 'dead' else 'pending' end, "+
		"locked_at = null, locked_by = null, claim_token = null, lease_until = null "+
		"where queue = $1 and status in ('processing', 'dead_processing') "+
		"and case when strpos(coalesce(claim_token, ''), ':') > 0 then lease_until <= clock_timestamp() "+
		"else locked_at < clock_timestamp() - ($2::bigint * interval '1 millisecond') end",
		[]any{backend.name, queueVisibilityTimeout().Milliseconds()})
}

// dequeue claims the oldest claimable job with `status` and decodes it. A row whose payload
// cannot be decoded — its `job_type` has no codec (a job enqueued by a build that knew a type
// this one does not), or the JSON does not fit — is QUARANTINED rather than dropped or
// retried: it goes to the dead letter with a `next_attempt_at` of infinity, so it is counted
// and listed there but never claimed again by either worker, and one line on stderr says so.
// The claim then moves on to the next row instead of answering "nothing to do".
func (backend *pgQueueBackend) dequeue(status string) (string, any, int, string, bool) {
	db, table := backend.table()
	backend.reclaimStuck(db, table)
	processingStatus := jobProcessing
	if status == jobDead {
		processingStatus = jobDeadProcessing
	}
	for {
		claimToken := UUIDv7()
		rows := PgQuery(db, "update "+table+" set status = $3, locked_at = now(), locked_by = $4, "+
			"claim_token = $5 || ':' || (claim_seq + 1)::text, claim_seq = claim_seq + 1, "+
			"lease_until = clock_timestamp() + ($6::bigint * interval '1 millisecond') "+
			"where id = (select id from "+table+" where queue = $1 and status = $2 "+
			"and next_attempt_at <= now() order by seq for update skip locked limit 1) "+
			"returning id, job_type, payload::text, attempts, claim_token",
			[]any{backend.name, status, processingStatus, instanceID(), claimToken, queueVisibilityTimeout().Milliseconds()}, scanClaimedJob)
		if len(rows) == 0 {
			return "", nil, 0, "", false
		}
		claimed := rows[0]
		migrationBoundary("queue-claim")
		rememberQueueTransactionClaim(claimed.claimToken)
		payload, err := backend.decodePayload(claimed.jobType, claimed.payload)
		if err != nil {
			sequence, valid := queueClaimSequence(claimed.claimToken)
			if !valid {
				panic("database: invalid durable queue claim identity")
			}
			changed := PgExec(db, "update "+table+" set status = 'dead', next_attempt_at = 'infinity', "+
				"locked_at = null, locked_by = null, claim_token = null, lease_until = null "+
				"where id = $1 and status = $3 and claim_token = $2 "+
				"and claim_seq = $5 and ($4::bool or lease_until > clock_timestamp())",
				[]any{claimed.id, claimed.claimToken, processingStatus, queueClaimOwnedByTransaction(claimed.claimToken), sequence})
			if changed == 1 {
				fmt.Fprintf(os.Stderr, "tesl: queue %s: job %s (job_type %s) cannot be decoded and was "+
					"quarantined in the dead letter: %v\n", backend.name, claimed.id, claimed.jobType, err)
			}
			continue
		}
		return claimed.id, payload, claimed.attempts, claimed.claimToken, true
	}
}

func (backend *pgQueueBackend) complete(id, claimToken string) bool {
	migrationBoundary("queue-completion-begins")
	sequence, valid := queueClaimSequence(claimToken)
	if !valid {
		return false
	}
	db, table := backend.table()
	// Zero rows means this attempt's lease was replaced; its result is discarded.
	return PgExec(db, "delete from "+table+
		" where id = $1 and status in ('processing', 'dead_processing') and claim_token = $2 "+
		"and claim_seq = $3 and ($4::bool or lease_until > clock_timestamp())",
		[]any{id, claimToken, sequence, queueClaimOwnedByTransaction(claimToken)}) == 1
}

// The opaque token carries both the random legacy attempt identity and the
// monotone per-row sequence. Keeping the random component also fences an old
// pre-sequence binary during a runtime upgrade.
func queueClaimSequence(token string) (int64, bool) {
	colon := strings.LastIndexByte(token, ':')
	if colon < 1 {
		return 0, false
	}
	sequence, err := strconv.ParseInt(token[colon+1:], 10, 64)
	return sequence, err == nil && sequence > 0
}

// queueRenewals separates the production clock from the renewal protocol. Tests
// deliver ticks explicitly, including cancellation and ownership-loss races.
func queueRenewals(ctx context.Context, ticks <-chan time.Time,
	renew func(context.Context) (bool, error), report func(error)) {
	for {
		select {
		case <-ctx.Done():
			return
		case _, open := <-ticks:
			if !open || ctx.Err() != nil {
				return
			}
			owned, err := renew(ctx)
			if err != nil || !owned {
				if ctx.Err() == nil {
					if err == nil {
						err = fmt.Errorf("claim lease expired or was replaced")
					}
					report(err)
				}
				return
			}
		}
	}
}

// keepClaim pins the backend and connection for the claim's lifetime, so a
// goroutine never resolves a different process-global database binding. A claim
// inside an explicit transaction already holds its row lock until completion;
// a second connection cannot renew an uncommitted claim and must not be started.
func (backend *pgQueueBackend) keepClaim(id, token string) func() {
	if currentTransaction() != nil {
		return func() {}
	}
	db, table := backend.table()
	lease := queueVisibilityTimeout()
	interval := max(time.Millisecond, lease/3)
	ctx, cancel := context.WithCancel(context.Background())
	ticker := time.NewTicker(interval)
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer ticker.Stop()
		queueRenewals(ctx, ticker.C, func(ctx context.Context) (bool, error) {
			return backend.renewClaim(ctx, db, table, id, token, lease)
		}, func(err error) {
			fmt.Fprintf(os.Stderr, "tesl: queue %s: job %s lease renewal stopped: %v\n", backend.name, id, err)
		})
	}()
	var stop sync.Once
	return func() { stop.Do(func() { cancel(); <-done }) }
}

// Renewal is a compare-and-set. In particular, an expired lease is never
// resurrected merely because the reclaim sweep has not reached it yet.
func (backend *pgQueueBackend) renewClaim(ctx context.Context, db *PostgresDB,
	table, id, token string, lease time.Duration) (bool, error) {
	sequence, valid := queueClaimSequence(token)
	if !valid {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(ctx, pgLeaseTimeout())
	defer cancel()
	tag, err := db.pool.Exec(ctx, "update "+table+" set locked_at = clock_timestamp(), "+
		"lease_until = clock_timestamp() + ($4::bigint * interval '1 millisecond') "+
		"where id = $1 and queue = $2 and claim_token = $3 "+
		"and status in ('processing', 'dead_processing') and claim_seq = $5 "+
		"and lease_until > clock_timestamp()",
		id, backend.name, token, lease.Milliseconds(), sequence)
	if err == nil && tag.RowsAffected() == 1 {
		migrationBoundary("queue-renewal")
	}
	return tag.RowsAffected() == 1, err
}

// retryDelaySeconds is the wait before attempt number `attempts`+1, given `attempts` failures:
// exponential doubles from the initial delay (N, 2N, 4N, …), linear grows by it (N, 2N, 3N,
// …), fixed is always N, and "" is no wait at all.
func (backend *pgQueueBackend) retryDelaySeconds(attempts int) int64 {
	initial := int64(backend.initialDelay)
	if attempts < 1 {
		attempts = 1
	}
	switch backend.backoff {
	case "exponential":
		shift := attempts - 1
		if shift > 40 {
			shift = 40
		}
		return initial << shift
	case "linear":
		return initial * int64(attempts)
	case "fixed":
		return initial
	default:
		return 0
	}
}

// fail records a failed attempt: back to `pending` after the backoff, or `dead` at
// maxAttempts — claimable at once by the dead-letter worker.
func (backend *pgQueueBackend) fail(id string, attempts int, claimToken string) bool {
	sequence, valid := queueClaimSequence(claimToken)
	if !valid {
		return false
	}
	db, table := backend.table()
	next := attempts + 1
	status := jobPending
	delay := backend.retryDelaySeconds(next)
	if next >= backend.maxAttempts {
		status = jobDead
		delay = 0
	}
	changed := PgExec(db, "update "+table+" set status = $2, attempts = $3, "+
		"next_attempt_at = now() + ($4::bigint * interval '1 second'), "+
		"locked_at = null, locked_by = null, claim_token = null, lease_until = null "+
		"where id = $1 and status = 'processing' and claim_token = $5 "+
		"and claim_seq = $6 and ($7::bool or lease_until > clock_timestamp())",
		[]any{id, status, int32(min(next, 1<<30)), delay, claimToken, sequence, queueClaimOwnedByTransaction(claimToken)}) // #nosec G115 -- clamped above
	return changed == 1
}

func (backend *pgQueueBackend) count(status string) int {
	db, table := backend.table()
	counted, exact := PgCount(db, "select count(*) from "+table+" where queue = $1 and status = $2",
		[]any{backend.name, status}).Int64()
	if !exact {
		return 0
	}
	return int(counted)
}

func (backend *pgQueueBackend) deadJobs(queue *Queue) []DeadJob {
	db, table := backend.table()
	ids := PgQuery(db, "select id from "+table+" where queue = $1 and status = 'dead' order by seq",
		[]any{backend.name}, scanText)
	dead := make([]DeadJob, 0, len(ids))
	for _, id := range ids {
		dead = append(dead, DeadJob{ID: id, queue: queue})
	}
	return dead
}

// requeue puts a dead job back in line with a fresh attempt count. Only a row that IS dead
// moves — one a dead-letter worker has claimed is `dead_processing` and answers false, as the
// in-memory store does for the same case.
func (backend *pgQueueBackend) requeue(id string) bool {
	db, table := backend.table()
	changed := PgExec(db, "update "+table+" set status = 'pending', attempts = 0, "+
		"next_attempt_at = now(), locked_at = null, locked_by = null, claim_token = null, lease_until = null "+
		"where id = $1 and status = 'dead'", []any{id})
	return changed == 1
}

func (backend *pgQueueBackend) reset() {
	db, table := backend.table()
	PgExec(db, "delete from "+table+" where queue = $1", []any{backend.name})
}

// ── Email outbox ──────────────────────────────────────────────────────────────
//
// tesl_email_outbox is one table per database, shared by every `email` declaration on it
// (as Racket's was). A row is a message; `status` is pending | sent | dead; a pending row
// with `locked_at` set is on the wire with some instance, and one whose lock is older than
// ten minutes is presumed abandoned and claimable again.

const outboxTable = "tesl_email_outbox"

func outboxTableDDL(qualified string) []string {
	return []string{
		"create table if not exists " + qualified + " (" +
			"id bigserial primary key, " +
			"recipient text, " +
			"subject text, " +
			"body_kind text, " +
			"body_text text, " +
			"body_html text, " +
			"status text, " +
			"attempts int, " +
			"next_attempt_at timestamptz, " +
			"locked_at timestamptz, " +
			"claim_token text, " +
			"created_at timestamptz default now(), " +
			"sent_at timestamptz)",
		"alter table " + qualified + " add column if not exists claim_token text",
		"create index if not exists " + quoteIdentifier(outboxTable+"_due_idx") +
			" on " + qualified + " (status, next_attempt_at, id)",
	}
}

// emailClaimWindow is how long a claimed message stays another instance's before it may be
// taken over — long enough for the SMTP exchange and its deadlines, short enough that a
// crashed instance's mail is not stuck for the day.
const emailClaimWindow = 10 * time.Minute

type pgOutboxBackend struct {
	pgStore
}

// NewOutboxOn is `email E = Email { database: D … }` for a Postgres-backed D.
func NewOutboxOn(database *Database, settings SmtpSettings) *Outbox {
	outbox := NewOutbox(settings)
	outbox.backend = &pgOutboxBackend{pgStore: pgStore{database: database}}
	return outbox
}

func (backend *pgOutboxBackend) table() (*PostgresDB, string) {
	db := backend.connection()
	ensureTable(db, outboxTable, outboxTableDDL)
	return db, db.QualifiedTable(outboxTable)
}

// bodyKind and bodyOfKind are the column form of the EmailBody ADT: the VARIANT is stored,
// not inferred from which string is non-empty, so `HtmlBody ""` comes back as HTML.
func bodyKind(body EmailBody) string {
	switch body.Tag {
	case EmailBodyHTML:
		return "html"
	case EmailBodyRich:
		return "rich"
	case EmailBodyText:
		return "text"
	default:
		return "text"
	}
}

func bodyOfKind(kind string, text, html *string) EmailBody {
	plain, markup := "", ""
	if text != nil {
		plain = *text
	}
	if html != nil {
		markup = *html
	}
	switch kind {
	case "html":
		return HTMLBody(markup)
	case "rich":
		return RichBody(plain, markup)
	default:
		return TextBody(plain)
	}
}

func emailStatusOf(text string) EmailStatus {
	switch text {
	case "sent":
		return EmailSent
	case "dead":
		return EmailDead
	default:
		return EmailPending
	}
}

func (backend *pgOutboxBackend) send(message EmailMessage) {
	db, table := backend.table()
	PgExec(db, "insert into "+table+" (recipient, subject, body_kind, body_text, body_html, "+
		"status, attempts, next_attempt_at) values ($1, $2, $3, $4, $5, 'pending', 0, now())",
		[]any{message.To, message.Subject, bodyKind(message.Body), message.Body.Text, message.Body.HTML})
}

const outboxColumns = "id, recipient, subject, body_kind, body_text, body_html, status, attempts, " +
	"next_attempt_at, sent_at, claim_token"

func scanOutboxRow(row pgx.CollectableRow) (EmailMessage, error) {
	message := EmailMessage{}
	var (
		id         int64
		recipient  *string
		subject    *string
		kind       *string
		text       *string
		html       *string
		status     *string
		attempts   *int32
		next       *time.Time
		sent       *time.Time
		claimToken *string
	)
	if err := row.Scan(&id, &recipient, &subject, &kind, &text, &html, &status, &attempts,
		&next, &sent, &claimToken); err != nil {
		return message, err
	}
	if id < 0 {
		return message, fmt.Errorf("outbox row has a negative id %d", id)
	}
	message.id = uint64(id)
	if recipient != nil {
		message.To = *recipient
	}
	if subject != nil {
		message.Subject = *subject
	}
	bodyKindText := "text"
	if kind != nil {
		bodyKindText = *kind
	}
	message.Body = bodyOfKind(bodyKindText, text, html)
	if status != nil {
		message.Status = emailStatusOf(*status)
	}
	if attempts != nil {
		message.Attempts = int(*attempts)
	}
	if next != nil {
		message.NextAttemptAt = *next
	}
	if sent != nil {
		message.SentAt = *sent
	}
	if claimToken != nil {
		message.claimToken = *claimToken
	}
	return message, nil
}

// claimDue takes up to `limit` due messages for this pass by stamping `locked_at`. The lock
// is what keeps a second instance off them: its own claim skips rows with a fresh lock, and
// `skip locked` covers the instant between two claims running at once.
func (backend *pgOutboxBackend) claimDue(limit int) []EmailMessage {
	db, table := backend.table()
	claimToken := UUIDv7()
	return PgQuery(db, "update "+table+" set locked_at = now(), claim_token = $3 where id in ("+
		"select id from "+table+" where status = 'pending' and next_attempt_at <= now() "+
		"and (locked_at is null or locked_at < now() - ($2::bigint * interval '1 millisecond')) "+
		"order by id for update skip locked limit $1) returning "+outboxColumns,
		[]any{int32(min(max(limit, 1), 1<<30)), emailClaimWindow.Milliseconds(), claimToken}, // #nosec G115 -- clamped
		scanOutboxRow)
}

func (backend *pgOutboxBackend) recordOutcome(message EmailMessage, err error) bool {
	db, table := backend.table()
	if message.id > uint64(1<<62) {
		panic("email: outbox row id out of range")
	}
	id := int64(message.id) // #nosec G115 -- range checked above
	// Zero rows in any branch means the lease was replaced; the stale SMTP result is discarded.
	if err == nil {
		return PgExec(db, "update "+table+" set status = 'sent', sent_at = now(), locked_at = null, "+
			"claim_token = null where id = $1 and status = 'pending' and claim_token = $2",
			[]any{id, message.claimToken}) == 1
	}
	attempts := message.Attempts + 1
	if attempts >= emailMaxAttempts {
		return PgExec(db, "update "+table+" set status = 'dead', attempts = $2, locked_at = null, "+
			"claim_token = null where id = $1 and status = 'pending' and claim_token = $3",
			[]any{id, int32(min(attempts, 1<<30)), message.claimToken}) == 1 // #nosec G115 -- clamped
	}
	return PgExec(db, "update "+table+" set attempts = $2, "+
		"next_attempt_at = now() + ($3::bigint * interval '1 millisecond'), locked_at = null, "+
		"claim_token = null where id = $1 and status = 'pending' and claim_token = $4",
		[]any{id, int32(min(attempts, 1<<30)), emailRetryDelay(attempts).Milliseconds(),
			message.claimToken}) == 1 // #nosec G115 -- clamped
}

func (backend *pgOutboxBackend) messages() []EmailMessage {
	db, table := backend.table()
	return PgQuery(db, "select "+outboxColumns+" from "+table+" order by id", nil, scanOutboxRow)
}

func (backend *pgOutboxBackend) reset() {
	db, table := backend.table()
	PgExec(db, "delete from "+table, nil)
}

func (backend *pgOutboxBackend) prune(keep time.Duration) {
	db, table := backend.table()
	PgExec(db, "delete from "+table+" where status = 'sent' and sent_at < now() - ($1::bigint * interval '1 millisecond')",
		[]any{keep.Milliseconds()})
}

// ── Cache ─────────────────────────────────────────────────────────────────────
//
// tesl_cache is UNLOGGED — no WAL, so a write costs what a cache write should, at the price
// that a crash empties it, which for a cache is the right trade. One table per database,
// with every `cache` declaration on it told apart by `cache_name`. The value is JSONB through
// the declaration's codec; an entry that no longer decodes (the type changed under it) is a
// miss and is removed, as Racket's was.

const cacheTable = "tesl_cache"

func cacheTableDDL(qualified string) []string {
	return []string{
		"create unlogged table if not exists " + qualified + " (" +
			"cache_name text not null, " +
			"key text not null, " +
			"value jsonb not null, " +
			"expires_at timestamptz, " +
			"primary key (cache_name, key))",
	}
}

// cacheSweepInterval bounds how often one process removes a cache's expired rows: a read
// never answers an expired row (the predicate excludes it), so the sweep is housekeeping and
// is done opportunistically on a write rather than by a goroutine of its own.
const cacheSweepInterval = time.Minute

type pgCacheBackend struct {
	pgStore
	name      string
	encode    func(any) any
	decode    func(any) (any, error)
	lastSweep atomic.Int64 // unix nanoseconds
}

// NewCacheOn is `cache C = Cache { database: D … }` for a Postgres-backed D: the in-memory
// cache plus the durable backend. `encode` and `decode` are the value type's JSON codec.
func NewCacheOn[V any](database *Database, name string, defaultTTLSeconds int64,
	encode func(V) any, decode func(any) (V, error)) *Cache[V] {
	cache := NewCache[V](defaultTTLSeconds)
	// The typed codecs are adapted to `any` at the one place the type parameter is known.
	cache.backend = &pgCacheBackend{pgStore: pgStore{database: database}, name: name,
		encode: func(value any) any { return encode(value.(V)) },
		decode: func(raw any) (any, error) { return decode(raw) }}
	return cache
}

func (backend *pgCacheBackend) table() (*PostgresDB, string) {
	db := backend.connection()
	ensureTable(db, cacheTable, cacheTableDDL)
	return db, db.QualifiedTable(cacheTable)
}

func (backend *pgCacheBackend) get(key string) (any, bool) {
	db, table := backend.table()
	rows := PgQuery(db, "select value::text from "+table+" where cache_name = $1 and key = $2 "+
		"and (expires_at is null or expires_at > now())", []any{backend.name, key}, scanText)
	if len(rows) == 0 {
		return nil, false
	}
	parsed, err := ParseJSON([]byte(rows[0]))
	if err == nil {
		var value any
		value, err = backend.decode(parsed)
		if err == nil {
			return value, true
		}
	}
	// An entry this build cannot read is removed so the next read does not pay for it
	// again, and reported, since a cache that silently misses on every read of a key looks
	// like one that was never written.
	fmt.Fprintf(os.Stderr, "tesl: cache %s: stored value for a key cannot be decoded and was removed: %v\n",
		backend.name, err)
	PgExec(db, "delete from "+table+" where cache_name = $1 and key = $2", []any{backend.name, key})
	return nil, false
}

func (backend *pgCacheBackend) set(key string, value any, ttlSeconds int64) {
	db, table := backend.table()
	backend.sweepExpired(db, table)
	PgExec(db, "insert into "+table+" (cache_name, key, value, expires_at) values ($1, $2, $3::jsonb, "+
		"case when $4::bigint > 0 then now() + ($4::bigint * interval '1 second') else null end) "+
		"on conflict (cache_name, key) do update set value = excluded.value, expires_at = excluded.expires_at",
		[]any{backend.name, key, jsonbText(backend.encode(value)), ttlSeconds})
}

// sweepExpired removes this cache's expired rows, at most once per cacheSweepInterval per
// process. It runs on the write path only — a hot cache is written to, a cold one has
// nothing worth sweeping.
func (backend *pgCacheBackend) sweepExpired(db *PostgresDB, table string) {
	now := time.Now().UnixNano()
	last := backend.lastSweep.Load()
	if now-last < cacheSweepInterval.Nanoseconds() || !backend.lastSweep.CompareAndSwap(last, now) {
		return
	}
	PgExec(db, "delete from "+table+" where cache_name = $1 and expires_at is not null and expires_at < now()",
		[]any{backend.name})
}

func (backend *pgCacheBackend) del(key string) {
	db, table := backend.table()
	PgExec(db, "delete from "+table+" where cache_name = $1 and key = $2", []any{backend.name, key})
}

// invalidatePrefix removes every key that BEGINS WITH prefix, literally: `left(key,
// length($2)) = $2` has no pattern semantics, where `key like $2 || '%'` would read a `%` or
// `_` in the prefix as a wildcard and wipe far more than it names.
func (backend *pgCacheBackend) invalidatePrefix(prefix string) {
	db, table := backend.table()
	PgExec(db, "delete from "+table+" where cache_name = $1 and left(key, length($2)) = $2",
		[]any{backend.name, prefix})
}

func (backend *pgCacheBackend) reset() {
	db, table := backend.table()
	PgExec(db, "delete from "+table+" where cache_name = $1", []any{backend.name})
}

// The lint gate on EMITTED code runs this file in every Postgres-backed program, including one
// that declares no cache, and the `unused` analyser does not follow a generic type's methods
// through interface dispatch. These assertions are the proof that each backend implements its
// hook — and the reference that keeps a method used regardless of what the program declares.
var (
	_ cacheBackend  = (*pgCacheBackend)(nil)
	_ queueBackend  = (*pgQueueBackend)(nil)
	_ outboxBackend = (*pgOutboxBackend)(nil)
)
