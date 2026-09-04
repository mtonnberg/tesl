package teslrt

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// Cross-instance SSE pub/sub on PostgreSQL: `sseChannel C(key) = SseChannel { database: D … }`.
//
// A publish delivered only to the listeners of THIS process reaches a browser subscribed on
// another replica never: with two instances behind a load balancer, half the events vanish.
// The spec (§ SSE channels) promises what this file implements — a `tesl_pubsub_outbox` table
// created alongside the entity tables, events published inside `transaction { }` written to
// it atomically and delivered after commit, and one PostgreSQL LISTEN connection per process
// for the fan-out. The retired Racket runtime (`tesl/queue.rkt`) did the same, and its two
// hard-won rules are kept: a NOTIFY carries the outbox ROW ID rather than the payload (every
// instance SELECTs the same row, so nothing is lost to the 8000-byte NOTIFY limit), and a
// periodic SWEEP re-reads the outbox so a lost notification or a reconnecting instance still
// delivers everything.
//
// WHAT DIFFERS FROM RACKET, deliberately. Racket delivered the publisher's own event locally
// after commit and marked the row so the LISTEN path would skip it; here the publisher's own
// process receives its events through the SAME LISTEN path as every other instance. One path
// instead of two means one ordering (the outbox's), no per-process "already delivered" set
// that must stay consistent with the deferred-delivery list, and the rolled-back case falls
// out for free: a row that never committed fires no NOTIFY and is visible to no sweep.
//
// WHERE THE FILE SHIPS. Only with a Postgres-backed program — it is the one place the SSE
// channel meets `*Database` and pgx, and sse.go (always shipped) sees it only through the
// `pubsubBackend` interface. A channel of a Memory-backed database never touches this file.
//
// COMMIT-ORDERED DISPATCH. The row id is allocated by INSERT, not commit, so it is never used
// as a lifetime delivery cursor. A sweep first assigns committed raw rows a dispatch_seq while
// holding one transaction-scoped advisory lock for this outbox. Those assignment transactions
// therefore commit in sequence order. A transaction that reserved a low row id and committed
// late is assigned a later dispatch_seq and remains visible above every process's cursor.
//
// STARTUP BASELINE. A process does not replay old SSE events. Preparation dispatches every row
// visible at startup, then captures max(dispatch_seq). Rows that commit later are still raw and
// receive a sequence above that baseline on a later sweep.

const (
	pubsubNotifyChannel = "tesl_pubsub"
	// queueNotifyChannel carries the QUEUE NAME as payload: one channel for every queue on the
	// database, so the listener connection is shared, and the payload says whose doorbell to
	// ring.
	queueNotifyChannel = "tesl_queue"
	pubsubOutboxTable  = "tesl_pubsub_outbox"
	pubsubDispatchSeq  = "tesl_pubsub_dispatch_seq"
	// pubsubSweepBatch bounds one sweep query; a sweep that fills the batch runs again at once.
	pubsubSweepBatch      = 500
	pubsubSweepMaxBatches = 4
	// pubsubSeenLimit bounds low-latency notification deduplication. Above it, rows wait for
	// the durable sweep instead of consuming more process memory.
	pubsubSeenLimit = pubsubSweepBatch * pubsubSweepMaxBatches
)

// The intervals are variables so a test can shrink them; production never writes them.
var (
	// pubsubSweepInterval is how often the outbox is re-read for rows a notification missed.
	pubsubSweepInterval = 5 * time.Second
	// pubsubBindPollInterval is how often an idle backend checks whether its database has
	// been bound yet: the listener cannot start before `with database D`.
	pubsubBindPollInterval = 250 * time.Millisecond
	// The reconnect backoff after the LISTEN connection drops, doubling up to the maximum.
	pubsubReconnectMinBackoff = 200 * time.Millisecond
	pubsubReconnectMaxBackoff = 5 * time.Second
	// pubsubOutboxRetention is how long a delivered row stays before a sweep prunes it.
	pubsubOutboxRetention = time.Hour
	pubsubPruneInterval   = time.Minute
)

// pgPubsub is one process's pub/sub state for one `Database` declaration: the channels
// declared on it, the LISTEN goroutine, and retained-row deduplication.
type pgPubsub struct {
	database *Database

	mutex sync.Mutex
	// channels by declared NAME. A name normally has one channel; a test standing two
	// channels in for two instances registers two, and both receive.
	channels map[string][]*SseChannel
	// queues by declared name, woken on a `tesl_queue` notification naming them.
	queues map[string][]*Queue
	// ready is set once the outbox table exists and the dispatch baseline is captured.
	ready bool
	// dispatchCursor is the highest commit-ordered dispatch sequence this process swept.
	dispatchCursor int64
	// seen contains up to pubsubSeenLimit notifications delivered before their row reached
	// dispatchCursor. Once full, further notifications defer to the durable sweep.
	seen map[int64]struct{}
	// listener is the live LISTEN connection, or nil between connections.
	listener *pgx.Conn

	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}
}

// pgPubsubs is the per-database registry: one runtime per `Database` value, created by the
// first `NewSseChannelOn` naming it.
var pgPubsubs sync.Map // *Database -> *pgPubsub

// NewSseChannelOn is what an `sseChannel` declaration with `database: D` emits, where
// `NewSseChannel` is what a Memory-backed one emits. The channel is an ordinary SseChannel
// with the database's pub/sub runtime attached, and registered with that runtime under its
// name so an event arriving from another instance finds it.
func NewSseChannelOn(database *Database, name string) *SseChannel {
	channel := NewSseChannel(name)
	runtime := pubsubFor(database)
	runtime.mutex.Lock()
	runtime.channels[name] = append(runtime.channels[name], channel)
	runtime.mutex.Unlock()
	channel.backend = runtime
	return channel
}

// registerQueue hands a durable queue's doorbell to the database's listener.
func (runtime *pgPubsub) registerQueue(queue *Queue) {
	runtime.mutex.Lock()
	runtime.queues[queue.name] = append(runtime.queues[queue.name], queue)
	runtime.mutex.Unlock()
}

// wakeQueues rings every registered queue named by a `tesl_queue` notification.
func (runtime *pgPubsub) wakeQueues(name string) {
	runtime.mutex.Lock()
	queues := append([]*Queue(nil), runtime.queues[name]...)
	runtime.mutex.Unlock()
	for _, queue := range queues {
		queue.Wake()
	}
}

func pubsubFor(database *Database) *pgPubsub {
	if existing, found := pgPubsubs.Load(database); found {
		if runtime, ok := existing.(*pgPubsub); ok {
			return runtime
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	created := &pgPubsub{
		database: database,
		channels: map[string][]*SseChannel{},
		queues:   map[string][]*Queue{},
		seen:     map[int64]struct{}{},
		ctx:      ctx,
		cancel:   cancel,
		done:     make(chan struct{}),
	}
	actual, loaded := pgPubsubs.LoadOrStore(database, created)
	if loaded {
		cancel()
		if runtime, ok := actual.(*pgPubsub); ok {
			return runtime
		}
	}
	go created.run()
	return created
}

// ── The publish side ──────────────────────────────────────────────────────────

// active answers whether the database is bound. It also PREPARES the outbox on the way, so
// this process's first publish cannot be mistaken for a pre-existing baseline row.
func (runtime *pgPubsub) active() bool {
	connection := runtime.database.bound()
	if connection == nil {
		return false
	}
	if err := runtime.prepare(connection); err != nil {
		panic(pgFailure("publish: cannot prepare the pub/sub outbox", err))
	}
	return true
}

// publish writes the row and queues the notification, both through the goroutine's executor
// so that inside a `transaction { }` they belong to it: PostgreSQL delivers a NOTIFY only when
// the transaction that issued it commits, and a rolled-back one leaves neither the row nor
// the notification behind.
func (runtime *pgPubsub) publish(channel, key string, encoded string) {
	connection := runtime.database.bound()
	if connection == nil {
		// The binding ended between `active` and here, which only a concurrent unbind can
		// do; the event is still owed to this process's listeners.
		runtime.deliver(channel, key, encoded)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	var id int64
	err := connection.executor().QueryRow(ctx,
		"insert into "+connection.QualifiedTable(pubsubOutboxTable)+
			` ("channel", "key", "payload") values ($1, $2, $3::jsonb) returning "id"`,
		channel, key, encoded).Scan(&id)
	if err != nil {
		panic(pgFailure("publish", err))
	}
	if _, err := connection.executor().Exec(ctx, "select pg_notify($1, $2)",
		pubsubNotifyChannel, strconv.FormatInt(id, 10)); err != nil {
		panic(pgFailure("publish", err))
	}
	Counter("tesl.sse.pubsub.published", FromInt64(1), sseChannelAttribute(channel))
}

// prepare creates the outbox if it is absent and captures the dispatch baseline, once per
// runtime. It runs on the POOL rather than the executor: a table created inside a caller's
// transaction would vanish with a rollback, and the baseline is a fact about committed rows.
func (runtime *pgPubsub) prepare(connection *PostgresDB) error {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	if runtime.ready {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	if err := createPubsubOutbox(ctx, connection); err != nil {
		return err
	}
	for {
		dispatched, err := dispatchPubsubPending(ctx, connection.pool, connection)
		if err != nil {
			return err
		}
		if dispatched < pubsubSweepBatch {
			break
		}
	}
	if err := connection.pool.QueryRow(ctx, `select coalesce(max("dispatch_seq"), 0) from `+
		connection.QualifiedTable(pubsubOutboxTable)).Scan(&runtime.dispatchCursor); err != nil {
		return err
	}
	runtime.ready = true
	return nil
}

// createPubsubOutbox owns only Tesl's runtime table, sequence, and indexes. The ALTERs are the
// idempotent upgrade from the original allocation-ordered outbox; they are not application
// schema migration machinery.
func createPubsubOutbox(ctx context.Context, connection *PostgresDB) error {
	table := connection.QualifiedTable(pubsubOutboxTable)
	statements := []string{
		`create sequence if not exists ` + connection.QualifiedTable(pubsubDispatchSeq),
		fmt.Sprintf(`create table if not exists %s (
	"id" bigserial primary key,
	"channel" text not null,
	"key" text not null,
	"payload" jsonb not null,
	"created_at" timestamptz not null default now(),
	"dispatch_seq" bigint,
	"dispatched_at" timestamptz
)`, table),
		`alter table ` + table + ` add column if not exists "dispatch_seq" bigint`,
		`alter table ` + table + ` add column if not exists "dispatched_at" timestamptz`,
		`create unique index if not exists ` + quoteIdentifier(pubsubOutboxTable+"_dispatch_idx") +
			` on ` + table + ` ("dispatch_seq") where "dispatch_seq" is not null`,
		`create index if not exists ` + quoteIdentifier(pubsubOutboxTable+"_pending_idx") +
			` on ` + table + ` ("id") where "dispatch_seq" is null`,
		`create index if not exists ` + quoteIdentifier(pubsubOutboxTable+"_prune_idx") +
			` on ` + table + ` ("dispatched_at") where "dispatched_at" is not null`,
	}
	for _, statement := range statements {
		var err error
		for attempt := 0; attempt < 2; attempt++ {
			if _, err = connection.pool.Exec(ctx, statement); err == nil {
				break
			}
			if !pgDuplicateObject(err) && !strings.Contains(err.Error(), "already exists") {
				return err
			}
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// ── The delivery side ─────────────────────────────────────────────────────────

// deliver hands one stored event to every local channel of that name. A payload that does
// not parse is a row another tool wrote, and is skipped rather than allowed to end the
// listener.
func (runtime *pgPubsub) deliver(channel, key string, encoded string) {
	payload, err := ParseJSON([]byte(encoded))
	if err != nil {
		fmt.Fprintf(os.Stderr, "tesl: pubsub: outbox row on channel %s holds no JSON: %v\n",
			channel, err)
		return
	}
	runtime.mutex.Lock()
	targets := append([]*SseChannel{}, runtime.channels[channel]...)
	runtime.mutex.Unlock()
	for _, target := range targets {
		deliverLocal(target, key, payload)
	}
}

// markSeen records a notification-delivered id. False means either duplicate or full; in the
// full case delivery is safely deferred to the durable sweep.
func (runtime *pgPubsub) markSeen(id int64) bool {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	if _, already := runtime.seen[id]; already {
		return false
	}
	if len(runtime.seen) >= pubsubSeenLimit {
		return false
	}
	runtime.seen[id] = struct{}{}
	return true
}

// takeSeen answers whether the notification path already delivered id and removes its
// temporary entry. The dispatch cursor suppresses every later notification for the row.
func (runtime *pgPubsub) takeSeen(id int64) bool {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	if _, seen := runtime.seen[id]; !seen {
		return false
	}
	delete(runtime.seen, id)
	return true
}

func (runtime *pgPubsub) cursor() int64 {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	return runtime.dispatchCursor
}

func (runtime *pgPubsub) swept(dispatchSequence int64) bool {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	return dispatchSequence <= runtime.dispatchCursor
}

// advance records a commit-ordered row and forgets its temporary notification dedup entry.
// Once the cursor covers the row, a delayed notification is rejected by dispatch sequence.
func (runtime *pgPubsub) advance(id, dispatchSequence int64) {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	if dispatchSequence > runtime.dispatchCursor {
		runtime.dispatchCursor = dispatchSequence
	}
	delete(runtime.seen, id)
}

// run is the listener goroutine: wait for the database to be bound, then hold a LISTEN
// connection for as long as the process lives, reconnecting with backoff when it drops.
func (runtime *pgPubsub) run() {
	defer close(runtime.done)
	backoff := pubsubReconnectMinBackoff
	for {
		connection := runtime.database.bound()
		if connection == nil {
			if !runtime.pause(pubsubBindPollInterval) {
				return
			}
			continue
		}
		listened, err := runtime.listenGuarded(connection)
		if listened {
			backoff = pubsubReconnectMinBackoff
		}
		if runtime.ctx.Err() != nil {
			return
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "tesl: pubsub: listener on database %s: %v (reconnecting in %s)\n",
				runtime.database.Name, err, backoff)
		}
		if !runtime.pause(backoff) {
			return
		}
		backoff = min(backoff*2, pubsubReconnectMaxBackoff)
	}
}

// listenGuarded is one connection attempt — prepare, then listen — with any TRAP inside it
// turned into the error the reconnect loop already handles. The listener goroutine is the
// process's only path from other instances' events to its subscribers; an unrecovered panic
// in it (a decode that traps, a driver surprise) would end the whole process rather than
// one connection.
func (runtime *pgPubsub) listenGuarded(connection *PostgresDB) (listened bool, err error) {
	defer func() {
		if trap := recover(); trap != nil {
			listened, err = false, fmt.Errorf("listener trapped: %v", trap)
		}
	}()
	if err := runtime.prepare(connection); err != nil {
		return false, err
	}
	return runtime.listen(connection)
}

// pause sleeps, or answers false if the runtime was closed meanwhile.
func (runtime *pgPubsub) pause(duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-runtime.ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

// listen holds ONE dedicated connection: LISTEN, an immediate catch-up sweep, then a loop
// that waits for a notification and, when none arrives within the sweep interval, sweeps.
// Everything runs on that one connection and one goroutine — a pool lease is never spent on
// delivery, so a saturated pool delays requests, not events.
//
// The connection is opened from the pool's configuration rather than leased from the pool:
// a connection that has issued LISTEN must never be handed to another statement, and it
// lives for the process, which is not what a pool's connections are for. `listened` reports
// whether LISTEN was established, which is what resets the reconnect backoff.
func (runtime *pgPubsub) listen(connection *PostgresDB) (listened bool, err error) {
	connectCtx, cancelConnect := context.WithTimeout(runtime.ctx, pgLeaseTimeout())
	defer cancelConnect()
	conn, err := pgx.ConnectConfig(connectCtx, connection.pool.Config().ConnConfig.Copy())
	if err != nil {
		return false, err
	}
	defer func() {
		closeCtx, cancelClose := context.WithTimeout(context.Background(), pgLeaseTimeout())
		defer cancelClose()
		_ = conn.Close(closeCtx)
		runtime.mutex.Lock()
		runtime.listener = nil
		runtime.mutex.Unlock()
	}()
	if _, err := conn.Exec(connectCtx, "listen "+quoteIdentifier(pubsubNotifyChannel)); err != nil {
		return false, err
	}
	if _, err := conn.Exec(connectCtx, "listen "+quoteIdentifier(queueNotifyChannel)); err != nil {
		return false, err
	}
	runtime.mutex.Lock()
	runtime.listener = conn
	runtime.mutex.Unlock()

	// Rows that committed before LISTEN was in place, and rows a previous connection's
	// last moments missed.
	if err := runtime.sweep(conn, connection); err != nil {
		return true, err
	}
	nextSweep := time.Now().Add(pubsubSweepInterval)
	nextPrune := time.Now().Add(pubsubPruneInterval)
	for {
		waitCtx, cancelWait := context.WithDeadline(runtime.ctx, nextSweep)
		notification, err := conn.WaitForNotification(waitCtx)
		cancelWait()
		switch {
		case err == nil:
			if notification != nil && notification.Channel == queueNotifyChannel {
				runtime.wakeQueues(notification.Payload)
			} else if notification != nil {
				if err := runtime.deliverNotified(conn, connection, notification.Payload); err != nil {
					return true, err
				}
			}
			if time.Now().Before(nextSweep) {
				continue
			}
			fallthrough
		case errors.Is(err, context.DeadlineExceeded) && runtime.ctx.Err() == nil:
			// The wait ran out, which is the sweep's cue; the connection is intact — pgx
			// resets the read deadline on the way out, and a deadline is not a fatal error
			// to it.
			if err := runtime.sweep(conn, connection); err != nil {
				return true, err
			}
			nextSweep = time.Now().Add(pubsubSweepInterval)
			if !time.Now().Before(nextPrune) {
				if err := runtime.prune(conn, connection); err != nil {
					return true, err
				}
				nextPrune = time.Now().Add(pubsubPruneInterval)
			}
		default:
			return true, err
		}
	}
}

// deliverNotified is the notification path: the payload is the row id, and the row is read
// back and delivered unless the sweep got there first. The id is marked seen only once the
// row is in hand — a fetch that fails takes the connection down, and the reconnect's sweep
// must then still deliver the row.
func (runtime *pgPubsub) deliverNotified(conn *pgx.Conn, connection *PostgresDB, payload string) error {
	id, err := strconv.ParseInt(strings.TrimSpace(payload), 10, 64)
	if err != nil {
		// Not one of ours — something else on the cluster shares the channel name.
		return nil
	}
	if runtime.isSeen(id) {
		return nil
	}
	ctx, cancel := context.WithTimeout(runtime.ctx, pgLeaseTimeout())
	defer cancel()
	var channel, key, encoded string
	var dispatchSequence *int64
	err = conn.QueryRow(ctx, `select "channel", "key", "payload"::text, "dispatch_seq" from `+
		connection.QualifiedTable(pubsubOutboxTable)+` where "id" = $1`, id).
		Scan(&channel, &key, &encoded, &dispatchSequence)
	if errors.Is(err, pgx.ErrNoRows) {
		// Pruned already, or a notification for a row this database never held.
		return nil
	}
	if err != nil {
		return err
	}
	if dispatchSequence != nil && runtime.swept(*dispatchSequence) {
		return nil
	}
	if runtime.markSeen(id) {
		runtime.deliver(channel, key, encoded)
	}
	return nil
}

func (runtime *pgPubsub) isSeen(id int64) bool {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	_, seen := runtime.seen[id]
	return seen
}

type pubsubRow struct {
	id               int64
	dispatchSequence int64
	channel, key     string
	encoded          string
}

// dispatchPubsubPending is one bounded dispatcher statement. The materialized lock CTE makes
// every dispatcher wait for the previous assignment transaction to commit before drawing
// sequence values. INSERT does not take this advisory lock and stays unblocked.
func dispatchPubsubPending(ctx context.Context, executor pgExecutor, connection *PostgresDB) (int, error) {
	table := connection.QualifiedTable(pubsubOutboxTable)
	statement := `with lock_acquired as materialized (` +
		`select pg_advisory_xact_lock(hashtextextended(current_database() || ':' || $1, 0))), ` +
		`pending as materialized (` +
		`select "id" from ` + table + `, lock_acquired where "dispatch_seq" is null ` +
		`order by "id" limit $2) ` +
		`update ` + table + ` as outbox set ` +
		`"dispatch_seq" = nextval($3::regclass), "dispatched_at" = clock_timestamp() ` +
		`from pending where outbox."id" = pending."id" and outbox."dispatch_seq" is null`
	tag, err := executor.Exec(ctx, statement, table, int32(pubsubSweepBatch),
		connection.QualifiedTable(pubsubDispatchSeq))
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

type pubsubSweepStats struct {
	dispatchQueries int
	fetchQueries    int
	rowsRead        int
}

// sweepWithStats performs bounded work: each stage issues at most
// pubsubSweepMaxBatches queries and each query handles at most pubsubSweepBatch rows.
func (runtime *pgPubsub) sweepWithStats(conn *pgx.Conn, connection *PostgresDB) (pubsubSweepStats, error) {
	stats := pubsubSweepStats{}
	for range pubsubSweepMaxBatches {
		ctx, cancel := context.WithTimeout(runtime.ctx, pgLeaseTimeout())
		dispatched, err := dispatchPubsubPending(ctx, conn, connection)
		cancel()
		stats.dispatchQueries++
		if err != nil {
			return stats, err
		}
		if dispatched < pubsubSweepBatch {
			break
		}
	}
	for range pubsubSweepMaxBatches {
		ctx, cancel := context.WithTimeout(runtime.ctx, pgLeaseTimeout())
		rows, err := conn.Query(ctx, `select "id", "channel", "key", "payload"::text, "dispatch_seq" from `+
			connection.QualifiedTable(pubsubOutboxTable)+
			` where "dispatch_seq" > $1 order by "dispatch_seq" limit $2`,
			runtime.cursor(), pubsubSweepBatch)
		stats.fetchQueries++
		if err != nil {
			cancel()
			return stats, err
		}
		batch, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (pubsubRow, error) {
			var collected pubsubRow
			err := row.Scan(&collected.id, &collected.channel, &collected.key, &collected.encoded,
				&collected.dispatchSequence)
			return collected, err
		})
		cancel()
		if err != nil {
			return stats, err
		}
		stats.rowsRead += len(batch)
		for _, row := range batch {
			if !runtime.takeSeen(row.id) {
				runtime.deliver(row.channel, row.key, row.encoded)
			}
			runtime.advance(row.id, row.dispatchSequence)
		}
		if len(batch) < pubsubSweepBatch {
			break
		}
	}
	return stats, nil
}

func (runtime *pgPubsub) sweep(conn *pgx.Conn, connection *PostgresDB) error {
	_, err := runtime.sweepWithStats(conn, connection)
	return err
}

// prune deletes rows past the retention. Every instance prunes; the statement is idempotent
// and cheap, and electing one pruner would be a coordination problem for no gain.
func (runtime *pgPubsub) prune(conn *pgx.Conn, connection *PostgresDB) error {
	ctx, cancel := context.WithTimeout(runtime.ctx, pgLeaseTimeout())
	defer cancel()
	_, err := conn.Exec(ctx, `delete from `+connection.QualifiedTable(pubsubOutboxTable)+
		` where "dispatched_at" < now() - make_interval(secs => $1)`,
		pubsubOutboxRetention.Seconds())
	return err
}

// listenerPID answers the backend process id of the live LISTEN connection, or zero between
// connections — what a test needs to kill it.
// ListenerPID is the backend pid of this process's LISTEN connection (0 while disconnected);
// exported for the runtime's own tests, which terminate it to exercise the reconnect.
func (runtime *pgPubsub) ListenerPID() uint32 {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	if runtime.listener == nil {
		return 0
	}
	return runtime.listener.PgConn().PID()
}

// close ends the listener goroutine and forgets the runtime, for a test that stood one up.
// A program never calls it: the listener lives as long as the process.
// Close stops the LISTEN loop and waits for it; exported for the runtime's own tests.
func (runtime *pgPubsub) Close() {
	runtime.cancel()
	pgPubsubs.CompareAndDelete(runtime.database, runtime)
	select {
	case <-runtime.done:
	case <-time.After(2 * pgLeaseTimeout()):
	}
}
