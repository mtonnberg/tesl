package teslrt

import (
	"bufio"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"time"
)

// The HTTP half of Server-Sent Events: the route that STREAMS a channel to a browser, and the
// api-test surface that subscribes to it. Both need the HTTP runtime, so they live apart from
// the channel itself — a module that only publishes ships no server.

// sseEventBufferLimit is how many undelivered events ONE connection may hold; see the
// never-block note on the channel itself.
const sseEventBufferLimit = 64

// sseHeartbeatInterval is Racket's 10 seconds.
const sseHeartbeatInterval = 10 * time.Second

func (channel *SseChannel) register(key string) *sseListener {
	listener := &sseListener{events: make(chan any, sseEventBufferLimit)}
	channel.mutex.Lock()
	channel.listeners[key] = append(channel.listeners[key], listener)
	channel.active++
	count := channel.active
	channel.mutex.Unlock()
	Gauge("tesl.sse.connections.active", float64(count), sseChannelAttribute(channel.name))
	return listener
}

// unregister is idempotent: every exit path calls it, and a connection that ended twice (an
// orderly close racing a cancelled request) must not corrupt the registry.
func (channel *SseChannel) unregister(key string, listener *sseListener) {
	channel.mutex.Lock()
	remaining := channel.listeners[key][:0]
	removed := false
	for _, registered := range channel.listeners[key] {
		if registered == listener && !removed {
			removed = true
			continue
		}
		remaining = append(remaining, registered)
	}
	if len(remaining) == 0 {
		// Drop the KEY as well: a churn of one-off keys would otherwise leak an entry each.
		delete(channel.listeners, key)
	} else {
		channel.listeners[key] = remaining
	}
	if removed && channel.active > 0 {
		channel.active--
	}
	count := channel.active
	channel.mutex.Unlock()
	if removed {
		Gauge("tesl.sse.connections.active", float64(count), sseChannelAttribute(channel.name))
	}
}

// SseStream is the `sse "/path" subscribe C(key)` route's handler. It streams until the client
// goes away, and it removes its listener on EVERY exit path — a listener that outlives its
// connection is charged to every future publish.
func SseStream(channel *SseChannel, key string) func(http.ResponseWriter, *http.Request) {
	return func(writer http.ResponseWriter, request *http.Request) {
		flusher, canFlush := writer.(http.Flusher)
		if !canFlush {
			// Nothing can be streamed to this client. Say so rather than opening a connection
			// that would silently never deliver.
			http.Error(writer, "streaming unsupported", http.StatusInternalServerError)
			return
		}
		writer.Header().Set("Content-Type", "text/event-stream")
		writer.Header().Set("Cache-Control", "no-cache")
		writer.Header().Set("Connection", "keep-alive")
		writer.WriteHeader(http.StatusOK)

		listener := channel.register(key)
		defer channel.unregister(key, listener)

		// An immediate comment so the browser fires onopen now rather than at the first
		// heartbeat: with chunked encoding it opens on the first body chunk.
		if _, err := writer.Write([]byte(": ok\n\n")); err != nil {
			return
		}
		flusher.Flush()

		heartbeat := time.NewTicker(sseHeartbeatInterval)
		defer heartbeat.Stop()
		for {
			select {
			case <-request.Context().Done():
				return
			case event := <-listener.events:
				body := fmt.Sprintf("data: %s\n\n", EncodeJSONValue(map[string]any{
					"channel": channel.name,
					"payload": event,
				}))
				if _, err := writer.Write([]byte(body)); err != nil {
					return
				}
				flusher.Flush()
				Counter("tesl.sse.events.sent", FromInt64(1), sseChannelAttribute(channel.name))
			case <-heartbeat.C:
				if _, err := writer.Write([]byte(": heartbeat\n\n")); err != nil {
					return
				}
				flusher.Flush()
			}
		}
	}
}

// SseStreamParam is the same route when the channel key comes from a `:param` SEGMENT of the
// path (`sse "/events/:userId" subscribe Notices(userId)`): each connection keys on its own
// segment, which is what makes the channel per-entity.
func SseStreamParam(channel *SseChannel, pattern, param string) func(http.ResponseWriter, *http.Request) {
	return func(writer http.ResponseWriter, request *http.Request) {
		key, found := PathParam(pattern, request.URL.Path, param)
		if !found {
			// The router matched the pattern, so a missing segment is an emitter bug rather
			// than a client error — say so instead of streaming on an empty key.
			http.Error(writer, "stream key segment "+param+" is missing", http.StatusInternalServerError)
			return
		}
		SseStream(channel, key)(writer, request)
	}
}

// ── api-test side ─────────────────────────────────────────────────────────────
//
// `subscribe "/path"` in an api-test opens a REAL connection to the emitted server and reads
// the stream, rather than registering on the channel behind the route's back. That way the
// test meets everything a browser would: the route lookup, the auth check, every declared
// capture check, and the wire format itself. A subscription the server refuses fails the test
// where it is written, with the status and message the client would have received.

type SseTestStream struct {
	name   string
	server *httptest.Server
	body   io.ReadCloser
	events chan any
	// closed guards the teardown, which every exit path calls.
	closed  bool
	mutex   sync.Mutex
	backlog []any
}

// sseTestBufferLimit bounds what one test stream holds. A test that publishes more than this
// without collecting is not measuring delivery any more.
const sseTestBufferLimit = 256

// SubscribeStream opens `path` on the emitted server as an event stream. `cookies` are the
// api-test cookie headers, so a stream behind `auth … via cookieAuth` can be subscribed the
// way the endpoint expects.
func SubscribeStream(server Server, path string, cookies []string) *SseTestStream {
	testServer := httptest.NewServer(server)
	request, err := http.NewRequest(http.MethodGet, testServer.URL+path, nil) //nolint:noctx // torn down by UnsubscribeStream
	if err != nil {
		testServer.Close()
		panic("subscribe: " + path + ": " + err.Error())
	}
	request.Header.Set("Accept", "text/event-stream")
	for _, cookie := range cookies {
		request.Header.Add("Cookie", cookie)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil || response == nil {
		testServer.Close()
		message := "no response"
		if err != nil {
			message = err.Error()
		}
		panic("subscribe: " + path + ": " + message)
	}
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		_ = response.Body.Close()
		testServer.Close()
		// The status and message the CLIENT would have seen: a refused subscription is an
		// answer about the route, not a missing-events problem for the next assertion.
		panic(fmt.Sprintf("subscribe failed for %s: %d %s", path, response.StatusCode,
			strings.TrimSpace(string(body))))
	}
	stream := &SseTestStream{
		name: path, server: testServer, body: response.Body,
		events: make(chan any, sseTestBufferLimit),
	}
	go stream.read()
	return stream
}

// read turns the event lines into payloads. A heartbeat or the opening comment is not an
// event; neither is a malformed line, which ends the stream rather than being reported as
// data.
func (stream *SseTestStream) read() {
	reader := bufio.NewReader(stream.body)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return
		}
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		parsed, parseErr := ParseJSON([]byte(strings.TrimRight(strings.TrimPrefix(line, "data: "), "\r\n")))
		if parseErr != nil {
			continue
		}
		// What a test collects is the PAYLOAD, which is what Racket's api-test stream yields;
		// the channel name is already known from the path it subscribed to.
		event := parsed
		if envelope, isObject := parsed.(map[string]any); isObject {
			if payload, present := envelope["payload"]; present {
				event = payload
			}
		}
		select {
		case stream.events <- event:
		default:
			return
		}
	}
}

// UnsubscribeStream closes the connection and the test server behind it. Emitted at the end of
// the block, so one block's stream cannot collect another's events.
func UnsubscribeStream(stream *SseTestStream) {
	stream.mutex.Lock()
	already := stream.closed
	stream.closed = true
	stream.mutex.Unlock()
	if already {
		return
	}
	_ = stream.body.Close()
	stream.server.Close()
}

// drain moves everything currently buffered into the backlog and answers it.
func (stream *SseTestStream) drain() []any {
	stream.mutex.Lock()
	defer stream.mutex.Unlock()
	for {
		select {
		case event := <-stream.events:
			stream.backlog = append(stream.backlog, event)
		default:
			events := make([]any, len(stream.backlog))
			copy(events, stream.backlog)
			return events
		}
	}
}

func (stream *SseTestStream) keep(from int) {
	stream.mutex.Lock()
	defer stream.mutex.Unlock()
	if from >= len(stream.backlog) {
		stream.backlog = nil
		return
	}
	stream.backlog = append([]any{}, stream.backlog[from:]...)
}

// ssePollInterval is Racket's 50ms poll; the collect loop is a poll on both backends because
// the deadline belongs to the whole collect, not to one event.
const ssePollInterval = 50 * time.Millisecond

// CollectCount waits for at least `count` events and answers everything drained — Racket's
// `finish-all!`, which hands back the extra events rather than hiding them.
//
// A timeout is a test FAILURE, not an empty answer: the assertion that follows would otherwise
// report "expected non-empty" for what is really "the action never published".
func CollectCount(stream *SseTestStream, count Int, timeoutMillis Int) JsonValue {
	wanted, exact := count.Int64()
	if !exact || wanted < 1 {
		panic("collect: count must be a positive Int, got " + count.String())
	}
	deadline := time.Now().Add(sseTimeout(timeoutMillis))
	for {
		events := stream.drain()
		if int64(len(events)) >= wanted {
			stream.keep(len(events))
			return JsonOf(events)
		}
		if !time.Now().Before(deadline) {
			panic(sseTimeoutMessage(stream, timeoutMillis,
				fmt.Sprintf("count %d", wanted), events))
		}
		time.Sleep(ssePollInterval)
	}
}

// CollectUntil waits for an event MATCHING the pattern and answers the events up to and
// including it; the rest stay on the stream for the next collect.
func CollectUntil(stream *SseTestStream, until any, timeoutMillis Int) JsonValue {
	deadline := time.Now().Add(sseTimeout(timeoutMillis))
	for {
		events := stream.drain()
		for index, event := range events {
			if jsonMatch(until, event) {
				stream.keep(index + 1)
				return JsonOf(events[:index+1])
			}
		}
		if !time.Now().Before(deadline) {
			panic(sseTimeoutMessage(stream, timeoutMillis,
				"until "+EncodeJSONValue(until), events))
		}
		time.Sleep(ssePollInterval)
	}
}

// CollectWithin waits out the whole timeout and answers whatever arrived — including nothing,
// which is how a test asserts that an action published NO event.
func CollectWithin(stream *SseTestStream, timeoutMillis Int) JsonValue {
	deadline := time.Now().Add(sseTimeout(timeoutMillis))
	for time.Now().Before(deadline) {
		time.Sleep(ssePollInterval)
	}
	events := stream.drain()
	stream.keep(len(events))
	return JsonOf(events)
}

func sseTimeout(timeoutMillis Int) time.Duration {
	millis, exact := timeoutMillis.Int64()
	if !exact || millis < 0 {
		panic("collect: timeout must be a non-negative number of milliseconds, got " +
			timeoutMillis.String())
	}
	return time.Duration(millis) * time.Millisecond
}

func sseTimeoutMessage(stream *SseTestStream, timeoutMillis Int, description string,
	events []any) string {
	millis, _ := timeoutMillis.Int64()
	duration := fmt.Sprintf("%dms", millis)
	if millis%1000 == 0 {
		duration = fmt.Sprintf("%ds", millis/1000)
	}
	return fmt.Sprintf(
		"collect: timed out after %s waiting for %s\nreceived %d events on stream %q\n"+
			"hint: did the action that produces events run successfully?",
		duration, description, len(events), stream.name)
}
