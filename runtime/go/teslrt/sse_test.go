package teslrt

import (
	"bufio"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func eventPayload(field, value string) map[string]any {
	return map[string]any{field: value}
}

// A server shaped like an emitted one: a broadcast stream on a fixed key, and a per-entity
// stream keyed on a path segment.
func streamServer(channel *SseChannel) Server {
	return Server{
		Routes: []Route{
			{Method: "GET", Path: "/stream", Endpoint: "sse:/stream"},
			{Method: "GET", Path: "/events/:userId", Endpoint: "sse:/events/:userId"},
		},
		Handlers: map[string]HandlerFunc{},
		Streams: map[string]StreamFunc{
			"sse:/stream":         SseStream(channel, "all"),
			"sse:/events/:userId": SseStreamParam(channel, "/events/:userId", "userId"),
		},
	}
}

// waitForListeners blocks until the connection the test just opened has registered, so a
// publish cannot race the subscription it is meant to reach.
func waitForListeners(t *testing.T, channel *SseChannel, key string, want int) {
	t.Helper()
	for attempt := 0; attempt < 200; attempt++ {
		if channelListenerCount(channel, key) >= want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("only %d listeners registered on %q, want %d",
		channelListenerCount(channel, key), key, want)
}

func channelListenerCount(channel *SseChannel, key string) int {
	channel.mutex.Lock()
	defer channel.mutex.Unlock()
	return len(channel.listeners[key])
}

func TestSubscribeReceivesAPublishedEvent(t *testing.T) {
	channel := NewSseChannel("RunEvents")
	stream := SubscribeStream(streamServer(channel), "/stream", nil)
	defer UnsubscribeStream(stream)
	waitForListeners(t, channel, "all", 1)

	Publish(channel, "all", eventPayload("runId", "run-abc"))

	events := CollectCount(stream, FromInt64(1), FromInt64(2000))
	if !JsonIsNotEmpty(events) {
		t.Fatal("the subscriber received nothing")
	}
	// What a test collects is the PAYLOAD, not the envelope the wire carries.
	if !JsonIncludesWhere(map[string]any{"runId": "run-abc"}, events) {
		t.Fatalf("the event is %s", EncodeJSONValue(events.JsonRaw()))
	}
}

// The channel KEY is what makes a channel per-entity: a publish for one key reaches only the
// connections on that key.
func TestPublishReachesOnlyItsOwnKey(t *testing.T) {
	channel := NewSseChannel("Notices")
	server := streamServer(channel)
	watching := SubscribeStream(server, "/events/ada", nil)
	defer UnsubscribeStream(watching)
	elsewhere := SubscribeStream(server, "/events/grace", nil)
	defer UnsubscribeStream(elsewhere)
	waitForListeners(t, channel, "ada", 1)
	waitForListeners(t, channel, "grace", 1)

	Publish(channel, "ada", eventPayload("note", "for ada"))

	if events := CollectCount(watching, FromInt64(1), FromInt64(2000)); !JsonIsNotEmpty(events) {
		t.Fatal("the subscriber on that key received nothing")
	}
	if others := CollectWithin(elsewhere, FromInt64(200)); JsonIsNotEmpty(others) {
		t.Fatalf("an event crossed into another key: %s", EncodeJSONValue(others.JsonRaw()))
	}
}

func TestPublishReachesEverySubscriberOnTheKey(t *testing.T) {
	channel := NewSseChannel("Broadcast")
	server := streamServer(channel)
	first := SubscribeStream(server, "/stream", nil)
	defer UnsubscribeStream(first)
	second := SubscribeStream(server, "/stream", nil)
	defer UnsubscribeStream(second)
	waitForListeners(t, channel, "all", 2)

	Publish(channel, "all", eventPayload("id", "e1"))

	for index, stream := range []*SseTestStream{first, second} {
		if events := CollectCount(stream, FromInt64(1), FromInt64(2000)); !JsonIsNotEmpty(events) {
			t.Fatalf("subscriber %d received nothing", index)
		}
	}
}

// SSE has no backlog: an event published before a subscriber connected is gone.
func TestPublishWithNoSubscribersIsDropped(t *testing.T) {
	channel := NewSseChannel("Quiet")
	Publish(channel, "all", eventPayload("id", "e1"))
	stream := SubscribeStream(streamServer(channel), "/stream", nil)
	defer UnsubscribeStream(stream)
	waitForListeners(t, channel, "all", 1)
	if events := CollectWithin(stream, FromInt64(200)); JsonIsNotEmpty(events) {
		t.Fatalf("a subscriber received an event published before it: %s",
			EncodeJSONValue(events.JsonRaw()))
	}
}

// A subscription the server REFUSES fails the test where it is written, carrying the status
// and message the client would have seen — not silently producing an empty stream.
func TestSubscribeToAnUnknownRouteFails(t *testing.T) {
	channel := NewSseChannel("Runs")
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("subscribing to a route that does not exist succeeded")
		}
		message := fmt.Sprint(recovered)
		if !strings.Contains(message, "subscribe failed for /nowhere") ||
			!strings.Contains(message, "404") {
			t.Fatalf("the failure reads %q", message)
		}
	}()
	SubscribeStream(streamServer(channel), "/nowhere", nil)
}

// A connection that goes away takes its listener with it: a listener that outlives its
// connection is charged to every future publish (Racket's issue #32, where a day of
// development left 109 stale listeners on one key).
func TestUnsubscribeRemovesTheListener(t *testing.T) {
	channel := NewSseChannel("Runs")
	stream := SubscribeStream(streamServer(channel), "/stream", nil)
	waitForListeners(t, channel, "all", 1)
	UnsubscribeStream(stream)

	for attempt := 0; attempt < 200; attempt++ {
		if channelListenerCount(channel, "all") == 0 {
			// The key itself is dropped too: a per-entity channel sees a new key per entity,
			// and the entries would otherwise outlive them all.
			channel.mutex.Lock()
			_, present := channel.listeners["all"]
			channel.mutex.Unlock()
			if present {
				t.Fatal("the key was left in the registry with no listeners")
			}
			// Idempotent: every exit path calls it.
			UnsubscribeStream(stream)
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the listener outlived the connection")
}

func TestCollectCountAnswersEverythingDrained(t *testing.T) {
	channel := NewSseChannel("Runs")
	stream := SubscribeStream(streamServer(channel), "/stream", nil)
	defer UnsubscribeStream(stream)
	waitForListeners(t, channel, "all", 1)
	for index := range 3 {
		Publish(channel, "all", eventPayload("id", fmt.Sprintf("e%d", index)))
	}
	// Asked for 1, answered 3: the extra events are handed back rather than hidden, which is
	// what Racket's `finish-all!` does.
	events := CollectCount(stream, FromInt64(3), FromInt64(2000))
	elements, ok := events.JsonRaw().([]any)
	if !ok || len(elements) != 3 {
		t.Fatalf("collect answered %s", EncodeJSONValue(events.JsonRaw()))
	}
	if again := CollectWithin(stream, FromInt64(200)); JsonIsNotEmpty(again) {
		t.Fatalf("the events were left on the stream: %s", EncodeJSONValue(again.JsonRaw()))
	}
}

// A collect that waits for events which never come is a test FAILURE naming the stream — the
// assertion after it would otherwise report "expected non-empty" for "the action published
// nothing".
func TestCollectCountTimesOutLoudly(t *testing.T) {
	channel := NewSseChannel("Runs")
	stream := SubscribeStream(streamServer(channel), "/stream", nil)
	defer UnsubscribeStream(stream)
	defer func() {
		recovered := recover()
		if recovered == nil {
			t.Fatal("a collect with no events succeeded")
		}
		message := fmt.Sprint(recovered)
		for _, want := range []string{"timed out after 100ms", "count 1", "/stream",
			"received 0 events"} {
			if !strings.Contains(message, want) {
				t.Fatalf("the timeout message is missing %q: %s", want, message)
			}
		}
	}()
	CollectCount(stream, FromInt64(1), FromInt64(100))
}

func TestCollectCountRejectsANonPositiveCount(t *testing.T) {
	channel := NewSseChannel("Runs")
	stream := SubscribeStream(streamServer(channel), "/stream", nil)
	defer UnsubscribeStream(stream)
	defer func() {
		if recover() == nil {
			t.Fatal("a zero count was accepted")
		}
	}()
	CollectCount(stream, FromInt64(0), FromInt64(100))
}

// `until` answers the prefix up to and including the match and LEAVES the rest: the next
// collect on the same stream continues where this one stopped.
func TestCollectUntilKeepsTheRest(t *testing.T) {
	channel := NewSseChannel("Runs")
	stream := SubscribeStream(streamServer(channel), "/stream", nil)
	defer UnsubscribeStream(stream)
	waitForListeners(t, channel, "all", 1)
	for _, id := range []string{"a", "b", "c"} {
		Publish(channel, "all", eventPayload("id", id))
	}
	events := CollectUntil(stream, map[string]any{"id": "b"}, FromInt64(2000))
	elements, _ := events.JsonRaw().([]any)
	if len(elements) != 2 {
		t.Fatalf("until answered %s", EncodeJSONValue(events.JsonRaw()))
	}
	rest := CollectCount(stream, FromInt64(1), FromInt64(2000))
	if !JsonIncludesWhere(map[string]any{"id": "c"}, rest) {
		t.Fatalf("the remaining event was dropped: %s", EncodeJSONValue(rest.JsonRaw()))
	}
}

// A stuck consumer costs the publisher NOTHING: events are dropped for it alone once it falls
// a whole buffer behind, and the publish call still returns.
func TestPublishNeverBlocksOnAFullBuffer(t *testing.T) {
	channel := NewSseChannel("Runs")
	// A listener registered directly, and never read: the HTTP path would drain into the
	// connection, and what is under test here is the bound itself.
	listener := channel.register("all")
	defer channel.unregister("all", listener)
	done := make(chan struct{})
	go func() {
		for index := range sseEventBufferLimit * 3 {
			Publish(channel, "all", eventPayload("id", fmt.Sprintf("e%d", index)))
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("publish blocked on a consumer that is not reading")
	}
	if buffered := len(listener.events); buffered != sseEventBufferLimit {
		t.Fatalf("the buffer holds %d events, want %d", buffered, sseEventBufferLimit)
	}
}

func TestResetChannelDropsEveryListener(t *testing.T) {
	channel := NewSseChannel("Runs")
	listener := channel.register("all")
	ResetChannel(channel)
	Publish(channel, "all", eventPayload("id", "e1"))
	if buffered := len(listener.events); buffered != 0 {
		t.Fatal("a listener survived the reset")
	}
	// Usable afterwards: the reset drops the listeners, it does not poison the channel.
	next := channel.register("all")
	defer channel.unregister("all", next)
	Publish(channel, "all", eventPayload("id", "e2"))
	if buffered := len(next.events); buffered != 1 {
		t.Fatalf("the channel delivered %d events after a reset", buffered)
	}
}

// ── The wire format ───────────────────────────────────────────────────────────

func TestSseStreamWritesTheRacketWireFormat(t *testing.T) {
	channel := NewSseChannel("RunEvents")
	server := httptest.NewServer(http.HandlerFunc(SseStream(channel, "all")))
	defer server.Close()

	response, err := http.Get(server.URL) //nolint:noctx // the test closes the server
	if err != nil || response == nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = response.Body.Close() }()
	if got := response.Header.Get("Content-Type"); got != "text/event-stream" {
		t.Fatalf("the stream is served as %q", got)
	}
	reader := bufio.NewReader(response.Body)
	// The immediate comment, so a browser fires onopen without waiting for a heartbeat.
	line, err := reader.ReadString('\n')
	if err != nil || strings.TrimRight(line, "\r\n") != ": ok" {
		t.Fatalf("the stream opened with %q (%v)", line, err)
	}

	waitForListeners(t, channel, "all", 1)
	Publish(channel, "all", eventPayload("runId", "run-abc"))

	data := readDataLine(t, reader)
	for _, want := range []string{`"channel":"RunEvents"`, `"payload":`, `"runId":"run-abc"`} {
		if !strings.Contains(data, want) {
			t.Fatalf("the event line %q is missing %q", data, want)
		}
	}
}

func readDataLine(t *testing.T, reader *bufio.Reader) string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if strings.HasPrefix(line, "data: ") {
			return strings.TrimRight(strings.TrimPrefix(line, "data: "), "\r\n")
		}
	}
	t.Fatal("no event arrived on the stream")
	return ""
}

// One channel, many goroutines: publishes come from concurrent request handlers while
// connections come and go. Run with -race, which the gate does.
func TestSseChannelIsSafeUnderConcurrentUse(t *testing.T) {
	channel := NewSseChannel("Runs")
	var waiting sync.WaitGroup
	for worker := range 8 {
		waiting.Add(1)
		go func() {
			defer waiting.Done()
			key := fmt.Sprintf("k%d", worker%3)
			for index := range 32 {
				listener := channel.register(key)
				Publish(channel, key, eventPayload("id", fmt.Sprintf("%d-%d", worker, index)))
				channel.unregister(key, listener)
			}
		}()
	}
	waiting.Wait()
	channel.mutex.Lock()
	defer channel.mutex.Unlock()
	if len(channel.listeners) != 0 {
		t.Fatalf("%d keys left in the registry", len(channel.listeners))
	}
	if channel.active != 0 {
		t.Fatalf("the active count settled at %d", channel.active)
	}
}
