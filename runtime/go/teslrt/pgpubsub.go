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
// STARTUP BASELINE. A process that starts (or reconnects after a long outage) does NOT replay
// the outbox to its subscribers: the sweep begins at `max(id)` as of the moment the process
// prepared the outbox. SSE has no backlog semantics — an event published before a browser
// connected is gone on the Memory path too — and replaying an hour of history to every fresh
// deploy would be a flood of stale events, not a feature. The outbox is a delivery buffer for
// LIVE instances, retained one hour so a slow sweep or a brief disconnect misses nothing.

const (
	pubsubNotifyChannel = "tesl_pubsub"
	// queueNotifyChannel carries the QUEUE NAME as payload: one channel for every queue on the
	// database, so the listener connection is shared, and the payload says whose doorbell to
	// ring.
	queueNotifyChannel = "tesl_queue"
	pubsubOutboxTable  = "tesl_pubsub_outbox"
	// pubsubSweepBatch bounds one sweep query; a sweep that fills the batch runs again at once.
	pubsubSweepBatch = 500
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
	// pubsubSeenRetention is how long an id delivered by one path is remembered so the other
	// path (a sweep after a notification, or a notification after a sweep) does not deliver
	// it twice. PostgreSQL hands a listener the notification for a row at the end of whatever
	// command it is running when the row commits, so the notification for a row the sweep
	// just read arrives right AFTER the sweep's own query — the id must outlive that moment.
	pubsubSeenRetention = 30 * time.Second
)

// pgPubsub is one process's pub/sub state for one `Database` declaration: the channels
// declared on it, the LISTEN goroutine, and the sweep cursor.
type pgPubsub struct {
	database *Database

	mutex sync.Mutex
	// channels by declared NAME. A name normally has one channel; a test standing two
	// channels in for two instances registers two, and both receive.
	channels map[string][]*SseChannel
	// queues by declared name, woken on a `tesl_queue` notification naming them.
	queues map[string][]*Queue
	// ready is set once the outbox table exists and the sweep baseline is captured.
	ready bool
	// lastDelivered is the sweep cursor: every committed row with a lower id has been
	// delivered by the sweep, or was already there when this process started.
	lastDelivered int64
	// seen remembers ids delivered by either path, for pubsubSeenRetention.
	seen map[int64]time.Time
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
		seen:     map[int64]time.Time{},
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
// that the sweep baseline is captured before this process inserts its first row: a row this
// process publishes must have an id above the baseline, or the sweep would never reach it
// should its notification be lost.
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

// prepare creates the outbox if it is absent and captures the sweep baseline, once per
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
	var baseline int64
	if err := connection.pool.QueryRow(ctx,
		`select coalesce(max("id"), 0) from `+connection.QualifiedTable(pubsubOutboxTable)).
		Scan(&baseline); err != nil {
		return err
	}
	runtime.lastDelivered = baseline
	runtime.ready = true
	return nil
}

// createPubsubOutbox is `create table if not exists`, tolerating the one way that statement
// can still fail: two processes creating the same absent table at the same instant, where the
// loser sees a duplicate-key error on the catalogue rather than "already exists". The retry
// then finds the table.
func createPubsubOutbox(ctx context.Context, connection *PostgresDB) error {
	statement := fmt.Sprintf(`create table if not exists %s (
	"id" bigserial primary key,
	"channel" text not null,
	"key" text not null,
	"payload" jsonb not null,
	"created_at" timestamptz not null default now()
)`, connection.QualifiedTable(pubsubOutboxTable))
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		if _, err = connection.pool.Exec(ctx, statement); err == nil {
			return nil
		}
		message := err.Error()
		if !strings.Contains(message, "duplicate key") && !strings.Contains(message, "already exists") {
			return err
		}
	}
	return err
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

// markSeen records an id as delivered, answering false when it already was.
func (runtime *pgPubsub) markSeen(id int64) bool {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	if _, already := runtime.seen[id]; already {
		return false
	}
	runtime.seen[id] = time.Now()
	return true
}

// advance moves the sweep cursor and forgets ids old enough that neither path can still
// present them.
func (runtime *pgPubsub) advance(id int64) {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	if id > runtime.lastDelivered {
		runtime.lastDelivered = id
	}
	horizon := time.Now().Add(-pubsubSeenRetention)
	for seen, at := range runtime.seen {
		if seen <= runtime.lastDelivered && at.Before(horizon) {
			delete(runtime.seen, seen)
		}
	}
}

func (runtime *pgPubsub) cursor() int64 {
	runtime.mutex.Lock()
	defer runtime.mutex.Unlock()
	return runtime.lastDelivered
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
	err = conn.QueryRow(ctx, `select "channel", "key", "payload"::text from `+
		connection.QualifiedTable(pubsubOutboxTable)+` where "id" = $1`, id).
		Scan(&channel, &key, &encoded)
	if errors.Is(err, pgx.ErrNoRows) {
		// Pruned already, or a notification for a row this database never held.
		return nil
	}
	if err != nil {
		return err
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
	id           int64
	channel, key string
	encoded      string
}

// sweep delivers every committed row above the cursor, in id order, in batches. A row the
// notification path already delivered is skipped by id; the cursor advances past it either
// way.
//
// A row whose transaction commits LATE — its id was assigned before a higher id that has
// already committed and been swept past — is below the cursor by the time it is visible, so
// the sweep never sees it; its notification, sent at its commit, is what delivers it. Losing
// both the notification and that ordering at once is the one case this does not recover.
func (runtime *pgPubsub) sweep(conn *pgx.Conn, connection *PostgresDB) error {
	for {
		ctx, cancel := context.WithTimeout(runtime.ctx, pgLeaseTimeout())
		rows, err := conn.Query(ctx, `select "id", "channel", "key", "payload"::text from `+
			connection.QualifiedTable(pubsubOutboxTable)+` where "id" > $1 order by "id" limit $2`,
			runtime.cursor(), pubsubSweepBatch)
		if err != nil {
			cancel()
			return err
		}
		batch, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (pubsubRow, error) {
			var collected pubsubRow
			err := row.Scan(&collected.id, &collected.channel, &collected.key, &collected.encoded)
			return collected, err
		})
		cancel()
		if err != nil {
			return err
		}
		for _, row := range batch {
			if runtime.markSeen(row.id) {
				runtime.deliver(row.channel, row.key, row.encoded)
			}
			runtime.advance(row.id)
		}
		if len(batch) < pubsubSweepBatch {
			return nil
		}
	}
}

// prune deletes rows past the retention. Every instance prunes; the statement is idempotent
// and cheap, and electing one pruner would be a coordination problem for no gain.
func (runtime *pgPubsub) prune(conn *pgx.Conn, connection *PostgresDB) error {
	ctx, cancel := context.WithTimeout(runtime.ctx, pgLeaseTimeout())
	defer cancel()
	_, err := conn.Exec(ctx, `delete from `+connection.QualifiedTable(pubsubOutboxTable)+
		` where "created_at" < now() - make_interval(secs => $1)`,
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
