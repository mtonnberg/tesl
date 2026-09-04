package teslrt

import (
	"bufio"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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
	if runtime := pubsubRuntimeOf(t, database); runtime.ListenerPID() != 0 || runtime.cursor() != 0 {
		t.Fatal("an unbound database started a listener")
	}
}
