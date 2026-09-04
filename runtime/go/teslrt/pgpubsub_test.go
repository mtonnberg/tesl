package teslrt

import (
	"bufio"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The cross-instance path is under test here, so every live test stands up TWO `Database`
// values on the same cluster and schema — each with its own runtime, its own LISTEN
// connection and its own channel — which is exactly what two replicas behind a load balancer
// are. A publish on one must reach a listener on the other, through the outbox and NOTIFY,
// never through the process's memory.

// pubsubDatabase is one instance's declaration of the same database: same cluster, same
// schema, a distinct `Database` value.
func pubsubDatabase(t *testing.T, name string) *Database {
	t.Helper()
	database := &Database{Name: name, Config: liveCluster(t)}
	t.Cleanup(func() {
		if runtime, found := pgPubsubs.Load(database); found {
			runtime.(*pgPubsub).Close()
		}
	})
	return database
}

// shrinkPubsubIntervals makes the sweep and the reconnect fast enough to observe, and puts
// them back once every runtime the test started has stopped (the cleanup order is LIFO, so
// this restore runs after the runtimes' close).
func shrinkPubsubIntervals(t *testing.T) {
	t.Helper()
	sweep, poll, minBackoff := pubsubSweepInterval, pubsubBindPollInterval, pubsubReconnectMinBackoff
	pubsubSweepInterval = 200 * time.Millisecond
	pubsubBindPollInterval = 20 * time.Millisecond
	pubsubReconnectMinBackoff = 50 * time.Millisecond
	t.Cleanup(func() {
		pubsubSweepInterval, pubsubBindPollInterval, pubsubReconnectMinBackoff = sweep, poll, minBackoff
	})
}

func pubsubRuntimeOf(t *testing.T, database *Database) *pgPubsub {
	t.Helper()
	found, ok := pgPubsubs.Load(database)
	if !ok {
		t.Fatal("no pub/sub runtime registered for the database")
	}
	return found.(*pgPubsub)
}

// awaitListener waits until the instance's LISTEN connection is up, and answers its backend
// pid.
func awaitListener(t *testing.T, database *Database) uint32 {
	t.Helper()
	runtime := pubsubRuntimeOf(t, database)
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if pid := runtime.ListenerPID(); pid != 0 {
			return pid
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("the LISTEN connection of %s never came up", database.Name)
	return 0
}

// expectEvent waits for one event on a directly registered listener.
func expectEvent(t *testing.T, listener *sseListener, timeout time.Duration) any {
	t.Helper()
	select {
	case event := <-listener.events:
		return event
	case <-time.After(timeout):
		t.Fatal("no event was delivered")
		return nil
	}
}

func expectNoEvent(t *testing.T, listener *sseListener, within time.Duration) {
	t.Helper()
	select {
	case event := <-listener.events:
		t.Fatalf("an event was delivered: %s", EncodeJSONValue(event))
	case <-time.After(within):
	}
}

func pubsubOutboxTableOf(database *Database) string {
	binding := database.bound()
	if binding == nil {
		panic("pubsubOutboxTableOf: database is not bound")
	}
	return binding.QualifiedTable(pubsubOutboxTable)
}

// (a) Two instances. A browser subscribed on B receives what a handler on A publishes — and
// A's own subscriber receives it through the same path, exactly once.
func TestPubsubPublishOnOneInstanceReachesAListenerOnAnother(t *testing.T) {
	shrinkPubsubIntervals(t)
	instanceA := pubsubDatabase(t, "InstanceA")
	instanceB := pubsubDatabase(t, "InstanceB")
	channelA := NewSseChannelOn(instanceA, "RunEvents")
	channelB := NewSseChannelOn(instanceB, "RunEvents")
	WithDatabase(instanceA, func() {
		WithDatabase(instanceB, func() {
			onB := channelB.register("run-1")
			defer channelB.unregister("run-1", onB)
			onA := channelA.register("run-1")
			defer channelA.unregister("run-1", onA)
			elsewhere := channelB.register("run-2")
			defer channelB.unregister("run-2", elsewhere)
			awaitListener(t, instanceA)
			awaitListener(t, instanceB)

			Publish(channelA, "run-1", eventPayload("runId", "run-1"))

			for name, listener := range map[string]*sseListener{"B": onB, "A": onA} {
				event := expectEvent(t, listener, 5*time.Second)
				if got := EncodeJSONValue(event); got != `{"runId":"run-1"}` {
					t.Fatalf("instance %s received %s", name, got)
				}
				expectNoEvent(t, listener, 600*time.Millisecond)
			}
			expectNoEvent(t, elsewhere, 100*time.Millisecond)
		})
	})
}

// (b) A publish inside a transaction is part of it: rolled back, it reaches nobody on any
// instance; committed, it reaches every listener exactly once.
func TestPubsubPublishInsideATransactionFollowsTheCommit(t *testing.T) {
	shrinkPubsubIntervals(t)
	instanceA := pubsubDatabase(t, "InstanceA")
	instanceB := pubsubDatabase(t, "InstanceB")
	channelA := NewSseChannelOn(instanceA, "Orders")
	channelB := NewSseChannelOn(instanceB, "Orders")
	WithDatabase(instanceB, func() {
		WithDatabase(instanceA, func() {
			onA := channelA.register("all")
			defer channelA.unregister("all", onA)
			onB := channelB.register("all")
			defer channelB.unregister("all", onB)
			awaitListener(t, instanceA)
			awaitListener(t, instanceB)

			func() {
				defer func() {
					if recover() == nil {
						t.Fatal("the transaction body's panic did not propagate")
					}
				}()
				WithTransaction(func() {
					Publish(channelA, "all", eventPayload("order", "rolled-back"))
					panic("the handler failed after publishing")
				})
			}()
			// Longer than several sweeps: neither the notification nor the sweep may find
			// a row that never committed.
			expectNoEvent(t, onA, time.Second)
			expectNoEvent(t, onB, 100*time.Millisecond)

			WithTransaction(func() {
				Publish(channelA, "all", eventPayload("order", "committed"))
			})
			for name, listener := range map[string]*sseListener{"A": onA, "B": onB} {
				event := expectEvent(t, listener, 5*time.Second)
				if got := EncodeJSONValue(event); got != `{"order":"committed"}` {
					t.Fatalf("instance %s received %s", name, got)
				}
				expectNoEvent(t, listener, 600*time.Millisecond)
			}
		})
	})
}

// (c) A lost notification. A row that reaches the outbox with no NOTIFY at all — here,
// inserted directly — is still delivered by the catch-up sweep.
func TestPubsubSweepDeliversARowWhoseNotificationWasLost(t *testing.T) {
	shrinkPubsubIntervals(t)
	instance := pubsubDatabase(t, "Instance")
	channel := NewSseChannelOn(instance, "Alerts")
	WithDatabase(instance, func() {
		listener := channel.register("ops")
		defer channel.unregister("ops", listener)
		awaitListener(t, instance)
		// The baseline is captured on the publish path or by the listener's start; make
		// sure the outbox exists and the cursor is set before the row goes in behind the
		// notification's back.
		if err := pubsubRuntimeOf(t, instance).prepare(instance.bound()); err != nil {
			t.Fatalf("prepare: %v", err)
		}

		PgExec(instance.bound(), `insert into `+pubsubOutboxTableOf(instance)+
			` ("channel", "key", "payload") values ($1, $2, $3::jsonb)`,
			[]any{"Alerts", "ops", `{"level":"red"}`})

		event := expectEvent(t, listener, 5*time.Second)
		if got := EncodeJSONValue(event); got != `{"level":"red"}` {
			t.Fatalf("the sweep delivered %s", got)
		}
		expectNoEvent(t, listener, 600*time.Millisecond)
	})
}

// A publisher holds the dispatch lock until commit. A concurrent publisher cannot allocate a
// later sequence and commit first, so another instance observes the transactions in lock/commit
// order rather than allocation-id or notification order.
func TestPubsubCrossInstanceDeliveryFollowsSerializedCommitOrder(t *testing.T) {
	shrinkPubsubIntervals(t)
	instanceA := pubsubDatabase(t, "InstanceA")
	instanceB := pubsubDatabase(t, "InstanceB")
	channelA := NewSseChannelOn(instanceA, "Ordered")
	channelB := NewSseChannelOn(instanceB, "Ordered")
	WithDatabase(instanceA, func() {
		WithDatabase(instanceB, func() {
			listener := channelB.register("all")
			defer channelB.unregister("all", listener)
			awaitListener(t, instanceA)
			awaitListener(t, instanceB)
			db := instanceA.bound()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			first, err := db.pool.Begin(ctx)
			if err != nil {
				t.Fatalf("begin first publisher: %v", err)
			}
			defer func() { _ = first.Rollback(context.Background()) }()
			if _, err := writePubsub(ctx, first, db, channelA.name, "all", `{"order":"first"}`); err != nil {
				t.Fatalf("write first publisher: %v", err)
			}

			secondDone := make(chan error, 1)
			go func() {
				second, beginErr := db.pool.Begin(ctx)
				if beginErr != nil {
					secondDone <- beginErr
					return
				}
				defer func() { _ = second.Rollback(context.Background()) }()
				if _, writeErr := writePubsub(ctx, second, db, channelA.name, "all", `{"order":"second"}`); writeErr != nil {
					secondDone <- writeErr
					return
				}
				secondDone <- second.Commit(ctx)
			}()
			select {
			case err := <-secondDone:
				t.Fatalf("second publisher passed the first transaction's lock: %v", err)
			case <-time.After(100 * time.Millisecond):
			}
			if err := first.Commit(ctx); err != nil {
				t.Fatalf("commit first publisher: %v", err)
			}
			if err := <-secondDone; err != nil {
				t.Fatalf("second publisher: %v", err)
			}

			for index, want := range []string{`{"order":"first"}`, `{"order":"second"}`} {
				if got := EncodeJSONValue(expectEvent(t, listener, 5*time.Second)); got != want {
					t.Fatalf("event %d was %s, want %s", index+1, got, want)
				}
			}
			expectNoEvent(t, listener, 600*time.Millisecond)
		})
	})
}

// Retained history does not become periodic work. A backlog larger than the former four-batch
// ceiling drains in one call, while each iteration reads and upgrades at most one bounded batch.
func TestPubsubSustainedBacklogConvergesWithBoundedIterations(t *testing.T) {
	database := storeDatabase(t, "SweepScale")
	WithDatabase(database, func() {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		runtime := &pgPubsub{
			database: database,
			channels: map[string][]*SseChannel{},
			queues:   map[string][]*Queue{},
			ctx:      ctx,
		}
		db := database.bound()
		if err := runtime.prepare(db); err != nil {
			t.Fatalf("prepare: %v", err)
		}
		conn, err := pgx.ConnectConfig(ctx, db.pool.Config().ConnConfig.Copy())
		if err != nil {
			t.Fatalf("connect sweep session: %v", err)
		}
		defer func() { _ = conn.Close(context.Background()) }()
		table := db.QualifiedTable(pubsubOutboxTable)
		channelName := uniqueName("sweep_scale")
		const retained = 10 * pubsubSweepBatch
		transaction, err := db.pool.Begin(ctx)
		if err != nil {
			t.Fatalf("begin fixture: %v", err)
		}
		if _, err := transaction.Exec(ctx,
			`select pg_advisory_xact_lock(hashtextextended(current_database() || ':' || $1, 0))`, table); err != nil {
			t.Fatalf("lock fixture: %v", err)
		}
		if _, err := transaction.Exec(ctx, `insert into `+table+
			` ("channel", "key", "payload", "dispatch_seq", "dispatched_at") `+
			`select $1, 'all', '{"scale":true}'::jsonb, nextval($2::regclass), clock_timestamp() `+
			`from generate_series(1, $3)`, channelName, db.QualifiedTable(pubsubDispatchSeq), int32(retained)); err != nil {
			t.Fatalf("insert fixture: %v", err)
		}
		if err := transaction.Commit(ctx); err != nil {
			t.Fatalf("commit fixture: %v", err)
		}
		const legacyRetained = 2*pubsubSweepBatch + 1
		PgExec(db, `insert into `+table+` ("channel", "key", "payload") `+
			`select $1, 'all', '{"scale":"legacy"}'::jsonb from generate_series(1, $2)`,
			[]any{channelName, int32(legacyRetained)})

		stats, err := runtime.drainWithStats(conn, db)
		if err != nil {
			t.Fatalf("catch-up drain: %v", err)
		}
		if stats.rowsRead != retained+legacyRetained || stats.legacyRows != legacyRetained || stats.iterations <= 4 {
			t.Fatalf("backlog did not drain continuously: %+v", stats)
		}
		if stats.maxLegacyBatch > pubsubSweepBatch || stats.maxDeliveryBatch > pubsubSweepBatch ||
			stats.dispatchQueries != 3 || stats.legacyChecks != stats.dispatchQueries+1 ||
			stats.fetchQueries != stats.iterations {
			t.Fatalf("an iteration exceeded its query or memory bound: %+v", stats)
		}
		ahead, _ := PgCount(db, `select count(*) from `+table+
			` where "channel" = $1 and "dispatch_seq" > $2`,
			[]any{channelName, runtime.cursor()}).Int64()
		if ahead != 0 {
			t.Fatalf("drain left %d rows ahead of its cursor", ahead)
		}

		quiet, err := runtime.drainWithStats(conn, db)
		if err != nil {
			t.Fatalf("quiet drain: %v", err)
		}
		if quiet.dispatchQueries != 0 || quiet.legacyChecks != 1 || quiet.fetchQueries != 1 || quiet.rowsRead != 0 {
			t.Fatalf("quiet drain over %d retained rows did %+v work", retained, quiet)
		}

		oneTransaction, err := db.pool.Begin(ctx)
		if err != nil {
			t.Fatalf("begin one-row fixture: %v", err)
		}
		if _, err := writePubsub(ctx, oneTransaction, db, channelName, "all", `{"scale":"new"}`); err != nil {
			t.Fatalf("write one-row fixture: %v", err)
		}
		if err := oneTransaction.Commit(ctx); err != nil {
			t.Fatalf("commit one-row fixture: %v", err)
		}
		one, err := runtime.drainWithStats(conn, db)
		if err != nil {
			t.Fatalf("one-row drain: %v", err)
		}
		if one.dispatchQueries != 0 || one.legacyChecks != 1 || one.fetchQueries != 1 || one.rowsRead != 1 {
			t.Fatalf("one new row over %d retained rows did %+v work", retained, one)
		}
		kept, _ := PgCount(db, `select count(*) from `+table+` where "channel" = $1`,
			[]any{channelName}).Int64()
		if kept != retained+legacyRetained+1 {
			t.Fatalf("scaling fixture retained %d rows, want %d", kept, retained+legacyRetained+1)
		}
		PgExec(db, `delete from `+table+` where "channel" = $1`, []any{channelName})
	})
}

func TestPubsubPreparationUpgradesTheRuntimeOutboxIdempotently(t *testing.T) {
	config := liveCluster(t)
	config.Schema = uniqueName("pubsub_upgrade")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	legacy, err := pgx.Connect(ctx, postgresDSN(config))
	if err != nil {
		t.Fatalf("connect legacy fixture: %v", err)
	}
	defer func() { _ = legacy.Close(context.Background()) }()
	if _, err := legacy.Exec(ctx, `create schema `+quoteIdentifier(config.Schema)); err != nil {
		t.Fatalf("create legacy schema: %v", err)
	}
	table := quoteIdentifier(config.Schema) + "." + quoteIdentifier(pubsubOutboxTable)
	if _, err := legacy.Exec(ctx, `create table `+table+` (`+
		`"id" bigserial primary key, "channel" text not null, "key" text not null, `+
		`"payload" jsonb not null, "created_at" timestamptz not null default now())`); err != nil {
		t.Fatalf("create legacy outbox: %v", err)
	}
	if _, err := legacy.Exec(ctx, `insert into `+table+
		` ("channel", "key", "payload") values ('Old', 'all', '{}'::jsonb)`); err != nil {
		t.Fatalf("insert legacy row: %v", err)
	}
	db := OpenPostgres(config, nil)
	_ = OpenPostgres(config, nil)
	runtimeCtx, runtimeCancel := context.WithCancel(context.Background())
	defer runtimeCancel()
	runtime := &pgPubsub{
		database: &Database{Name: "Upgrade", Config: config},
		channels: map[string][]*SseChannel{},
		queues:   map[string][]*Queue{},
		ctx:      runtimeCtx,
	}
	if err := runtime.prepare(db); err != nil {
		t.Fatalf("first prepare: %v", err)
	}
	if err := runtime.prepare(db); err != nil {
		t.Fatalf("second prepare: %v", err)
	}
	ready, _ := PgCount(db, `select count(*) from `+table+
		` where "dispatch_seq" is not null and "dispatched_at" is not null`, nil).Int64()
	if ready != 1 || runtime.cursor() == 0 {
		t.Fatalf("upgraded outbox: ready=%d cursor=%d", ready, runtime.cursor())
	}
}

// (d) The LISTEN connection dies. The instance reconnects, and an event published while it
// was down is delivered by the reconnect's catch-up sweep; one published afterwards arrives
// through the new connection.
func TestPubsubListenerReconnectsWhenItsConnectionIsKilled(t *testing.T) {
	shrinkPubsubIntervals(t)
	instance := pubsubDatabase(t, "Instance")
	channel := NewSseChannelOn(instance, "Ticks")
	WithDatabase(instance, func() {
		listener := channel.register("clock")
		defer channel.unregister("clock", listener)
		pid := awaitListener(t, instance)

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var terminated bool
		if err := instance.bound().pool.QueryRow(ctx, "select pg_terminate_backend($1)", int32(pid)).
			Scan(&terminated); err != nil || !terminated {
			t.Fatalf("terminate backend %d: %v (%v)", pid, err, terminated)
		}
		Publish(channel, "clock", eventPayload("tick", "while-down"))

		deadline := time.Now().Add(10 * time.Second)
		runtime := pubsubRuntimeOf(t, instance)
		for {
			if again := runtime.ListenerPID(); again != 0 && again != pid {
				break
			}
			if !time.Now().Before(deadline) {
				t.Fatal("the listener did not reconnect")
			}
			time.Sleep(10 * time.Millisecond)
		}
		event := expectEvent(t, listener, 5*time.Second)
		if got := EncodeJSONValue(event); got != `{"tick":"while-down"}` {
			t.Fatalf("after the reconnect the listener received %s", got)
		}

		Publish(channel, "clock", eventPayload("tick", "after"))
		event = expectEvent(t, listener, 5*time.Second)
		if got := EncodeJSONValue(event); got != `{"tick":"after"}` {
			t.Fatalf("the reconnected listener received %s", got)
		}
		expectNoEvent(t, listener, 600*time.Millisecond)
	})
}

// (e) The wire format. An event that travelled through the outbox is written to the browser
// byte for byte as the same event on a Memory channel is — the payload here exercises every
// JSON shape the codecs produce (an unbounded Int, a Float, escaped text, a nested object, an
// array, a null and booleans), so a round trip through jsonb that changed a digit or a key
// order would show.
func TestPubsubDeliveredEventKeepsTheMemoryWireFormat(t *testing.T) {
	shrinkPubsubIntervals(t)
	payload := map[string]any{
		"runId": "run-<&>-ünïcode",
		"count": FromInt64(1234567890123456789),
		"ratio": 0.1,
		"nested": map[string]any{
			"z":     true,
			"a":     nil,
			"items": []any{FromInt64(1), "two", 3.5, false},
		},
	}
	streamLine := func(channel *SseChannel) string {
		server := httptest.NewServer(http.HandlerFunc(SseStream(channel, "all")))
		defer server.Close()
		response, err := http.Get(server.URL) //nolint:noctx // the test closes the server
		if err != nil || response == nil {
			t.Fatalf("connect: %v", err)
		}
		defer func() { _ = response.Body.Close() }()
		reader := bufio.NewReader(response.Body)
		if line, err := reader.ReadString('\n'); err != nil || strings.TrimRight(line, "\r\n") != ": ok" {
			t.Fatalf("the stream opened with %q (%v)", line, err)
		}
		waitForListeners(t, channel, "all", 1)
		Publish(channel, "all", payload)
		return readDataLine(t, reader)
	}

	memoryLine := streamLine(NewSseChannel("RunEvents"))

	instance := pubsubDatabase(t, "Instance")
	channel := NewSseChannelOn(instance, "RunEvents")
	var outboxLine string
	WithDatabase(instance, func() {
		awaitListener(t, instance)
		outboxLine = streamLine(channel)
	})
	if outboxLine != memoryLine {
		t.Fatalf("the outbox path wrote\n  %s\nwhere the Memory path wrote\n  %s", outboxLine, memoryLine)
	}
	for _, want := range []string{`"count":1234567890123456789`, `"ratio":0.1`, `"a":null`} {
		if !strings.Contains(outboxLine, want) {
			t.Fatalf("the event line %q is missing %q", outboxLine, want)
		}
	}
}

// Off a binding a Postgres-declared channel is a Memory channel: a `test` block over the
// program runs with no cluster anywhere, and its publishes reach the block's subscribers
// directly. This test needs no cluster either.
func TestPubsubChannelOnAnUnboundDatabaseDeliversLocally(t *testing.T) {
	database := &Database{Name: "Unbound"}
	channel := NewSseChannelOn(database, "RunEvents")
	t.Cleanup(pubsubRuntimeOf(t, database).Close)
	listener := channel.register("all")
	defer channel.unregister("all", listener)

	Publish(channel, "all", eventPayload("runId", "run-abc"))

	event := expectEvent(t, listener, time.Second)
	if got := EncodeJSONValue(event); got != `{"runId":"run-abc"}` {
		t.Fatalf("the unbound channel delivered %s", got)
	}
	// The listener goroutine is idle, polling for a binding that never comes; it must not
	// have touched anything.
	if runtime := pubsubRuntimeOf(t, database); runtime.ListenerPID() != 0 {
		t.Fatal("an unbound database started a listener")
	}
}

// A timer can expire while a publishing transaction holds the dispatch lock and its NOTIFY is
// waiting for commit. Both wakeups must feed one cursor rather than independently delivering.
func TestPubsubNotificationAndPeriodicDrainDoNotDoubleDeliver(t *testing.T) {
	shrinkPubsubIntervals(t)
	previous := pubsubSweepInterval
	pubsubSweepInterval = 5 * time.Millisecond
	t.Cleanup(func() { pubsubSweepInterval = previous })
	instance := pubsubDatabase(t, "Instance")
	channel := NewSseChannelOn(instance, "Race")
	WithDatabase(instance, func() {
		listener := channel.register("all")
		defer channel.unregister("all", listener)
		awaitListener(t, instance)
		const published = 48
		WithTransaction(func() {
			for number := range published {
				Publish(channel, "all", eventPayload("n", fmt.Sprintf("%02d", number)))
			}
			// Let periodic recovery run before the commit's NOTIFY wakes the same path.
			time.Sleep(2 * pubsubSweepInterval)
		})
		for number := range published {
			want := fmt.Sprintf(`{"n":"%02d"}`, number)
			if got := EncodeJSONValue(expectEvent(t, listener, 5*time.Second)); got != want {
				t.Fatalf("event %d was %s, want %s", number+1, got, want)
			}
		}
		expectNoEvent(t, listener, 100*time.Millisecond)
	})
}

// The runtime starts unprepared and the caller already owns the pool's sole connection. Baseline
// capture and publishing must stay on that transaction rather than lazily leasing another one.
func TestPubsubFirstTransactionalPublishUsesPoolSizeOne(t *testing.T) {
	config := liveCluster(t)
	config.Schema = uniqueName("pubsub_pool_one")
	config.PoolSize = 1
	database := &Database{Name: "PoolOne", Config: config}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime := &pgPubsub{
		database: database,
		channels: map[string][]*SseChannel{},
		queues:   map[string][]*Queue{},
		ctx:      ctx,
	}
	channel := NewSseChannel("FirstPublish")
	channel.backend = runtime
	runtime.channels[channel.name] = []*SseChannel{channel}
	listener := channel.register("all")
	defer channel.unregister("all", listener)

	WithDatabase(database, func() {
		if runtime.ready {
			t.Fatal("fixture runtime was prepared before its first transactional publish")
		}
		WithTransaction(func() {
			Publish(channel, "all", eventPayload("pool", "one"))
		})
		conn, err := pgx.ConnectConfig(ctx, database.bound().pool.Config().ConnConfig.Copy())
		if err != nil {
			t.Fatalf("connect delivery session: %v", err)
		}
		defer func() { _ = conn.Close(context.Background()) }()
		if err := runtime.drain(conn, database.bound()); err != nil {
			t.Fatalf("drain: %v", err)
		}
		if got := EncodeJSONValue(expectEvent(t, listener, time.Second)); got != `{"pool":"one"}` {
			t.Fatalf("first transactional publish delivered %s", got)
		}
	})
}
